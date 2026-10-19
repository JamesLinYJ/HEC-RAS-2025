using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.Features;
using Geospatial.GDALAssist;
using Geospatial.IO;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Utility.Memory;
using Utility.Units;

internal static class MapVectorSourceChecks
{
    private const string MapID = "4e17d264-e4f5-4882-b87f-03e3ca4aa435";
    private const string LocalMapID = "b27eb264-1a98-46e6-8cb7-c936dd444b9f";
    private const string MapName = "Map vector source fixture";

    private sealed record FixtureSource(string MapType, string Path, MapVectorSourceLoadResult Result,
        MapVectorSourceLoadRequest Request);

    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "vector-source.ras");
        Project createdProject = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        DisposeProject(createdProject);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: MapName, MapID: MapID));

        string pointPath = Path.Combine(root, "fixture-points.shp");
        Check(ShapefileIO.Write(pointPath, new List<Point> { new(116, 39), new(116.1, 39.1) }).Result,
            "The retained writer creates real point records for the map-vector reader fixture.");
        new EPSGProjection(4326).ExportEsri(ShapefileIO.PRJFilename(pointPath));

        string linePath = Path.Combine(root, "fixture-line.shp");
        var line = new Polyline(new Point[] { new(116, 39), new(116.1, 39.1), new(116.2, 39.2) });
        line.TrackZ(new double[] { 10, 20, 30 });
        line.TrackM(new double[] { 100, 200, 300 });
        Table lineAttributes = LineAttributes();
        Check(ShapefileIO.Write(linePath, new List<Polyline> { line }, lineAttributes).Result,
            "The retained writer creates actual XYZM polyline records and typed DBF values.");
        string lineProjectionPath = ShapefileIO.PRJFilename(linePath);
        new EPSGProjection(4326).ExportEsri(lineProjectionPath);
        MakeSecondAndFifthDbfColumnNamesDuplicate(ShapefileIO.DBFFilename(linePath));

        string polygonPath = Path.Combine(root, "fixture-polygon.shp");
        Check(ShapefileIO.Write(polygonPath, new List<Polygon>
        {
            new(new Point[] { new(116, 39), new(116.2, 39), new(116.2, 39.2), new(116, 39.2) })
        }, OneStringColumn("Class", "floodplain")).Result,
            "The retained writer creates real polygon records for the map-vector reader fixture.");
        new EPSGProjection(4326).ExportEsri(ShapefileIO.PRJFilename(polygonPath));

        var sourcePaths = new[] { pointPath, linePath, polygonPath };
        var families = sourcePaths.ToDictionary(path => path, MapTreeService.CaptureShapefileFamily,
            StringComparer.Ordinal);
        MapDocumentMutationReceipt lastImport = createdMap;
        foreach (string sourcePath in sourcePaths)
        {
            MapDocumentRequest mapDocument = MapDocumentRequestFor(projectPath, projectXml, createdMap);
            lastImport = MapTreeService.ImportShapefileVector(new(mapDocument, sourcePath, projectRevision,
                families[sourcePath]));
        }

        MapTreeRequest mapRequest = MapTreeRequestFor(projectPath, projectXml, lastImport);
        MapTreeSnapshot tree = MapTreeService.Load(mapRequest);
        var results = new List<FixtureSource>();
        foreach ((string path, string mapType) in new[]
                 {
                     (pointPath, "PointsVector"), (linePath, "PolylinesVector"), (polygonPath, "PolygonsVector")
                 })
        {
            CatalogTreeNode layer = FindMapLayer(tree.Roots, mapType, Path.GetFileName(path));
            CatalogTreeNodeLocator locator = layer.Locator ?? throw new InvalidOperationException("The source map layer has no locator.");
            var request = new MapVectorSourceLoadRequest(mapRequest, locator, families[path]);
            MapVectorSourceLoadResult result = MapVectorSourceService.Load(request);
            Check(result.Source.Map.IsPersisted && result.Source.Map.MapID == MapID &&
                result.Source.Map.MapIndex == lastImport.MapIndex && result.Source.Map.MapName == MapName &&
                result.Source.Map.MapType == "Project" && result.Source.Locator.MapType == mapType &&
                result.Source.Family.SourcePath == Path.GetFullPath(path),
                "Vector source read remains bound to the exact saved map, node and consumed file family.");
            Check(SameFamily(result.Source.Family, families[path]),
                "The returned family capture is the exact source family supplied by the map tree.");
            results.Add(new(mapType, path, result, request));
        }

        CheckPointSource(results.Single(item => item.MapType == "PointsVector").Result.Data,
            ShapefileIO.PRJFilename(pointPath));
        CheckLineSource(results.Single(item => item.MapType == "PolylinesVector").Result.Data, lineProjectionPath);
        CheckPolygonSource(results.Single(item => item.MapType == "PolygonsVector").Result.Data);

        CheckProjectedMapRejectsMissingSourceProjection(results.Single(item => item.MapType == "PointsVector"), pointPath);
        CheckLocalProjectUsesSourceCoordinates(projectXmlSHA, linePath);

        FixtureSource lineFixture = results.Single(item => item.MapType == "PolylinesVector");
        byte[] unchangedDbf = File.ReadAllBytes(ShapefileIO.DBFFilename(linePath));
        File.WriteAllBytes(ShapefileIO.DBFFilename(linePath), [1, 2, 3]);
        Expect<SourceFileChangedException>(() => MapVectorSourceService.Load(lineFixture.Request),
            "A DBF modified after its captured family is rejected before returning vector data.");
        File.WriteAllBytes(ShapefileIO.DBFFilename(linePath), unchangedDbf);

        var incorrectLocator = lineFixture.Request.Node with { Filename = Path.Combine(root, "different.shp") };
        Expect<SourceFileChangedException>(() => MapVectorSourceService.Load(lineFixture.Request with { Node = incorrectLocator }),
            "A node locator that no longer identifies the persisted map row is rejected.");

        ExportAcceptanceFixtureIfRequested(projectPath, projectXml, lastImport, sourcePaths, families, results);
        Console.WriteLine("Real retained point, XYZM polyline and polygon source reads preserve map/family identity, projection, parts and ordered typed DBF attributes.");
    }

    private static void CheckPointSource(MapVectorSourceData data, string sourceProjectionPath)
    {
        Check(data.ShapeType == "Point" && data.ShapeTypeCode == 1 && data.Count == 2 && data.Features.Length == 2,
            "Point shape records retain the source shape code and record order.");
        var sourceProjection = new ESRIProjection(sourceProjectionPath);
        Point expected = Projector.TransformPoint(sourceProjection, new EPSGProjection(32650), new Point(116.1, 39.1));
        Check(data.ProjectionStatus == "projected" && data.SourceProjectionWKT == sourceProjection.GetWKT() &&
            data.TargetProjectionWKT == new EPSGProjection(32650).GetWKT() &&
            data.Features[1].SourceOrdinal == 1 && data.Features[1].SourceID is null &&
            Near(data.Features[1].Parts.Single().Vertices.Single().X, expected.X, 0.01) &&
            Near(data.Features[1].Parts.Single().Vertices.Single().Y, expected.Y, 0.01) &&
            data.Features[1].Parts.Single().Vertices.Single() is { SourceX: 116.1, SourceY: 39.1 },
            "Point source coordinates remain available while actual target-CRS coordinates are projected.");
    }

    private static void CheckLineSource(MapVectorSourceData data, string sourceProjectionPath)
    {
        Check(data.ShapeType == "Polyline" && (data.ShapeTypeCode is 3 or 13 or 23) &&
            data.Count == 1 && data.Features.Length == 1,
            "Polyline shape records retain the exact supported source code and record count.");
        MapVectorSourceFeature feature = data.Features.Single();
        MapVectorSourceVertex[] vertices = feature.Parts.Single().Vertices;
        Point expected = Projector.TransformPoint(new ESRIProjection(sourceProjectionPath),
            new EPSGProjection(32650), new Point(116, 39));
        Check(feature.SourceOrdinal == 0 && feature.SourceID is null && feature.ShapeType == "Polyline" &&
            vertices.Length == 3 && Near(vertices[0].X, expected.X, 0.01) && Near(vertices[0].Y, expected.Y, 0.01) &&
            vertices[0].SourceX == 116 && vertices[0].SourceY == 39 && vertices[0].Z == 10 && vertices[0].M == 100 &&
            vertices[2].SourceX == 116.2 && vertices[2].SourceY == 39.2 && vertices[2].Z == 30 && vertices[2].M == 300,
            "Polyline paths preserve source XY/Z/M and contain the actual project-projected drawing coordinates.");
        Check(data.ProjectionStatus == "projected" && data.SourceProjectionWKT == new ESRIProjection(sourceProjectionPath).GetWKT() &&
            data.TargetProjectionWKT == new EPSGProjection(32650).GetWKT() &&
            data.SourceExtent is { MinX: 116, MinY: 39, MaxX: 116.2, MaxY: 39.2 } &&
            data.Extent is { MinX: > 400_000, MaxX: < 500_000 },
            "Polyline source and project extents and their actual projection definitions are reported.");
        MapVectorSourceAttribute[] attributes = feature.Attributes;
        Check(attributes.Length == 5 && attributes.Select(attribute => attribute.ColumnOrdinal).SequenceEqual([0, 1, 2, 3, 4]) &&
            attributes.Select(attribute => attribute.ColumnName).SequenceEqual(["ID", "Level", "Active", "Label", "Label"]) &&
            attributes.Select(attribute => attribute.Type).SequenceEqual(["integer", "number", "boolean", "string", "string"]) &&
            attributes[0].Value == "7" && attributes[1].Value == "3.5" && attributes[2].BooleanValue == true &&
            attributes[3].Value == "left" && attributes[4].Value == "right",
            "DBF output preserves duplicate field names, order, cell types and the distinct values for each duplicate ordinal.");
    }

    private static void CheckPolygonSource(MapVectorSourceData data)
    {
        Check(data.ProjectionStatus == "projected" && data.ShapeType == "Polygon" && data.ShapeTypeCode == 5 && data.Count == 1 &&
            data.Features.Single().Parts.Length == 1 && data.Features[0].Parts[0].Vertices.Length >= 3 &&
            data.Features[0].Attributes.Single() is { ColumnOrdinal: 0, ColumnName: "Class", Type: "string", Value: "floodplain" },
            "Polygon rings remain distinct ordered parts and the real polygon DBF value survives.");
    }

    private static void CheckProjectedMapRejectsMissingSourceProjection(FixtureSource pointSource, string sourcePath)
    {
        string projectionPath = ShapefileIO.PRJFilename(sourcePath);
        byte[] projectionBytes = File.ReadAllBytes(projectionPath);
        File.Delete(projectionPath);
        try
        {
            MapSourceFamilyCapture currentFamily = MapTreeService.CaptureShapefileFamily(sourcePath);
            Expect<InvalidOperationException>(() => MapVectorSourceService.Load(
                pointSource.Request with { ExpectedFamily = currentFamily }),
                "A projected map does not interpret unreferenced source coordinates as project coordinates.");
        }
        finally
        {
            File.WriteAllBytes(projectionPath, projectionBytes);
        }
    }

    private static void CheckLocalProjectUsesSourceCoordinates(string projectXmlSHA, string sourcePath)
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "local-vector-source.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.Local(UnitSystem.SI));
        DisposeProject(project);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        Check(Hash(Encoding.UTF8.GetBytes(projectXml)) != projectXmlSHA,
            "The Local-project source-coordinate check uses a distinct real project fixture.");
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)), null, "Project",
            Name: "Local source map", MapID: LocalMapID));

        MapSourceFamilyCapture sourceFamily = MapTreeService.CaptureShapefileFamily(sourcePath);
        foreach (MapSourceFileRevision file in sourceFamily.Files.Where(item => item.Exists))
            File.Copy(file.Path, Path.Combine(directory.FullName, Path.GetFileName(file.Path)));
        sourcePath = Path.Combine(directory.FullName, Path.GetFileName(sourcePath));
        MapSourceFamilyCapture family = MapTreeService.CaptureShapefileFamily(sourcePath);
        MapDocumentMutationReceipt imported = MapTreeService.ImportShapefileVector(new(
            MapDocumentRequestFor(projectPath, projectXml, created, LocalMapID),
            sourcePath, projectRevision, family));
        MapTreeRequest mapRequest = MapTreeRequestFor(projectPath, projectXml, imported,
            LocalMapID);
        CatalogTreeNode layer = FindMapLayer(MapTreeService.Load(mapRequest).Roots,
            "PolylinesVector", "fixture-line.shp");
        MapVectorSourceLoadResult local = MapVectorSourceService.Load(new(mapRequest, layer.Locator!, family));
        MapVectorSourceVertex first = local.Data.Features.Single().Parts.Single().Vertices[0];
        Check(local.Data.ProjectionStatus == "localProjectSourceCoordinates" &&
            local.Data.SourceProjectionWKT == new ESRIProjection(ShapefileIO.PRJFilename(sourcePath)).GetWKT() &&
            local.Data.TargetProjectionWKT is null && first.X == first.SourceX && first.Y == first.SourceY &&
            first.SourceX == 116 && first.SourceY == 39,
            "A valid Local project exposes its no-transform path without inventing a target CRS.");
    }

    private static void ExportAcceptanceFixtureIfRequested(string projectPath, string projectXml,
        MapDocumentMutationReceipt map, string[] sourcePaths,
        IReadOnlyDictionary<string, MapSourceFamilyCapture> families, IReadOnlyList<FixtureSource> sources)
    {
        string? configured = Environment.GetEnvironmentVariable("HECRAS_MAP_VECTOR_SOURCE_FIXTURE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configured)) return;

        string destination = Path.GetFullPath(configured);
        string sourceDirectory = Path.GetDirectoryName(projectPath)!;
        if (PathEquals(destination, sourceDirectory) || IsWithin(destination, sourceDirectory) || IsWithin(sourceDirectory, destination))
            throw new InvalidOperationException("The acceptance fixture destination must be separate from its unique source fixture directory.");
        Directory.CreateDirectory(destination);
        if (Directory.EnumerateFileSystemEntries(destination).Any())
            throw new InvalidOperationException("The map-vector acceptance fixture destination must be empty before export.");

        string destinationProject = Path.Combine(destination, Path.GetFileName(projectPath));
        File.Copy(projectPath, destinationProject);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string destinationVisualization = Path.ChangeExtension(destinationProject, ".vis");
        File.Copy(visualizationPath, destinationVisualization);
        foreach (string sourcePath in sourcePaths)
        {
            MapSourceFamilyCapture family = families[sourcePath];
            foreach (MapSourceFileRevision file in family.Files.Where(item => item.Exists))
                File.Copy(file.Path, Path.Combine(destination, Path.GetFileName(file.Path)));
        }

        string copiedProjectXml = File.ReadAllText(destinationProject, Encoding.UTF8);
        string copiedProjectXmlSHA = Hash(Encoding.UTF8.GetBytes(copiedProjectXml));
        string copiedProjectRevision = Hash(File.ReadAllBytes(destinationProject));
        string copiedVisualizationRevision = Hash(File.ReadAllBytes(destinationVisualization));
        var copiedReceipt = map with { VisualizationRevision = copiedVisualizationRevision };
        MapTreeRequest copiedMapRequest = MapTreeRequestFor(destinationProject, copiedProjectXml, copiedReceipt);
        MapTreeSnapshot copiedTree = MapTreeService.Load(copiedMapRequest);
        var copiedSources = new List<FixtureSource>();
        foreach ((string sourcePath, string mapType) in sourcePaths.Select(path => (path,
                     Path.GetFileName(path) switch
                     {
                         "fixture-points.shp" => "PointsVector",
                         "fixture-line.shp" => "PolylinesVector",
                         _ => "PolygonsVector"
                     })))
        {
            CatalogTreeNode layer = FindMapLayer(copiedTree.Roots, mapType, Path.GetFileName(sourcePath));
            var request = new MapVectorSourceLoadRequest(copiedMapRequest, layer.Locator!,
                MapTreeService.CaptureShapefileFamily(Path.Combine(destination, Path.GetFileName(sourcePath))));
            MapVectorSourceLoadResult result = MapVectorSourceService.Load(request);
            copiedSources.Add(new(mapType, request.ExpectedFamily!.SourcePath, result, request));
        }

        var manifest = new
        {
            version = 1,
            projectPath = Path.GetFileName(destinationProject),
            visualizationPath = Path.GetFileName(destinationVisualization),
            projectRevision = copiedProjectRevision,
            map = new
            {
                mapID = MapID,
                mapIndex = copiedReceipt.MapIndex,
                mapName = copiedReceipt.MapName,
                mapType = copiedReceipt.MapType,
                projectXmlSHA = copiedProjectXmlSHA,
                expectedVisualizationRevision = copiedVisualizationRevision
            },
            sourceFamilies = copiedSources.Select(source => new
            {
                sourcePath = Path.GetRelativePath(destination, source.Result.Source.Family.SourcePath),
                source.MapType,
                source.Result.Source.Locator,
                expectedFamily = source.Result.Source.Family,
                request = source.Request,
                result = source.Result
            }).ToArray(),
            primarySourcePath = "fixture-line.shp",
            request = copiedSources.Single(source => source.MapType == "PolylinesVector").Request,
            result = copiedSources.Single(source => source.MapType == "PolylinesVector").Result
        };
        File.WriteAllText(Path.Combine(destination, "MAP_VECTOR_SOURCE_FIXTURE.json"),
            JsonSerializer.Serialize(manifest, BackendJson.Options), new UTF8Encoding(false));
    }

    private static Table LineAttributes()
    {
        var table = new Table();
        table.AddColumn("ID", typeof(int));
        table.AddColumn("Level", typeof(double));
        table.AddColumn("Active", typeof(bool));
        table.AddColumn("Label", typeof(string));
        table.AddColumn("LabelB", typeof(string));
        table.AddNewRow([7, 3.5, true, "left", "right"]);
        return table;
    }

    private static Table OneStringColumn(string name, string value)
    {
        var table = new Table();
        table.AddColumn(name, typeof(string));
        table.AddNewRow([value]);
        return table;
    }

    private static void MakeSecondAndFifthDbfColumnNamesDuplicate(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        int headerLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(8, 2));
        int descriptorOffset = 32 + 4 * 32;
        if (descriptorOffset + 11 > headerLength - 1)
            throw new InvalidDataException("The retained DBF writer did not create the expected fifth field descriptor.");
        Array.Clear(bytes, descriptorOffset, 11);
        Encoding.UTF8.GetBytes("Label").CopyTo(bytes, descriptorOffset);
        File.WriteAllBytes(path, bytes);
    }

    private static MapDocumentRequest MapDocumentRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map, string mapID = MapID)
    {
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        return new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)), Hash(File.ReadAllBytes(visualizationPath)),
            "Project", MapID: mapID, MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);
    }

    private static MapTreeRequest MapTreeRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map, string mapID = MapID)
    {
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        return new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)), mapID,
            map.MapIndex, map.MapName, map.MapType, Hash(File.ReadAllBytes(visualizationPath)));
    }

    private static CatalogTreeNode FindMapLayer(IEnumerable<CatalogTreeNode> nodes, string mapType, string filename)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            if (node.Locator is { NodeType: "MapLayer" } locator && locator.MapType == mapType &&
                string.Equals(Path.GetFileName(locator.Filename), filename, StringComparison.Ordinal))
                return node;
            if (node.Children is { Length: > 0 })
            {
                try { return FindMapLayer(node.Children, mapType, filename); }
                catch (KeyNotFoundException) { }
            }
        }
        throw new KeyNotFoundException($"The map tree has no {mapType} source named {filename}.");
    }

    private static bool Near(double left, double right, double tolerance) => Math.Abs(left - right) <= tolerance;

    private static bool SameFamily(MapSourceFamilyCapture left, MapSourceFamilyCapture right) =>
        left.Family == right.Family && left.SourcePath == right.SourcePath && left.Revision == right.Revision &&
        left.Files.Length == right.Files.Length && left.Files.OrderBy(file => file.Role, StringComparer.Ordinal)
            .SequenceEqual(right.Files.OrderBy(file => file.Role, StringComparer.Ordinal));

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool PathEquals(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static bool IsWithin(string path, string directory)
    {
        string fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string fullDirectory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(fullDirectory, OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }
}
