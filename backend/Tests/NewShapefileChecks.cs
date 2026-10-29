using Utility.Logging;
using Geospatial.Vectors;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.Features;
using Geospatial.IO;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class NewShapefileChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string root = temporary.FullName;
        string projectPath = Path.Combine(root, "Projected.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        project.Save();
        MapResultChartService.DisposeProject(project);
        string projectXml = File.ReadAllText(projectPath);
        string projectRevision = Hash(File.ReadAllBytes(projectPath));
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt createdMap = MapTreeService.CreateMap(new(projectPath, projectXml,
            projectXmlSHA, null, "Project", Name: "Project map"));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");

        string[] shapeTypes = ["Point", "Polyline", "Polygon"];
        string[] expectedMapTypes = ["PointsVector", "PolylinesVector", "PolygonsVector"];
        string visualizationRevision = createdMap.VisualizationRevision;
        List<NewShapefileCreateReceipt> receipts = [];
        for (int i = 0; i < shapeTypes.Length; i++)
        {
            string destination = Path.Combine(root, "Created-" + shapeTypes[i] + ".shp");
            NewShapefileCreateRequest request = Request(projectPath, projectXml, projectXmlSHA,
                projectRevision, visualizationRevision, createdMap, destination, shapeTypes[i], "Project");
            byte[] beforeCreateVisualization = File.ReadAllBytes(visualizationPath);
            NewShapefileCreateReceipt receipt = NewShapefileService.Create(request);
            Check(File.ReadAllBytes(visualizationPath).SequenceEqual(beforeCreateVisualization),
                "File creation keeps .vis unchanged until the existing map import transaction runs.");
            Check(receipt.ShapeType == shapeTypes[i] && receipt.ProjectionChoice == "Project" &&
                receipt.ProjectionWKT is { Length: > 0 }, "The creation receipt records its explicit geometry and project projection.");
            CheckFamily(receipt.Family, destination, projectionExists: true);
            CheckEmptySource(destination, expectedMapTypes[i]);

            byte[][] familyBytes = FamilyPaths(destination).Select(File.ReadAllBytes).ToArray();
            NewShapefileCreateReceipt replay = NewShapefileService.Create(request);
            Check(replay.Family == receipt.Family && FamilyPaths(destination).Select(File.ReadAllBytes)
                    .Zip(familyBytes).All(pair => pair.First.SequenceEqual(pair.Second)),
                "Repeating one operation ID returns its receipt without rewriting any sidecar.");

            MapDocumentRequest map = MapRequest(projectPath, projectXml, projectXmlSHA,
                visualizationRevision, createdMap, request.Map.MapID!);
            MapDocumentMutationReceipt imported = MapTreeService.ImportShapefileVector(new(map,
                destination, projectRevision, receipt.Family));
            visualizationRevision = imported.VisualizationRevision;
            receipts.Add(receipt);
        }

        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement[] layers = visualization.Root!.Element("Maps")!.Elements("Map").Single()
            .Descendants("Node").Where(node => (string?)node.Attribute("Type") == "MapLayer").ToArray();
        Check(layers.Length == 3 && expectedMapTypes.All(type => layers.Any(node =>
            (string?)node.Attribute("MapType") == type && (string?)node.Attribute("IsChecked") == "true")),
            "The real existing Shapefile import operation persists checked Point, Polyline and Polygon map rows.");

        string occupiedPath = Path.Combine(root, "Occupied.shp");
        byte[] priorDbf = [0x10, 0x20, 0x30];
        File.WriteAllBytes(ShapefileIO.DBFFilename(occupiedPath), priorDbf);
        NewShapefileCreateRequest occupiedRequest = Request(projectPath, projectXml, projectXmlSHA,
            projectRevision, visualizationRevision, createdMap, occupiedPath, "Point", "Project");
        Expect<IOException>(() => NewShapefileService.Create(occupiedRequest),
            "An existing sidecar blocks the complete family before writing.");
        Check(File.ReadAllBytes(ShapefileIO.DBFFilename(occupiedPath)).SequenceEqual(priorDbf) &&
            !File.Exists(occupiedPath) && !File.Exists(ShapefileIO.SHXFilename(occupiedPath)),
            "A sidecar collision is no-clobber and creates no partial public family.");

        string stalePath = Path.Combine(root, "Stale.ras");
        Project staleProject = Project.CreateNew(stalePath, UnitSystem.SI);
        staleProject.Save();
        MapResultChartService.DisposeProject(staleProject);
        string staleXml = File.ReadAllText(stalePath);
        string staleRevision = Hash(File.ReadAllBytes(stalePath));
        MapDocumentMutationReceipt staleMap = MapTreeService.CreateMap(new(stalePath, staleXml,
            Hash(Encoding.UTF8.GetBytes(staleXml)), null, "Project"));
        string staleDestination = Path.Combine(root, "Wrong-Projection.shp");
        NewShapefileCreateRequest wrongProjection = Request(stalePath, staleXml,
            Hash(Encoding.UTF8.GetBytes(staleXml)), staleRevision, staleMap.VisualizationRevision,
            staleMap, staleDestination, "Point", "Project");
        Expect<ArgumentException>(() => NewShapefileService.Create(wrongProjection),
            "A projected Shapefile cannot silently use a missing/local project projection.");
        Check(!File.Exists(staleDestination) && !File.Exists(ShapefileIO.DBFFilename(staleDestination)),
            "An invalid projection selection fails before publishing any sidecar.");

        string localDestination = Path.Combine(root, "Local-Coordinates.shp");
        NewShapefileCreateRequest localCoordinates = Request(stalePath, staleXml,
            Hash(Encoding.UTF8.GetBytes(staleXml)), staleRevision, staleMap.VisualizationRevision,
            staleMap, localDestination, "Point", "Local");
        NewShapefileCreateReceipt localReceipt = NewShapefileService.Create(localCoordinates);
        Check(localReceipt.ProjectionChoice == "Local" && localReceipt.ProjectionWKT is null,
            "A Local-coordinate project records its explicit projection choice without inventing a CRS.");
        CheckFamily(localReceipt.Family, localDestination, projectionExists: false);
        CheckEmptySource(localDestination, "PointsVector");

        CheckCommitBoundary(root, stalePath, staleXml, staleRevision, staleMap);

        Console.WriteLine("New Shapefile creation uses the retained format writer, verifies all real empty shape families and projection, preserves no-clobber semantics, and feeds the existing map import transaction.");
    }

    private static void CheckCommitBoundary(string root, string projectPath, string projectXml,
        string projectRevision, MapDocumentMutationReceipt map)
    {
        string rollbackDestination = Path.Combine(root, "Rollback-boundary.shp");
        NewShapefileCreateRequest rollbackRequest = Request(projectPath, projectXml,
            Hash(Encoding.UTF8.GetBytes(projectXml)), projectRevision, map.VisualizationRevision,
            map, rollbackDestination, "Point", "Local");
        string rollbackStage = Path.Combine(root, "rollback-stage", "Rollback-boundary.shp");
        Directory.CreateDirectory(Path.GetDirectoryName(rollbackStage)!);
        WriteEmptyStagedSource(rollbackStage);
        MapSourceFamilyCapture rollbackStageFamily = MapTreeService.CaptureShapefileFamily(rollbackStage);
        NewShapefileCreateReceipt rollbackReceipt = MakeReceipt(rollbackRequest,
            MapSourceIdentity.RebaseStagedShapefileFamily(rollbackStageFamily, rollbackDestination));
        byte[] externalBytes = [0x77, 0x88, 0x99];
        int moveCount = 0;
        IOException? rollbackFailure = null;
        try
        {
            _ = NewShapefileService.CommitPreparedFamily(rollbackStage, rollbackDestination,
                rollbackStageFamily, rollbackReceipt, () => { }, (source, destination) =>
                {
                    File.Move(source, destination);
                    moveCount++;
                    if (moveCount == 2) File.WriteAllBytes(destination, externalBytes);
                });
        }
        catch (IOException error)
        {
            rollbackFailure = error;
        }

        string rollbackDbf = ShapefileIO.DBFFilename(rollbackDestination);
        bool reportsPreservedComponent = rollbackFailure is not null &&
            rollbackFailure.Message.Contains("preserved", StringComparison.OrdinalIgnoreCase) &&
            rollbackFailure.Message.Contains(rollbackDbf, StringComparison.Ordinal);
        Check(reportsPreservedComponent,
            "A partial publication reports the path of a component changed by another writer.");
        Check(File.Exists(rollbackDbf) && File.ReadAllBytes(rollbackDbf).SequenceEqual(externalBytes) &&
            !File.Exists(ShapefileIO.SHXFilename(rollbackDestination)) && !File.Exists(rollbackDestination),
            "Rollback deletes only unchanged sidecars from this operation and preserves externally modified bytes.");

        string committedDestination = Path.Combine(root, "Commit-boundary.shp");
        NewShapefileCreateRequest committedRequest = Request(projectPath, projectXml,
            Hash(Encoding.UTF8.GetBytes(projectXml)), projectRevision, map.VisualizationRevision,
            map, committedDestination, "Point", "Local");
        string committedStage = Path.Combine(root, "commit-stage", "Commit-boundary.shp");
        Directory.CreateDirectory(Path.GetDirectoryName(committedStage)!);
        WriteEmptyStagedSource(committedStage);
        MapSourceFamilyCapture committedStageFamily = MapTreeService.CaptureShapefileFamily(committedStage);
        NewShapefileCreateReceipt committedReceipt = MakeReceipt(committedRequest,
            MapSourceIdentity.RebaseStagedShapefileFamily(committedStageFamily, committedDestination));
        NewShapefileCreateReceipt returnedReceipt = NewShapefileService.CommitPreparedFamily(
            committedStage, committedDestination, committedStageFamily, committedReceipt, () => { },
            (source, destination) =>
            {
                File.Move(source, destination);
                if (Path.GetExtension(destination).Equals(".shp", StringComparison.OrdinalIgnoreCase))
                    File.WriteAllBytes(destination, [0xAA]);
            });
        Check(ReferenceEquals(returnedReceipt, committedReceipt) && File.Exists(committedDestination) &&
            File.ReadAllBytes(committedDestination).SequenceEqual(new byte[] { 0xAA }) &&
            File.Exists(ShapefileIO.SHXFilename(committedDestination)) &&
            File.Exists(ShapefileIO.DBFFilename(committedDestination)),
            "The completed .shp rename returns its prepared receipt without a fallible post-commit recapture that could delete the family.");
    }

    private static void WriteEmptyStagedSource(string path)
    {
        OperationResult result = ShapefileIO.Write(path, new List<Point>());
        Check(result.Result, "The retained writer prepares a real staged empty Point Shapefile for commit-boundary checks.");
    }

    private static NewShapefileCreateReceipt MakeReceipt(NewShapefileCreateRequest request,
        MapSourceFamilyCapture family) => new(request.OperationID, request.ProjectSessionID,
            request.MapID, Path.GetFullPath(request.Map.ProjectPath), request.ExpectedProjectRevision,
            request.Map.ExpectedVisualizationRevision, request.Map.MapIndex, request.Map.MapName,
            request.Map.MapType ?? request.Map.Kind, request.DestinationPath, request.ShapeType,
            request.ProjectionChoice, null, family, DateTimeOffset.UtcNow.ToString("O"));

    private static NewShapefileCreateRequest Request(string projectPath, string projectXml,
        string projectXmlSHA, string projectRevision, string? visualizationRevision,
        MapDocumentMutationReceipt map, string destination, string shapeType, string projectionChoice)
    {
        string mapID = Guid.NewGuid().ToString("D");
        var mapRequest = new MapDocumentRequest(projectPath, projectXml, projectXmlSHA,
            visualizationRevision, "Project", MapID: mapID, MapIndex: map.MapIndex,
            MapName: map.MapName, MapType: map.MapType);
        return new(mapRequest, projectRevision, Guid.NewGuid().ToString("D"), mapID,
            Guid.NewGuid().ToString("D"), destination, shapeType, projectionChoice);
    }

    private static MapDocumentRequest MapRequest(string projectPath, string projectXml,
        string projectXmlSHA, string? visualizationRevision,
        MapDocumentMutationReceipt map, string mapID) =>
        new(projectPath, projectXml, projectXmlSHA, visualizationRevision, "Project",
            MapID: mapID, MapIndex: map.MapIndex, MapName: map.MapName, MapType: map.MapType);

    private static void CheckEmptySource(string path, string expectedMapType)
    {
        MapShapefileSourceReadResult source = MapShapefileImportService.Read(path);
        Check(source.MapType == expectedMapType && source.FeatureCount == 0,
            "The retained Shapefile reader confirms the exact requested empty geometry type.");
    }

    private static string[] FamilyPaths(string path) => [path,
        ShapefileIO.SHXFilename(path), ShapefileIO.DBFFilename(path), ShapefileIO.PRJFilename(path)];

    private static void CheckFamily(MapSourceFamilyCapture family, string sourcePath, bool projectionExists)
    {
        Check(family.Family == "shapefile" &&
            SourceFilePaths.SameSourceFile(family.SourcePath, sourcePath) && family.Files.Length == 4 &&
            family.Files.Single(file => file.Role == "source") is { Required: true, Exists: true, Revision.Length: 64 } &&
            family.Files.Single(file => file.Role == "shx") is { Required: true, Exists: true, Revision.Length: 64 } &&
            family.Files.Single(file => file.Role == "dbf") is { Required: true, Exists: true, Revision.Length: 64 } &&
            family.Files.Single(file => file.Role == "prj") is { Required: false } prj && prj.Exists == projectionExists,
            "The receipt captures the real source, index, attribute and optional projection sidecars.");
        MapSourceIdentity.VerifyFamily(family);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

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
