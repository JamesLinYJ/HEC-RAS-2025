using System.Security.Cryptography;
using System.Text;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Hydraulics.Culverts;
using Ras.Layers;

/// <summary>
/// Exercises source-backed hover against the exact map rows and retained
/// vector renderers, including a parent-owned culvert draft and BCL ordinals.
/// </summary>
internal static partial class MapHoverModelVectorChecks
{
    internal static async Task RunAsync()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName);
        MapTreeRequest map = fixture.Map;
        CatalogTreeNode[] nodes = Flatten(MapTreeService.Load(map).Roots).ToArray();
        CatalogTreeNode geometryNode = nodes.Single(IsProjectGeometryNode);
        string geometryPath = geometryNode.Locator!.AssetID!;
        CatalogTreeNode boundaryNode = nodes.Single(IsProjectBoundaryNode);
        string boundaryPath = boundaryNode.Locator!.AssetID!;
        using (var boundary = new BoundaryCondition(boundaryPath))
        {
            var line = boundary.BoundaryConditionLines.Add(
                new Polyline(new Point[] { new(0, 0.5), new(1, 0.5) }));
            line.Name = "North boundary source line";
            boundary.Save();
        }
        using (var geometry = new Geometry(geometryPath))
        {
            var line = new Polyline(new Point[] { new(0, 0.5), new(1, 0.5) });
            geometry.CulvertBarrelLayer.Add(new CulvertBarrel
            {
                Name = "North culvert source name",
                Polyline = line,
                BarrelPropertyName = "",
                UpstreamInvert = 0,
                DownstreamInvert = 0,
                UpstreamOpeningName = "",
                DownstreamOpeningName = ""
            });
            geometry.Save();
        }

        nodes = Flatten(MapTreeService.Load(map).Roots).ToArray();
        geometryNode = nodes.Single(node => IsProjectGeometryNode(node) &&
            node.Locator is { AssetID: { } path } && SamePath(path, geometryPath));
        CatalogTreeNodeLocator geometryLocator = geometryNode.Locator
            ?? throw new InvalidDataException("The Geometry map row omitted its exact locator.");
        CatalogTreeNode culvertNode = nodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "CulvertBarrelLayer",
                ParentResultNodeType: null, ParentResultAssetID: null, ParentResultNodePath: null,
                ParentResultNodeName: null, ParentResultRevision: null,
                ParentGeometryAssetID: { } path }
            && SamePath(path, geometryPath));
        CatalogTreeNodeLocator culvertLocator = culvertNode.Locator
            ?? throw new InvalidDataException("The CulvertBarrel map row omitted its exact locator.");
        boundaryNode = nodes.Single(node =>
            IsProjectBoundaryNode(node) && node.Locator is { AssetID: { } path }
            && SamePath(path, boundaryPath));
        CatalogTreeNodeLocator boundaryLocator = boundaryNode.Locator
            ?? throw new InvalidDataException("The BoundaryCondition map row omitted its exact locator.");

        MapTreeMutationResult culvertVisible = MapTreeService.Perform(new(map, "visibility",
            Node: culvertLocator, Checked: true));
        map = map with { ExpectedVisualizationRevision = culvertVisible.VisualizationRevision };
        MapTreeMutationResult boundaryVisible = MapTreeService.Perform(new(map, "visibility",
            Node: boundaryLocator, Checked: true));
        map = map with { ExpectedVisualizationRevision = boundaryVisible.VisualizationRevision };

        // Visibility materializes source rows in the serialized .vis tree and
        // can therefore give the same source a different exact NodePath. All
        // subsequent requests must use locators from the committed tree.
        nodes = Flatten(MapTreeService.Load(map).Roots).ToArray();
        geometryNode = nodes.Single(node => IsProjectGeometryNode(node) &&
            node.Locator is { AssetID: { } path } && SamePath(path, geometryPath));
        geometryLocator = geometryNode.Locator
            ?? throw new InvalidDataException("The committed Geometry map row omitted its exact locator.");
        culvertNode = nodes.Single(node =>
            node.Locator is { RootName: "Geometries", NodeType: "CulvertBarrelLayer",
                ParentResultNodeType: null, ParentResultAssetID: null, ParentResultNodePath: null,
                ParentResultNodeName: null, ParentResultRevision: null,
                ParentGeometryAssetID: { } path }
            && SamePath(path, geometryPath));
        culvertLocator = culvertNode.Locator
            ?? throw new InvalidDataException("The committed CulvertBarrel map row omitted its exact locator.");
        boundaryNode = nodes.Single(node => IsProjectBoundaryNode(node) &&
            node.Locator is { AssetID: { } path } && SamePath(path, boundaryPath));
        boundaryLocator = boundaryNode.Locator
            ?? throw new InvalidDataException("The committed Boundary map row omitted its exact locator.");

        MapResultSourcesResult mapSources = MapResultChartService.Sources(new(map, []));
        MapGeometrySnapshot geometrySource = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(map, geometryLocator, PageSize: 1,
                SkipTopologyPage: true, SkipFlowAreasPage: true, SkipCulvertsPage: true));
        CatalogTreeNodeLocator? returnedCulvertLocator = geometrySource.CulvertsState.Locator;
        Check(returnedCulvertLocator is not null &&
              MapResultRenderService.SameLocator(returnedCulvertLocator, culvertLocator),
            "The exact saved map exposes the source CulvertBarrel child. " +
            $"Request locator: {System.Text.Json.JsonSerializer.Serialize(culvertLocator)}; " +
            $"Geometry response locator: {System.Text.Json.JsonSerializer.Serialize(returnedCulvertLocator)}.");

        var geometryModel = new GeometryCulvertModelRequest(geometryPath, "Geometry",
            map.ProjectPath, map.ProjectXml);
        GeometryCulvertSnapshot loadedDraft = await ModelEditorAdapter.LoadGeometryCulvertsAsync(
            new(geometryModel, SelectedBarrelIDs: ["barrel:source:0"]));
        GeometryCulvertSnapshot renamedDraft = await ModelEditorAdapter.EditGeometryCulvertsAsync(
            new(geometryModel, loadedDraft.Revision, loadedDraft.DraftState,
                new("setField", "barrel", ["barrel:source:0"], FieldID: "Name",
                    Value: "Uncommitted map label"), ["barrel:source:0"]));
        byte[] geometryBefore = File.ReadAllBytes(geometryPath);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] boundaryBefore = File.ReadAllBytes(boundaryPath);

        MapHoverModelVectorCapture draftCapture = CulvertCapture(geometrySource, culvertLocator,
            map, geometryModel, renamedDraft);
        MapHoverIdentifyEntry draftEntry = (await Identify(map, mapSources,
            "hover-culvert-parent-draft", new(0.5, 0.5),
            new(culvertLocator, "modelVector", draftCapture.SourcePath,
                draftCapture.SourceRevision, ModelVector: draftCapture))).Entries.Single();
        Check(draftEntry.Kind == "modelVector" && draftEntry.Label == "Uncommitted map label"
            && draftEntry.Value == "0" && draftEntry.ValueType == "culvertBarrel"
            && draftEntry.ElementIndex == 0 && draftEntry.MapType is null
            && draftEntry.ProfileIndex is null && draftEntry.MeshIndex is null,
            "Culvert hover uses the retained source renderer's exact feature ordinal and replays the captured parent draft name.");

        MapHoverModelVectorCapture savedCapture = CulvertCapture(geometrySource, culvertLocator,
            map, geometryModel, null);
        MapHoverIdentifyEntry savedEntry = (await Identify(map, mapSources,
            "hover-culvert-saved", new(0.5, 0.5),
            new(culvertLocator, "modelVector", savedCapture.SourcePath,
                savedCapture.SourceRevision, ModelVector: savedCapture))).Entries.Single();
        Check(savedEntry.Label == "North culvert source name" && savedEntry.ElementIndex == 0,
            "A saved-source hover uses the source Geometry name rather than a draft or display-row label.");

        MapHoverModelVectorCapture staleDraft = draftCapture with
        { CulvertDraftSHA256 = new string('0', 64) };
        await ExpectAsync<SourceFileChangedException>(() => Identify(map, mapSources,
            "hover-culvert-stale-draft", new(0.5, 0.5),
            new(culvertLocator, "modelVector", staleDraft.SourcePath,
                staleDraft.SourceRevision, ModelVector: staleDraft)));
        MapHoverModelVectorCapture staleSource = savedCapture with
        { SourceRevision = new string('0', 64) };
        await ExpectAsync<SourceFileChangedException>(() => Identify(map, mapSources,
            "hover-culvert-stale-source", new(0.5, 0.5),
            new(culvertLocator, "modelVector", staleSource.SourcePath,
                staleSource.SourceRevision, ModelVector: staleSource)));

        string boundaryRevision = HashFile(boundaryPath);
        MapBoundaryGeometrySnapshot boundarySource = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, boundaryLocator, boundaryRevision));
        MapHoverModelVectorLine[] boundaryLines = boundarySource.Lines
            .Where(line => line.Coordinates is { Length: >= 2 })
            .Select(line => new MapHoverModelVectorLine(line.Id, line.Name, line.SourceOrdinal,
                line.Coordinates!.Select(point => new MapHoverCoordinate(point.X, point.Y)).ToArray()))
            .ToArray();
        Check(boundaryLines.Length > 0 && boundaryLines[0].SourceOrdinal == 0,
            "The ordinary BoundaryCondition HDF contains its newly saved visible source BCL.");
        MapBoundaryLineData firstBoundaryLine = boundarySource.Lines.Single(line =>
            line.SourceOrdinal == 0 && line.Coordinates is { Length: >= 2 });
        MapHoverCoordinate boundaryHit = SegmentMidpoint(firstBoundaryLine.Coordinates!);
        var boundaryModel = new ModelRequest(boundaryPath, "Boundary Conditions", map.ProjectPath,
            map.ProjectXml, boundarySource.BoundarySourceState, map.CoreLayerContext);
        var boundaryCapture = new MapHoverModelVectorCapture(boundaryLocator,
            "boundaryConditionLine", boundarySource.BoundaryPath, boundarySource.BoundaryRevision,
            "savedSource", BoundarySourceState: boundarySource.BoundarySourceState,
            BoundaryContextToken: boundarySource.ContextToken, BoundaryLines: boundaryLines,
            Model: boundaryModel);
        MapHoverIdentifyEntry boundaryEntry = (await Identify(map, mapSources,
            "hover-boundary-line", boundaryHit,
            new(boundaryLocator, "modelVector", boundaryCapture.SourcePath,
                boundaryCapture.SourceRevision, ModelVector: boundaryCapture))).Entries.Single();
        Check(boundaryEntry.Kind == "modelVector" && boundaryEntry.Label == "BCL: 0"
            && boundaryEntry.Value == "0" && boundaryEntry.ValueType == "boundaryConditionLine"
            && boundaryEntry.ElementIndex == 0 && boundaryEntry.MapType is null,
            "Boundary hover uses the retained source line renderer's BCL ordinal callback.");

        MapHoverModelVectorLine firstLine = boundaryLines[0];
        MapHoverModelVectorCapture changedBoundaryGeometry = boundaryCapture with
        {
            BoundaryLines = [firstLine with
            {
                Coordinates = [new(firstLine.Coordinates[0].X + 10, firstLine.Coordinates[0].Y),
                    .. firstLine.Coordinates.Skip(1)]
            }, .. boundaryLines.Skip(1)]
        };
        await ExpectAsync<SourceFileChangedException>(() => Identify(map, mapSources,
            "hover-boundary-changed-geometry", new(0.5, 0.5),
            new(boundaryLocator, "modelVector", changedBoundaryGeometry.SourcePath,
                changedBoundaryGeometry.SourceRevision, ModelVector: changedBoundaryGeometry)));

        Check(File.ReadAllBytes(geometryPath).SequenceEqual(geometryBefore)
            && File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(boundaryPath).SequenceEqual(boundaryBefore),
            "Model vector hover, parent-draft replay and stale-capture rejection leave every project/map/HDF byte unchanged.");
        Console.WriteLine("Source-backed CulvertBarrel and BoundaryConditionLine hover, parent-draft naming, exact ordinals, stale capture rejection and read-only source checks passed.");
        await RunResultOwnedPositiveAsync();
    }

    private static MapHoverModelVectorCapture CulvertCapture(MapGeometrySnapshot source,
        CatalogTreeNodeLocator culvert, MapTreeRequest map, GeometryCulvertModelRequest model,
        GeometryCulvertSnapshot? draft) => new(culvert, "culvertBarrel",
            source.GeometryCanonicalPath, source.GeometryRevision,
            draft?.IsDirty == true ? "parentDraft" : "savedSource",
            source.GeometryNode, source.ContextToken, source.PlanNodes, Model: new ModelRequest(
                model.AssetPath, model.Kind, model.ProjectPath, model.ProjectXml,
                CoreLayerContext: model.CoreLayerContext),
            CulvertDraftState: draft?.IsDirty == true ? draft.DraftState : null,
            CulvertDraftSHA256: draft?.IsDirty == true ? HashText(draft.DraftState) : null);

    private static Task<MapHoverIdentifyResult> Identify(MapTreeRequest map,
        MapResultSourcesResult sources, string requestID, MapHoverCoordinate point,
        MapHoverLayerCapture capture, MapResultSelectionOverride[]? selectionOverrides = null) =>
        MapHoverIdentifyService.Identify(new(map,
            sources.ContextToken, selectionOverrides ?? [], requestID, point, new(point.X + 0.0001, point.Y),
            0.0001, [], [capture]));

    private static string HashText(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static bool IsProjectGeometryNode(CatalogTreeNode node) =>
        node.Locator is { RootName: "Geometries", NodeType: "Geometry", AssetID: { Length: > 0 },
            ParentResultNodeType: null, ParentResultAssetID: null, ParentResultNodePath: null,
            ParentResultNodeName: null, ParentResultRevision: null };

    private static bool IsProjectBoundaryNode(CatalogTreeNode node) =>
        node.Locator is { RootName: "Boundary Conditions", NodeType: "BoundaryCondition",
            AssetID: { Length: > 0 }, ParentResultNodeType: null,
            ParentResultAssetID: null, ParentResultNodePath: null,
            ParentResultNodeName: null, ParentResultRevision: null };

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static bool SamePath(string left, string right) =>
        MapSourceTestPaths.SameFile(left, right);

    private static IEnumerable<CatalogTreeNode> Flatten(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            foreach (CatalogTreeNode child in Flatten(node.Children ?? [])) yield return child;
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string FullName { get; } = Path.Combine(Path.GetTempPath(), "hecras-hover-model-vector-" + Guid.NewGuid().ToString("N"));
        public TemporaryDirectory() => Directory.CreateDirectory(FullName);
        public void Dispose() { try { Directory.Delete(FullName, recursive: true); } catch { } }
    }
}
