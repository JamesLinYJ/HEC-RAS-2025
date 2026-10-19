using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using System.Globalization;
using Geospatial.GDALAssist;
using Geospatial.Vectors;
using OSGeo.OGR;
using OSGeo.OSR;
using Ras.Backend;
using Ras.Layers;
using OgrGeometry = OSGeo.OGR.Geometry;

internal static class GdbMapSourceChecks
{
    private const string MapID = "d6b6af62-23c4-4dfa-b4e0-8b5d0c079f31";

    private sealed record PersistedXYZMVertex(double X, double Y, double Z, double M);

    internal static void Run()
    {
        VerifyInMemoryAttributeSemantics();
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "gdb-vector-project.ras");
        Project createdProject = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        DisposeProject(createdProject);
        string projectXml = File.ReadAllText(projectPath, Encoding.UTF8);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "GDB vector map", MapID: MapID));

        string gdbPath = Path.Combine(root, "typed-zm.gdb");
        (string sourceLayerName, wkbGeometryType sourceLayerGeometryType) = CreateOpenFileGdbFixture(gdbPath);
        PersistedXYZMVertex[] persistedVertices = VerifyOpenFileGdbReopen(
            gdbPath, sourceLayerName, sourceLayerGeometryType);
        GdbMapSourceIdentity captured = GdbMapSourceService.CaptureSource(gdbPath);
        string transientLock = Path.Combine(gdbPath, "fixture.lock");
        File.WriteAllText(transientLock, "OGR lock metadata is excluded from source data identity.", new UTF8Encoding(false));
        GdbMapSourceIdentity withLock = GdbMapSourceService.CaptureSource(gdbPath);
        Check(SameSource(captured, withLock),
            "Transient lock files do not change the exact file-geodatabase manifest.");

        GdbMapCatalogResponse catalog = GdbMapSourceService.Catalog(new(gdbPath, captured.Revision));
        GdbMapLayerDescriptor[] matchingLayers = catalog.Layers
            .Where(item => string.Equals(item.Name, sourceLayerName, StringComparison.Ordinal)).ToArray();
        Check(catalog.Layers.Length == 1 && matchingLayers.Length == 1,
            "OpenFileGDB catalog includes exactly the driver's persisted source layer.");
        GdbMapLayerDescriptor layer = matchingLayers[0];
        Check(layer.Name == sourceLayerName && layer.GeometryType == sourceLayerGeometryType.ToString() &&
              layer.VectorType == "LineCollection" &&
              layer.GeometryTypeCode == (int)wkbGeometryType.wkbMultiLineStringZM &&
              layer.GeometryTypeCode == (int)sourceLayerGeometryType && layer.FeatureCount == 1 &&
              catalog.RasterSubdatasets is { Length: 0 },
            "OpenFileGDB catalog preserves the driver's exact persisted name, MultiLineStringZM layer type and count.");

        MapDocumentRequest documentRequest = MapDocumentRequestFor(projectPath, projectXml, createdMap);
        GdbMapImportResponse imported = MapTreeService.ImportGdbVector(new(documentRequest, projectRevision, captured));
        Check(imported.ImportedLayers.SequenceEqual(catalog.Layers) &&
              imported.ImportedRasterSubdatasets is { Length: 0 } && SameSource(imported.Source, captured),
            "Import commits the source-backed vector-only dataset and returns the exact nested empty raster catalog.");

        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement serializedLayer = visualization.Descendants("Node").Single(node =>
            (string?)node.Attribute("Type") == "GdbVectorLayer" &&
            (string?)node.Attribute("GdbLayerName") == sourceLayerName);
        serializedLayer.SetAttributeValue("Name", "Visible route label");
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

        MapDocumentMutationReceipt currentReceipt = imported.Receipt with
        {
            VisualizationRevision = Hash(File.ReadAllBytes(visualizationPath))
        };
        MapTreeRequest mapRequest = MapTreeRequestFor(projectPath, projectXml, currentReceipt);
        MapTreeSnapshot tree = MapTreeService.Load(mapRequest);
        CatalogTreeNode node = FindGdbLayer(tree.Roots, "Visible route label");
        CatalogTreeNodeLocator locator = node.Locator ??
            throw new InvalidOperationException("The imported GDB vector row has no exact source locator.");
        CatalogTreeProperty[] nodeProperties = node.Properties ?? [];
        Check(locator.NodeType == "GdbVectorLayer" && locator.MapType == "GdbVectorLayer" &&
              locator.NodeName == "Visible route label" && nodeProperties.Any(property =>
                  property.Id == "Source/GdbLayerName" && property.Value == sourceLayerName),
            "The persisted display name remains independent from the source GDB layer name and context type.");

        GdbMapSourceLoadResponse loaded = GdbMapSourceService.Load(new(mapRequest,
            locator, captured.Revision));
        Check(loaded.Node.NodeName == "Visible route label" && loaded.Layer.Name == sourceLayerName &&
              loaded.Layer.GeometryTypeCode == (int)sourceLayerGeometryType && loaded.Data.Count == 1 &&
              loaded.Data.Features.Single().SourceOrdinal == 0 &&
              loaded.Data.Features.Single().Geometry.GeometryTypeCode == (int)sourceLayerGeometryType,
            "The exact renamed display row resolves and returns the original GDB layer by its persisted source name.");
        GdbMapSourceGeometry[] sourceLines = FlattenGeometries(loaded.Data.Features.Single().Geometry)
            .Where(geometry => geometry.GeometryTypeCode == (int)wkbGeometryType.wkbLineStringZM).ToArray();
        Check(sourceLines.Length == 1, "The persisted MultiLineStringZM feature retains its source LineStringZM component.");
        GdbMapSourceVertex[] vertices = sourceLines[0].Vertices;
        string vertexDiagnostics = DescribeVertices(vertices);
        string projectionDiagnostics = $"status={loaded.Data.ProjectionStatus}; " +
            $"sourceWKT={loaded.Data.SourceProjectionWKT}; targetWKT={loaded.Data.TargetProjectionWKT}; " +
            $"geometry={sourceLines[0].GeometryType}[{sourceLines[0].GeometryTypeCode}]";
        Check(vertices.Length == 2,
            $"The persisted XYZM line has two coordinates. Actual: {vertexDiagnostics}; {projectionDiagnostics}");
        Check(vertices.All(vertex => vertex.Z.HasValue),
            $"OpenFileGDB retains the Z ordinate on every XYZM source vertex. Actual: {vertexDiagnostics}; {projectionDiagnostics}");
        Check(vertices.All(vertex => vertex.M.HasValue),
            $"OpenFileGDB retains the M ordinate on every XYZM source vertex. Actual: {vertexDiagnostics}; {projectionDiagnostics}");
        Check(vertices.Length == persistedVertices.Length && vertices.Select(vertex =>
                  (vertex.SourceX, vertex.SourceY)).SequenceEqual(persistedVertices.Select(vertex =>
                  (vertex.X, vertex.Y))),
            $"XYZM source X/Y ordinates match the OpenFileGDB reopen readback exactly. Persisted: {DescribePersistedVertices(persistedVertices)}; actual: {vertexDiagnostics}; {projectionDiagnostics}");
        Check(vertices[0] is { Z: 12.5, M: 100.25 } && vertices[1] is { Z: 14.75, M: 101.5 },
            $"XYZM source Z/M ordinates match the values written to OGR. Actual: {vertexDiagnostics}; {projectionDiagnostics}");
        var sourceProjection = new WKTProjection(loaded.Data.SourceProjectionWKT ??
            throw new InvalidDataException("The reopened OpenFileGDB source has no projection WKT."));
        var targetProjection = new EPSGProjection(32650);
        Point[] independentlyProjected = persistedVertices.Select(vertex => Projector.TransformPoint(
            sourceProjection, targetProjection, new Point(vertex.X, vertex.Y))).ToArray();
        Check(loaded.Data.ProjectionStatus == "projected" && vertices.Zip(independentlyProjected).All(pair =>
                  double.IsFinite(pair.First.X) && double.IsFinite(pair.First.Y) &&
                  Near(pair.First.X, pair.Second.X, 0.01) && Near(pair.First.Y, pair.Second.Y, 0.01)) &&
              Near(independentlyProjected[0].X, 413407.3219726745, 0.01) &&
              Near(independentlyProjected[0].Y, 4317252.16462973, 0.01),
            $"Projected XY matches an independent EPSG:4326-to-32650 transform of persisted traditional GIS-order XY. Independent: {DescribePoints(independentlyProjected)}; actual: {vertexDiagnostics}; {projectionDiagnostics}");
        CheckGdbAttributes(loaded.Data.Features.Single().Attributes);

        GdbMapRendererCapture renderer = GdbMapSourceService.CreateRendererCapture(mapRequest, locator, captured.Revision);
        GdbMapSourceService.VerifyRendererCapture(mapRequest, locator, renderer);
        Check(renderer.GdbLayerName == sourceLayerName && renderer.GdbVectorType == "LineCollection" &&
              renderer.SourceFeatureIndices is { Length: 1 } indices && indices[0] == 0 &&
              renderer.Renderer is Geospatial.Rendering.Layers.PolylineRenderLayer,
            "The exact persisted GDB source builds the retained line renderer with its source feature ordinal.");
        GdbMapSourceService.VerifySource(captured);

        File.Delete(transientLock);
        string changedFile = Path.Combine(gdbPath, "new-source-content.bin");
        File.WriteAllBytes(changedFile, [1, 2, 3, 4]);
        Expect<SourceFileChangedException>(() => GdbMapSourceService.VerifySource(captured),
            "Adding stable source content after capture invalidates the full directory manifest.");
        File.Delete(changedFile);
        Console.WriteLine("Real OpenFileGDB vector source preserves exact directory identity, ISO XYZM, typed fields, display/source names and renderer ownership.");
        GdbMapSourceService.VerifySource(captured);
        ExportAcceptanceFixtureIfRequested(root, projectPath, gdbPath, captured, imported.Receipt,
            sourceLayerName: layer.Name, sourceVectorType: layer.VectorType,
            displayLayerName: "Visible route label");
    }

    private static (string Name, wkbGeometryType GeometryType) CreateOpenFileGdbFixture(string path)
    {
        using OSGeo.GDAL.Driver metadataDriver = OSGeo.GDAL.Gdal.GetDriverByName("OpenFileGDB") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no OpenFileGDB metadata driver.");
        string? createCapability = metadataDriver.GetMetadataItem("DCAP_CREATE", "");
        Check(string.Equals(createCapability, "YES", StringComparison.OrdinalIgnoreCase),
            "The packaged OpenFileGDB driver advertises real dataset creation for the fixture.");

        using Driver driver = Ogr.GetDriverByName("OpenFileGDB") ??
            throw new InvalidOperationException("The packaged GDAL runtime has no OpenFileGDB driver.");

        using DataSource dataSource = driver.CreateDataSource(path, null) ??
            throw new InvalidOperationException("OpenFileGDB could not create the real fixture dataset.");
        using var spatialReference = new SpatialReference("");
        Check(spatialReference.ImportFromEPSG(4326) == 0,
            "The OGR source fixture uses a real EPSG:4326 spatial reference.");
        spatialReference.SetAxisMappingStrategy(AxisMappingStrategy.OAMS_TRADITIONAL_GIS_ORDER);
        string[] layerOptions = ["TARGET_ARCGIS_VERSION=ARCGIS_PRO_3_2_OR_LATER"];
        using Layer layer = dataSource.CreateLayer("Route_XYZM", spatialReference,
            wkbGeometryType.wkbMultiLineStringZM, layerOptions) ??
            throw new InvalidOperationException("OpenFileGDB could not create the ISO XYZM multiline layer.");
        string persistedName = layer.GetName();
        wkbGeometryType persistedType = layer.GetGeomType();
        Check(persistedName == "Route_XYZM" && persistedType == wkbGeometryType.wkbMultiLineStringZM,
            $"OpenFileGDB preserves the fixture's requested source name and MultiLineStringZM layer declaration; received {persistedName} [{persistedType}].");

        CreateField(layer, "LargeID", FieldType.OFTInteger64);
        CreateField(layer, "Ratio", FieldType.OFTReal);
        using (var enabledField = new FieldDefn("Enabled", FieldType.OFTInteger))
        {
            enabledField.SetSubType(FieldSubType.OFSTBoolean);
            Check(layer.CreateField(enabledField, 1) == 0, "OpenFileGDB creates a real Boolean-subtyped field.");
        }
        CreateField(layer, "Observed", FieldType.OFTDateTime);
        CreateField(layer, "NullText", FieldType.OFTString);
        CreateField(layer, "UnsetText", FieldType.OFTString);

        using FeatureDefn definition = layer.GetLayerDefn();
        using var feature = new Feature(definition);
        feature.SetFieldInteger64(definition.GetFieldIndex("LargeID"), 9_223_372_036_854_775_000L);
        feature.SetField("Ratio", 3.141592653589793);
        feature.SetField("Enabled", 1);
        feature.SetField("Observed", 2026, 10, 19, 13, 45, 12.5f, 100);
        feature.SetFieldNull(definition.GetFieldIndex("NullText"));
        // UnsetText deliberately remains unset on the newly created feature.
        using var geometry = new OSGeo.OGR.Geometry(wkbGeometryType.wkbLineStringZM);
        geometry.AddPointZM(116.0, 39.0, 12.5, 100.25);
        geometry.AddPointZM(116.1, 39.1, 14.75, 101.5);
        using var multiGeometry = new OSGeo.OGR.Geometry(wkbGeometryType.wkbMultiLineStringZM);
        multiGeometry.AddGeometry(geometry);
        Check(feature.SetGeometry(multiGeometry) == 0 && layer.CreateFeature(feature) == 0,
            "OpenFileGDB writes an actual XYZM line feature with the source attributes.");
        layer.SyncToDisk();
        dataSource.FlushCache();
        return (persistedName, persistedType);
    }

    private static PersistedXYZMVertex[] VerifyOpenFileGdbReopen(string path, string expectedName,
        wkbGeometryType expectedGeometryType)
    {
        using DataSource reopened = Ogr.OpenShared(path, 0) ??
            throw new InvalidDataException("OpenFileGDB could not reopen the source fixture after creation.");
        Check(reopened.GetLayerCount() == 1,
            "The persisted OpenFileGDB fixture reopens with exactly one source layer.");
        using Layer layer = reopened.GetLayerByIndex(0) ??
            throw new InvalidDataException("OpenFileGDB could not reopen the persisted source layer.");
        Check(layer.GetName() == expectedName && layer.GetGeomType() == expectedGeometryType &&
              layer.GetFeatureCount(1) == 1,
            "The reopened OpenFileGDB layer retains the exact source name, geometry declaration and feature count.");
        using Feature feature = layer.GetNextFeature() ??
            throw new InvalidDataException("OpenFileGDB did not return the persisted XYZM feature on reopen.");
        using OgrGeometry multiLine = feature.GetGeometryRef() ??
            throw new InvalidDataException("The persisted XYZM feature has no OGR geometry on reopen.");
        Check(multiLine.GetGeometryType() == wkbGeometryType.wkbMultiLineStringZM &&
              multiLine.Is3D() != 0 && multiLine.IsMeasured() != 0 && multiLine.GetGeometryCount() == 1,
            $"The reopened feature geometry retains MultiLineStringZM type, Z/M dimensions and one component; received {multiLine.GetGeometryType()}, hasZ={multiLine.Is3D() != 0}, hasM={multiLine.IsMeasured() != 0}.");
        using OgrGeometry line = multiLine.GetGeometryRef(0);
        Check(line.GetGeometryType() == wkbGeometryType.wkbLineStringZM &&
              line.Is3D() != 0 && line.IsMeasured() != 0 && line.GetPointCount() == 2,
            $"The reopened component retains LineStringZM type, Z/M dimensions and two points; received {line.GetGeometryType()}, hasZ={line.Is3D() != 0}, hasM={line.IsMeasured() != 0}, points={line.GetPointCount()}.");
        var vertices = new PersistedXYZMVertex[line.GetPointCount()];
        var values = new double[4];
        for (int index = 0; index < vertices.Length; index++)
        {
            line.GetPointZM(index, values);
            vertices[index] = new(values[0], values[1], values[2], values[3]);
        }
        Check(vertices[0].Z == 12.5 && vertices[0].M == 100.25 &&
              vertices[1].Z == 14.75 && vertices[1].M == 101.5,
            $"OpenFileGDB persists declared Z/M values exactly. Actual reopen values: {DescribePersistedVertices(vertices)}.");
        return vertices;
    }

    private static IEnumerable<GdbMapSourceGeometry> FlattenGeometries(GdbMapSourceGeometry geometry)
    {
        yield return geometry;
        foreach (GdbMapSourceGeometry child in geometry.Children)
            foreach (GdbMapSourceGeometry nested in FlattenGeometries(child))
                yield return nested;
    }

    private static string DescribeVertices(GdbMapSourceVertex[] vertices) => vertices.Length == 0
        ? "<none>"
        : string.Join("; ", vertices.Select((vertex, index) =>
            $"v{index}: sourceXY=({Format(vertex.SourceX)},{Format(vertex.SourceY)}), " +
            $"hasZ={vertex.Z.HasValue}, Z={Format(vertex.Z)}, hasM={vertex.M.HasValue}, M={Format(vertex.M)}, " +
            $"projectedXY=({Format(vertex.X)},{Format(vertex.Y)})"));

    private static string Format(double? value) => value?.ToString("R", CultureInfo.InvariantCulture) ?? "<null>";

    private static string DescribePersistedVertices(PersistedXYZMVertex[] vertices) => vertices.Length == 0
        ? "<none>"
        : string.Join("; ", vertices.Select((vertex, index) =>
            $"v{index}: sourceXY=({Format(vertex.X)},{Format(vertex.Y)}), Z={Format(vertex.Z)}, M={Format(vertex.M)}"));

    private static string DescribePoints(Point[] points) => points.Length == 0
        ? "<none>"
        : string.Join("; ", points.Select((point, index) =>
            $"v{index}: ({Format(point.X)},{Format(point.Y)})"));

    private static bool Near(double actual, double expected, double tolerance) =>
        double.IsFinite(actual) && Math.Abs(actual - expected) <= tolerance;

    private static void CreateField(Layer layer, string name, FieldType type)
    {
        using var field = new FieldDefn(name, type);
        Check(layer.CreateField(field, 1) == 0, $"OpenFileGDB creates the {type} field {name}.");
    }

    private static void CheckGdbAttributes(GdbMapSourceAttribute[] attributes)
    {
        string actualAttributes = JsonSerializer.Serialize(attributes);
        GdbMapSourceAttribute large = attributes.Single(attribute => attribute.ColumnName == "LargeID");
        GdbMapSourceAttribute ratio = attributes.Single(attribute => attribute.ColumnName == "Ratio");
        GdbMapSourceAttribute enabled = attributes.Single(attribute => attribute.ColumnName == "Enabled");
        GdbMapSourceAttribute observed = attributes.Single(attribute => attribute.ColumnName == "Observed");
        GdbMapSourceAttribute nullText = attributes.Single(attribute => attribute.ColumnName == "NullText");
        GdbMapSourceAttribute unsetText = attributes.Single(attribute => attribute.ColumnName == "UnsetText");
        Check(large.Type.Equals("Integer64", StringComparison.OrdinalIgnoreCase) &&
              large.Value == "9223372036854775000" && large.IsSet && !large.IsNull,
            "Integer64 source attributes retain their exact decimal lexeme without a Double conversion. Actual: " + actualAttributes);
        Check(ratio.Type.Equals("Real", StringComparison.OrdinalIgnoreCase) &&
              ratio.Value == 3.141592653589793.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
            "Real source attributes retain the invariant round-trip precision.");
        Check(enabled.Type == "Integer" && enabled.BooleanValue is null && enabled.Value == "1",
            "The persisted OpenFileGDB integer field is reported with its actual type, without inventing a Boolean subtype. Actual: " + actualAttributes);
        Check(observed.Type.Equals("DateTime", StringComparison.OrdinalIgnoreCase) &&
              observed.Value == "2026-10-19T13:45:12.5" && observed.TimeZoneFlag == 100,
            "DateTime source components and the OGR timezone flag survive without inventing an offset.");
        Check(nullText.IsSet && nullText.IsNull && nullText.Value is null && nullText.BooleanValue is null &&
              unsetText.IsSet && unsetText.IsNull && unsetText.Value is null,
            "OpenFileGDB reopens both absent and explicitly NULL text fields as stored NULL values.");
    }

    private static void VerifyInMemoryAttributeSemantics()
    {
        // OpenFileGDB persists an Integer field rather than OFSTBoolean, and
        // normalizes an unset nullable field to NULL. Exercise the reader's
        // distinct OGR states before persistence rather than inventing those
        // states in the directory-backed dataset.
        using Driver driver = Ogr.GetDriverByName("MEM") ??
            throw new InvalidOperationException("The packaged OGR runtime has no MEM vector driver.");
        using DataSource source = driver.CreateDataSource("typed-attribute-states", null) ??
            throw new InvalidOperationException("OGR could not create the in-memory attribute fixture.");
        using Layer layer = source.CreateLayer("states", null, wkbGeometryType.wkbNone, null) ??
            throw new InvalidOperationException("OGR could not create the attribute fixture layer.");
        using (var boolean = new FieldDefn("Enabled", FieldType.OFTInteger))
        {
            boolean.SetSubType(FieldSubType.OFSTBoolean);
            Check(layer.CreateField(boolean, 0) == 0, "OGR retains a genuine Boolean-subtyped field.");
        }
        CreateField(layer, "NullText", FieldType.OFTString);
        CreateField(layer, "UnsetText", FieldType.OFTString);
        using FeatureDefn definition = layer.GetLayerDefn();
        using var feature = new Feature(definition);
        feature.SetField("Enabled", 1);
        feature.SetFieldNull(definition.GetFieldIndex("NullText"));
        GdbMapSourceAttribute[] attributes = GdbMapSourceService.ReadAttributes(feature, definition);
        GdbMapSourceAttribute enabled = attributes.Single(attribute => attribute.ColumnName == "Enabled");
        GdbMapSourceAttribute nullText = attributes.Single(attribute => attribute.ColumnName == "NullText");
        GdbMapSourceAttribute unsetText = attributes.Single(attribute => attribute.ColumnName == "UnsetText");
        Check(enabled.Type == "Boolean" && enabled.BooleanValue == true && enabled.Value is null,
            "A genuine OGR Boolean subtype remains a Boolean value in the typed protocol.");
        Check(nullText.IsSet && nullText.IsNull && nullText.Value is null &&
              !unsetText.IsSet && !unsetText.IsNull && unsetText.Value is null,
            "Distinct OGR NULL and unset states survive the typed attribute reader.");
    }

    private static void ExportAcceptanceFixtureIfRequested(string sourceRoot, string projectPath,
        string gdbPath, GdbMapSourceIdentity capturedSource, MapDocumentMutationReceipt receipt,
        string sourceLayerName, string sourceVectorType, string displayLayerName)
    {
        string? configured = Environment.GetEnvironmentVariable("HECRAS_GDB_SOURCE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configured)) return;

        string sourceDirectory = SourceFilePaths.Canonical(Path.GetFullPath(sourceRoot));
        string destination = SourceFilePaths.Canonical(Path.GetFullPath(configured));
        if (Directory.Exists(destination) || File.Exists(destination) ||
            IsPathAtOrBelow(destination, sourceDirectory) || IsPathAtOrBelow(sourceDirectory, destination))
            throw new IOException("The GDB source acceptance destination must be a new directory outside the source fixture.");

        string? destinationParent = Path.GetDirectoryName(destination);
        if (string.IsNullOrWhiteSpace(destinationParent))
            throw new IOException("The GDB source acceptance destination has no parent directory.");
        Directory.CreateDirectory(destinationParent);
        string staging = destination + ".staging-" + Guid.NewGuid().ToString("N");
        bool moved = false;
        try
        {
            Directory.CreateDirectory(staging);
            File.Copy(projectPath, Path.Combine(staging, "project.ras"), overwrite: false);
            File.Copy(Path.ChangeExtension(projectPath, ".vis"), Path.Combine(staging, "project.vis"), overwrite: false);

            string stagedGdb = Path.Combine(staging, "typed-zm.gdb");
            Directory.CreateDirectory(stagedGdb);
            foreach (GdbMapSourceFileRevision file in capturedSource.Files)
            {
                string relative = file.RelativePath.Replace('/', Path.DirectorySeparatorChar);
                if (Path.IsPathRooted(relative) || relative.Split(Path.DirectorySeparatorChar)
                        .Any(segment => segment is "" or "." or ".."))
                    throw new InvalidDataException("The GDB acceptance manifest contains an invalid relative path.");
                string sourceFile = Path.Combine(capturedSource.SourcePath, relative);
                string stagedFile = Path.Combine(stagedGdb, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(stagedFile)!);
                File.Copy(sourceFile, stagedFile, overwrite: false);
            }

            GdbMapSourceService.VerifySource(capturedSource);
            Directory.Move(staging, destination);
            moved = true;

            string copiedGdb = Path.Combine(destination, "typed-zm.gdb");
            GdbMapSourceIdentity copiedSource = GdbMapSourceService.CaptureSource(copiedGdb);
            if (!SameManifestFiles(capturedSource.Files, copiedSource.Files))
                throw new SourceFileChangedException();

            var metadata = new
            {
                schema = "hecras.gdb-map-source-acceptance.v1",
                projectPath = "project.ras",
                visualizationPath = "project.vis",
                sourceDirectory = "typed-zm.gdb",
                mapID = MapID,
                mapIndex = receipt.MapIndex,
                mapName = receipt.MapName,
                mapType = receipt.MapType,
                sourceLayerName,
                displayLayerName,
                vectorType = sourceVectorType,
                featureCount = 1,
                expectedRasterSubdatasetCount = 0,
                sourceRevision = copiedSource.Revision,
                sourceFiles = copiedSource.Files.Select(file => new
                {
                    relativePath = file.RelativePath,
                    length = file.Length,
                    revision = file.Revision
                }).ToArray()
            };
            string json = JsonSerializer.Serialize(metadata, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(Path.Combine(destination, "acceptance.json"), json + Environment.NewLine,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            GdbMapSourceService.VerifySource(copiedSource);
        }
        catch
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            if (moved && Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
            throw;
        }
    }

    private static bool SameManifestFiles(GdbMapSourceFileRevision[] expected,
        GdbMapSourceFileRevision[] actual) => expected.Length == actual.Length &&
        expected.Zip(actual).All(pair =>
            string.Equals(pair.First.RelativePath, pair.Second.RelativePath, StringComparison.Ordinal) &&
            pair.First.Length == pair.Second.Length &&
            string.Equals(pair.First.Revision, pair.Second.Revision, StringComparison.OrdinalIgnoreCase));

    private static bool IsPathAtOrBelow(string path, string parent)
    {
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        string normalizedParent = Path.TrimEndingDirectorySeparator(parent);
        return string.Equals(path, normalizedParent, comparison) ||
            path.StartsWith(normalizedParent + Path.DirectorySeparatorChar, comparison);
    }

    private static CatalogTreeNode FindGdbLayer(IEnumerable<CatalogTreeNode> nodes, string name)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            if (node.Locator is { NodeType: "GdbVectorLayer" } locator && locator.NodeName == name) return node;
            if (node.Children is { Length: > 0 })
            {
                try { return FindGdbLayer(node.Children, name); }
                catch (KeyNotFoundException) { }
            }
        }
        throw new KeyNotFoundException($"The map tree has no GDB vector layer named '{name}'.");
    }

    private static MapDocumentRequest MapDocumentRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml,
        Hash(Encoding.UTF8.GetBytes(projectXml)), Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))),
        "Project", MapID: MapID, MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);

    private static MapTreeRequest MapTreeRequestFor(string projectPath, string projectXml,
        MapDocumentMutationReceipt map) => new(projectPath, projectXml, Hash(Encoding.UTF8.GetBytes(projectXml)),
        MapID, map.MapIndex, map.MapName, map.MapType,
        Hash(File.ReadAllBytes(Path.ChangeExtension(projectPath, ".vis"))));

    private static bool SameSource(GdbMapSourceIdentity first, GdbMapSourceIdentity second) =>
        Path.GetFullPath(first.SourcePath) == Path.GetFullPath(second.SourcePath) &&
        string.Equals(first.Revision, second.Revision, StringComparison.OrdinalIgnoreCase) &&
        first.Files.Length == second.Files.Length && first.Files.Zip(second.Files).All(pair =>
            pair.First.RelativePath == pair.Second.RelativePath && pair.First.Length == pair.Second.Length &&
            string.Equals(pair.First.Revision, pair.Second.Revision, StringComparison.OrdinalIgnoreCase));

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static void DisposeProject(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ": " + message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("hecras-gdb-source-");
        public string FullName => directory.FullName;
        public void Dispose() => directory.Delete(recursive: true);
    }
}
