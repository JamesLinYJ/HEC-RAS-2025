using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Engine;
using Ras.Layers;
using Utility.Files;

/// <summary>
/// Exercises the read-only Plan and stored-Result geometry routes against a
/// private copy of the real CPU-solver culvert acceptance fixture. No source
/// HDF, Project XML, raster, or visualization bytes are modified by a read.
/// </summary>
internal static class MapResultOwnedGeometryChecks
{
    private static readonly JsonSerializerOptions WebJSON = new(JsonSerializerDefaults.Web);

    internal static async Task Run()
    {
        string fixturePath = Environment.GetEnvironmentVariable(
            "HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY")
            ?? throw new DirectoryNotFoundException("The real CPU-solver culvert acceptance fixture is required.");
        if (!Directory.Exists(fixturePath))
            throw new DirectoryNotFoundException("The real CPU-solver culvert acceptance fixture is unavailable: " + fixturePath);

        string fixtureDigestBefore = DirectoryDigest(fixturePath);
        using var temporary = new TemporaryDirectory();
        CopyFixtureDirectory(fixturePath, temporary.FullName);
        AcceptanceManifest manifest = JsonSerializer.Deserialize<AcceptanceManifest>(
            File.ReadAllText(Path.Combine(temporary.FullName, "acceptance.json")), WebJSON)
            ?? throw new InvalidDataException("The retained CPU-solver acceptance manifest is missing.");

        string projectPath = FixturePath(temporary.FullName, manifest.ProjectRelativePath);
        string planPath = FixturePath(temporary.FullName, manifest.PlanRelativePath);
        string sharedPlanPath = FixturePath(temporary.FullName, manifest.SharedPlanRelativePath);
        string alternatePlanPath = FixturePath(temporary.FullName, manifest.AlternatePlanRelativePath);
        string geometryPath = FixturePath(temporary.FullName, manifest.GeometryRelativePath);
        string alternateGeometryPath = FixturePath(temporary.FullName, manifest.AlternateGeometryRelativePath);
        string boundaryPath = FixturePath(temporary.FullName, manifest.BoundaryConditionRelativePath);
        string rasterPath = FixturePath(temporary.FullName, manifest.TerrainRasterRelativePath);
        if (manifest.Results.Length != 2 ||
            !manifest.Results.Select(result => result.Role).SequenceEqual(["signed-flow", "zero-flow"]))
            throw new InvalidDataException("The CPU-solver fixture must contain signed-flow and zero-flow Result HDFs in source order.");
        ResultCapture signed = manifest.Results.Single(result => result.Role == "signed-flow");
        ResultCapture zero = manifest.Results.Single(result => result.Role == "zero-flow");
        string signedPath = FixturePath(temporary.FullName, signed.Path);
        string zeroPath = FixturePath(temporary.FullName, zero.Path);
        RequireRevision(signedPath, signed.Revision, "signed-flow Result");
        RequireRevision(zeroPath, zero.Revision, "zero-flow Result");

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, null, "Project", Name: "R20 Result Geometry"));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        AddStoredResultRows(visualizationPath, created.MapName, created.MapType, manifest, signedPath);

        string planRevision = Hash(planPath);
        string geometryRevision = Hash(geometryPath);
        string boundaryRevision = Hash(boundaryPath);
        string rasterRevision = Hash(rasterPath);
        string signedRevision = Hash(signedPath);
        string zeroRevision = Hash(zeroPath);
        string projectRevision = Hash(projectPath);
        string visualizationRevision = Hash(visualizationPath);
        string[] readOnlyPaths = [projectPath, planPath, sharedPlanPath, alternatePlanPath,
            geometryPath, alternateGeometryPath, boundaryPath,
            rasterPath, signedPath, zeroPath, visualizationPath];
        Dictionary<string, byte[]> readOnlyBytes = CaptureBytes(readOnlyPaths);

        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "r20-result-geometry-project", created.MapIndex, created.MapName,
            created.MapType, visualizationRevision,
            [new MapTreeResultSelectionOverride(planPath, manifest.PlanName, zeroPath, zeroRevision)]);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode resultRow = FindNode(tree.Roots, "Results", "Result",
            Path.GetFileNameWithoutExtension(signedPath));
        CatalogTreeNode multiResultRow = FindNode(tree.Roots, "Results", "MultiResult", manifest.PlanName);
        CatalogTreeNodeLocator resultLocator = RequiredLocator(resultRow);
        CatalogTreeNodeLocator multiResultLocator = RequiredLocator(multiResultRow);
        MapResultSourcesResult resultSources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode activeResult = resultSources.ActiveNodes.Single(node =>
            node.NodeKind == "Result" && SameLocator(node.Node, resultLocator));
        MapResultSourceChoice selectedSigned = activeResult.Selections.Single().SelectedResult
            ?? throw new InvalidDataException("The checked standalone Result did not resolve to its stored HDF.");
        Check(SamePath(selectedSigned.ResultPath, signedPath) &&
              selectedSigned.Revision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase),
            "The standalone Result row resolves to the exact signed-flow source HDF and SHA.");

        CatalogTreeNode resultGeometry = FindChild(resultRow, "Geometry", manifest.GeometryName);
        CatalogTreeNode resultBoundary = FindChild(resultRow, "BoundaryCondition", manifest.BoundaryConditionName);
        Check(resultGeometry.Locator?.ParentResultNodeType == "Result" &&
              resultGeometry.Locator.ParentResultNodePath is { Length: >= 2 } resultParentPath &&
              resultLocator.NodePath is not null && resultParentPath.SequenceEqual(resultLocator.NodePath) &&
              resultGeometry.Locator.ParentResultRevision == signedRevision,
            "Serialized embedded Geometry ancestry identifies the exact Result row, selected HDF, and revision.");
        Check(resultBoundary.Locator?.ParentResultNodeType == "Result" &&
              SamePath(resultBoundary.Locator.ParentResultAssetID!, signedPath) &&
              resultBoundary.Locator.ParentResultRevision == signedRevision,
            "Serialized embedded BoundaryCondition ancestry is bound to the same exact Result HDF.");

        var owner = new MapResultGeometryOwner(resultLocator, resultSources.ContextToken,
            null, 0, selectedSigned.ResultPath, selectedSigned.Revision);
        MapResultGeometrySnapshot resultGeometrySnapshot = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(map, owner, RequiredLocator(resultGeometry), PageSize: 512));
        Check(resultGeometrySnapshot.ResultNode is { } echoedResult && SameLocator(echoedResult, resultLocator) &&
              SamePath(resultGeometrySnapshot.SelectedResultPath, signedPath) &&
              resultGeometrySnapshot.SelectedResultRevision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase) &&
              SamePath(resultGeometrySnapshot.GeometryPath, signedPath) &&
              resultGeometrySnapshot.GeometryRevision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase) &&
              resultGeometrySnapshot.Geometry.GeometryName == manifest.GeometryName &&
              resultGeometrySnapshot.Geometry.GeometryEffectiveVisible,
            "Result Geometry reads the object embedded in the exact selected Result and echoes its map, owner, and HDF identity.");
        Check(resultGeometrySnapshot.Geometry.Culverts?.Features.Select(feature => feature.Values["Name"])
                  .SequenceEqual(manifest.BarrelNames, StringComparer.Ordinal) == true,
            "Result Geometry projection retains the embedded source culvert order and names.");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(map, owner,
                RequiredLocator(resultGeometry) with { ParentResultAssetID = zeroPath }, PageSize: 1)));

        var boundaryOwner = new MapResultGeometryOwner(resultLocator, resultSources.ContextToken,
            null, 0, selectedSigned.ResultPath, selectedSigned.Revision);
        MapBoundaryGeometrySnapshot boundary = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, RequiredLocator(resultBoundary), signedRevision,
                ResultOwner: boundaryOwner));
        Check(boundary.MapID == map.MapID && boundary.MapIndex == map.MapIndex &&
              boundary.MapType == "Project" && SamePath(boundary.BoundaryPath, signedPath) &&
              boundary.BoundaryRevision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase) &&
              boundary.BoundaryEffectiveVisible && boundary.ResultOwner is { } boundaryResultOwner &&
              SameLocator(boundaryResultOwner.ResultNode, resultLocator) &&
              SamePath(boundaryResultOwner.SelectedResultPath, signedPath) &&
              boundaryResultOwner.SelectedResultRevision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase),
            "Result-owned boundary geometry returns the exact selected Result receipt and effective visibility.");
        Check(boundary.Lines.Length > 0 && boundary.Lines.Select((line, index) =>
                  line.SourceOrdinal == index && line.Coordinates is { Length: >= 2 } points &&
                  points.All(point => double.IsFinite(point.X) && double.IsFinite(point.Y))).All(value => value),
            "Boundary map lines preserve source feature order and return only actual finite source coordinates.");
        MapBoundaryGeometrySnapshot boundaryReadback = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, RequiredLocator(resultBoundary), signedRevision,
                boundary.BoundarySourceState, boundary.ContextToken, boundaryOwner));
        Check(boundaryReadback.ContextToken == boundary.ContextToken &&
              boundaryReadback.Lines.Select(line => line.Id).SequenceEqual(boundary.Lines.Select(line => line.Id)) &&
              boundaryReadback.Lines.Select(line => line.SourceOrdinal).SequenceEqual(boundary.Lines.Select(line => line.SourceOrdinal)),
            "A Result boundary readback accepts its captured boundary state and retains stable IDs/order.");
        BoundaryLineCoordinateData[] boundaryPoints = boundary.Lines
            .SelectMany(line => line.Coordinates ?? []).ToArray();
        double minX = boundaryPoints.Min(point => point.X);
        double maxX = boundaryPoints.Max(point => point.X);
        double minY = boundaryPoints.Min(point => point.Y);
        double maxY = boundaryPoints.Max(point => point.Y);
        double padding = Math.Max(1, Math.Max(maxX - minX, maxY - minY) * 0.05);
        var attachedFacesViewport = new RasterMapViewExtent(
            minX - padding, minY - padding, maxX + padding, maxY + padding, 128, 128);
        MapBoundaryGeometrySnapshot attachedFaces = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, RequiredLocator(resultBoundary), signedRevision,
                boundary.BoundarySourceState, boundary.ContextToken, boundaryOwner,
                AttachedFacesViewport: attachedFacesViewport, RenderScale: 0.75));
        Check(attachedFaces.AttachedFaces is { } attachedFrame &&
              attachedFrame.Viewport == attachedFacesViewport && attachedFrame.Width == 128 &&
              attachedFrame.Height == 128 && attachedFrame.Rgba.Length == 128 * 128 * 4 &&
              attachedFrame.Rgba.Where((_, index) => index % 4 == 3).Any(alpha => alpha > 0) &&
              attachedFaces.ResultOwner is { } attachedOwner && SameLocator(attachedOwner.ResultNode, resultLocator) &&
              SamePath(attachedOwner.SelectedResultPath, signedPath) &&
              attachedOwner.SelectedResultRevision.Equals(signedRevision, StringComparison.OrdinalIgnoreCase),
            "ShowAttachedFaces renders nontransparent source pixels for the exact selected Result owner and requested project-camera viewport.");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map,
                RequiredLocator(resultBoundary) with { ParentResultAssetID = zeroPath }, signedRevision,
                ResultOwner: boundaryOwner)));
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, RequiredLocator(resultBoundary), signedRevision,
                ExpectedContextToken: new string('0', 64), ResultOwner: boundaryOwner)));

        MapResultSourcesResult zeroSources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode activeMulti = zeroSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SameLocator(node.Node, multiResultLocator));
        MapResultSourceChoice selectedZero = activeMulti.Selections.Single(slot => slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The MultiResult source did not resolve its current slot-zero Result.");
        Check(SamePath(selectedZero.ResultPath, zeroPath) &&
              selectedZero.Revision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            "MultiResult geometry resolves only the exact current slot-zero keyframe Result HDF.");
        CatalogTreeNode selectedMulti = FindNode(MapTreeService.Load(map).Roots,
            "Results", "MultiResult", manifest.PlanName);
        CatalogTreeNode multiGeometry = FindChild(selectedMulti, "Geometry", manifest.GeometryName);
        CatalogTreeNode multiBoundary = FindChild(selectedMulti, "BoundaryCondition", manifest.BoundaryConditionName);
        var multiOwner = new MapResultGeometryOwner(multiResultLocator, zeroSources.ContextToken,
            null, 0, selectedZero.ResultPath, selectedZero.Revision);
        MapResultGeometrySnapshot zeroGeometry = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(map, multiOwner, RequiredLocator(multiGeometry), PageSize: 512));
        Check(SamePath(zeroGeometry.SelectedResultPath, zeroPath) &&
              zeroGeometry.SelectedResultRevision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase) &&
              SamePath(zeroGeometry.Geometry.GeometryCanonicalPath, zeroPath),
            "MultiResult Geometry stays scoped to the exact selected keyframe HDF instead of a project Geometry with the same name.");
        MapBoundaryGeometrySnapshot zeroBoundary = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(map, RequiredLocator(multiBoundary), zeroRevision,
                ResultOwner: multiOwner));
        Check(zeroBoundary.ResultOwner?.SelectionIndex == 0 &&
              SamePath(zeroBoundary.ResultOwner.SelectedResultPath, zeroPath) &&
              zeroBoundary.BoundaryRevision.Equals(zeroRevision, StringComparison.OrdinalIgnoreCase),
            "MultiResult boundary projection follows slot zero and its current Result revision.");

        CheckCulvertProfile(map, resultSources, selectedSigned, resultRow, manifest,
            signed, signedPath, "signed-flow");
        CheckCulvertProfile(map, zeroSources, selectedZero, selectedMulti, manifest,
            zero, zeroPath, "zero-flow");
        CheckCulvertTimeSeries(map, resultSources, selectedSigned, resultRow,
            signed, signedPath, projectRevision, manifest, "signed-flow");
        CheckCulvertTimeSeries(map, zeroSources, selectedZero, selectedMulti,
            zero, zeroPath, projectRevision, manifest, "zero-flow");
        Expect<ArgumentOutOfRangeException>(() => ModelEditorAdapter.LoadMapResultCulvertProfile(
            new MapResultCulvertProfileRequest(map, zeroSources.ContextToken, null,
                multiResultLocator, 0, zero.ProfileCount)));

        AssertBytes(readOnlyBytes,
            "Result/Boundary/Culvert map reads do not write .ras, Plan, Geometry, BoundaryCondition, raster, Result HDF, or .vis bytes.");
        Check(DirectoryDigest(fixturePath) == fixtureDigestBefore,
            "The immutable CPU solver acceptance fixture remains unchanged; all map operations used its private copy.");

        MapDocumentMutationReceipt geometryMapCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, Hash(visualizationPath), "Geometry",
            Name: "R20 Geometry Result Owner"));
        AddStoredResultRows(visualizationPath, geometryMapCreated.MapName,
            geometryMapCreated.MapType, manifest, signedPath);
        var geometryMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "r20-result-geometry-geometry", geometryMapCreated.MapIndex,
            geometryMapCreated.MapName, geometryMapCreated.MapType, Hash(visualizationPath));
        MapTreeSnapshot geometryMapTree = MapTreeService.Load(geometryMap);
        CatalogTreeNode geometryMapResult = FindNode(geometryMapTree.Roots, "Layers", "Result",
            Path.GetFileNameWithoutExtension(signedPath));
        CatalogTreeNode geometryMapEmbeddedGeometry = FindChild(geometryMapResult,
            "Geometry", manifest.GeometryName);
        CatalogTreeNode geometryMapEmbeddedBoundary = FindChild(geometryMapResult,
            "BoundaryCondition", manifest.BoundaryConditionName);
        MapResultSourcesResult geometryMapSources = MapResultChartService.Sources(new(geometryMap, []));
        MapResultActiveNode geometryMapActiveResult = geometryMapSources.ActiveNodes.Single(node =>
            node.NodeKind == "Result" && SameLocator(node.Node, RequiredLocator(geometryMapResult)));
        MapResultSourceChoice geometryMapSelectedResult = geometryMapActiveResult.Selections
            .Single().SelectedResult ?? throw new InvalidDataException("The Geometry map Result row did not resolve its source HDF.");
        var geometryMapResultOwner = new MapResultGeometryOwner(RequiredLocator(geometryMapResult),
            geometryMapSources.ContextToken, null, 0, geometryMapSelectedResult.ResultPath,
            geometryMapSelectedResult.Revision);
        Dictionary<string, byte[]> geometryMapReadOnlyBytes = CaptureBytes(readOnlyPaths);
        MapResultGeometrySnapshot geometryMapResultSnapshot = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(geometryMap, geometryMapResultOwner,
                RequiredLocator(geometryMapEmbeddedGeometry), PageSize: 64));
        MapBoundaryGeometrySnapshot geometryMapBoundarySnapshot = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(geometryMap, RequiredLocator(geometryMapEmbeddedBoundary),
                geometryMapSelectedResult.Revision, ResultOwner: geometryMapResultOwner));
        Check(geometryMapResultSnapshot.MapType == "Geometry" &&
              SamePath(geometryMapResultSnapshot.GeometryPath, signedPath) &&
              SamePath(geometryMapBoundarySnapshot.BoundaryPath, signedPath) &&
              geometryMapBoundarySnapshot.Lines.Length > 0,
            "Geometry-map Result rows resolve embedded Geometry and BoundaryCondition children from their exact selected Result HDF.");
        AssertBytes(geometryMapReadOnlyBytes,
            "Geometry-map embedded Result reads do not write source HDFs, raster, project, or saved map data.");

        MapDocumentMutationReceipt planMapCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, Hash(visualizationPath), "Plan",
            Name: "R20 Plan Geometry", InitialPlanPath: planPath, InitialPlanRevision: planRevision));
        string planMapVisualizationRevision = planMapCreated.VisualizationRevision;
        var planMap = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "r20-result-geometry-plan", planMapCreated.MapIndex, planMapCreated.MapName,
            planMapCreated.MapType, planMapVisualizationRevision);
        MapTreeSnapshot planTree = MapTreeService.Load(planMap);
        CatalogTreeNode focusedPlan = FindNode(planTree.Roots, "Focused Plans", "Plan", manifest.PlanName);
        CatalogTreeNode planGeometry = FindChild(focusedPlan, "Geometry", manifest.GeometryName);
        CatalogTreeNode planBoundary = FindChild(focusedPlan, "BoundaryCondition", manifest.BoundaryConditionName);
        Check(planGeometry.Locator?.ParentPlanNodePath is { Length: >= 2 } planOwnerPath &&
              RequiredLocator(focusedPlan).NodePath is { } planRowPath && planOwnerPath.SequenceEqual(planRowPath) &&
              SamePath(planGeometry.Locator.ParentPlanAssetID!, planPath),
            "Plan map Geometry is tied to the exact focused Plan HDF locator and owner path.");

        MapGeometrySnapshot initiallyHiddenGeometry = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(planGeometry), PageSize: 512,
                PlanNodes: [RequiredLocator(focusedPlan)]));
        Check(!initiallyHiddenGeometry.GeometryChecked && !initiallyHiddenGeometry.GeometryEffectiveVisible,
            "A newly focused Plan keeps its retained unchecked Geometry default until the user explicitly enables it.");
        MapTreeMutationResult enabledPlanGeometry = MapTreeService.Perform(new MapTreeActionRequest(
            planMap, "visibility", Node: RequiredLocator(planGeometry), Checked: true));
        planMap = planMap with { ExpectedVisualizationRevision = enabledPlanGeometry.VisualizationRevision };
        planTree = MapTreeService.Load(planMap);
        focusedPlan = FindNode(planTree.Roots, "Focused Plans", "Plan", manifest.PlanName);
        planGeometry = FindChild(focusedPlan, "Geometry", manifest.GeometryName);
        planBoundary = FindChild(focusedPlan, "BoundaryCondition", manifest.BoundaryConditionName);
        MapGeometrySnapshot planGeometrySnapshot = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(planGeometry), PageSize: 512,
                PlanNodes: [RequiredLocator(focusedPlan)]));
        Check(planGeometrySnapshot.MapType == "Plan" &&
              SamePath(planGeometrySnapshot.GeometryCanonicalPath, geometryPath) &&
              planGeometrySnapshot.GeometryRevision.Equals(geometryRevision, StringComparison.OrdinalIgnoreCase) &&
              planGeometrySnapshot.GeometryEffectiveVisible &&
              planGeometrySnapshot.PlanNodes.Length == 1 &&
              SameLocator(planGeometrySnapshot.PlanNodes[0], RequiredLocator(focusedPlan)),
            "The existing map.geometry.load route reads Plan-owned Geometry by exact singleton Plan owner and real source HDF. " +
            JsonSerializer.Serialize(new { planGeometrySnapshot.MapType, planGeometrySnapshot.GeometryCanonicalPath,
                ExpectedGeometryPath = geometryPath, planGeometrySnapshot.GeometryRevision,
                ExpectedGeometryRevision = geometryRevision, planGeometrySnapshot.GeometryEffectiveVisible,
                planGeometrySnapshot.PlanNodes, ExpectedPlan = RequiredLocator(focusedPlan) }));
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(planGeometry), PageSize: 1)));
        MapBoundaryGeometrySnapshot planBoundarySnapshot = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(planMap, RequiredLocator(planBoundary), boundaryRevision));
        Check(SamePath(planBoundarySnapshot.BoundaryPath, boundaryPath) &&
              planBoundarySnapshot.BoundaryRevision.Equals(boundaryRevision, StringComparison.OrdinalIgnoreCase) &&
              planBoundarySnapshot.Lines.Length > 0,
            "Plan-owned BoundaryCondition lines resolve from the exact focused Plan source tree and actual boundary HDF.");
        CatalogTreeNode planMultiResult = (focusedPlan.Children ?? []).Single(node =>
            node.Locator?.NodeType == "MultiResult");
        MapTreeMutationResult enabledPlanResult = MapTreeService.Perform(new MapTreeActionRequest(
            planMap, "visibility", Node: RequiredLocator(planMultiResult), Checked: true));
        planMap = planMap with { ExpectedVisualizationRevision = enabledPlanResult.VisualizationRevision };
        focusedPlan = FindNode(MapTreeService.Load(planMap).Roots, "Focused Plans", "Plan", manifest.PlanName);
        planGeometry = FindChild(focusedPlan, "Geometry", manifest.GeometryName);
        planMultiResult = (focusedPlan.Children ?? []).Single(node => node.Locator?.NodeType == "MultiResult");
        CatalogTreeNode planResultGeometry = FindChild(planMultiResult, "Geometry", manifest.GeometryName);
        CatalogTreeNode planResultBoundary = FindChild(planMultiResult, "BoundaryCondition", manifest.BoundaryConditionName);
        MapResultSourcesResult planSources = MapResultChartService.Sources(new(planMap, []));
        MapResultActiveNode planActiveMulti = planSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SameLocator(node.Node, RequiredLocator(planMultiResult)));
        MapResultSourceChoice planSelectedResult = planActiveMulti.Selections
            .Single(slot => slot.SelectionIndex == 0).SelectedResult
            ?? throw new InvalidDataException("The focused Plan MultiResult has no slot-zero Result.");
        var planResultOwner = new MapResultGeometryOwner(RequiredLocator(planMultiResult),
            planSources.ContextToken, null, 0, planSelectedResult.ResultPath,
            planSelectedResult.Revision);
        MapResultGeometrySnapshot planResultGeometrySnapshot = await ModelEditorAdapter.LoadMapResultGeometryAsync(
            new MapResultGeometryRequest(planMap, planResultOwner,
                RequiredLocator(planResultGeometry), PageSize: 512));
        Check(planResultGeometrySnapshot.MapType == "Plan" &&
              SamePath(planResultGeometrySnapshot.SelectedResultPath, planSelectedResult.ResultPath) &&
              SamePath(planResultGeometrySnapshot.GeometryPath, planSelectedResult.ResultPath) &&
              planResultGeometrySnapshot.Geometry.GeometryName == manifest.GeometryName,
            "Plan-map Result Geometry reads the exact slot-zero embedded Geometry instead of its project Geometry source.");
        MapBoundaryGeometrySnapshot planResultBoundarySnapshot = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(planMap, RequiredLocator(planResultBoundary),
                planSelectedResult.Revision, ResultOwner: planResultOwner));
        Check(planResultBoundarySnapshot.ResultOwner?.SelectionIndex == 0 &&
              SamePath(planResultBoundarySnapshot.BoundaryPath, planSelectedResult.ResultPath) &&
              planResultBoundarySnapshot.Lines.Length > 0,
            "Plan-map Result boundary lines resolve from the exact slot-zero embedded BoundaryCondition HDF.");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(planGeometry) with
            { ParentPlanAssetID = geometryPath }, PageSize: 1,
                PlanNodes: [RequiredLocator(focusedPlan)])));

        MapTreeMutationResult focusedShared = MapTreeService.Perform(new MapTreeActionRequest(planMap,
            "focusPlan", SourcePath: sharedPlanPath, SourceRevision: Hash(sharedPlanPath)));
        planMap = planMap with { ExpectedVisualizationRevision = focusedShared.VisualizationRevision };
        MapTreeSnapshot sharedPlanTree = MapTreeService.Load(planMap);
        CatalogTreeNode[] sharedPlanRows = (sharedPlanTree.Roots.Single(node => node.Name == "Focused Plans").Children ?? [])
            .Where(node => node.Locator?.NodeType == "Plan").ToArray();
        CatalogTreeNode sharedGeometry = FindChild(
            sharedPlanTree.Roots.Single(node => node.Name == "Matching Layers"),
            "Geometry", manifest.GeometryName);
        CatalogTreeNodeLocator[] sharedPlanLocators = sharedPlanRows.Select(RequiredLocator).ToArray();
        Check(sharedPlanLocators.Length == 2 &&
              sharedGeometry.Locator is { AssociationKind: "Geometry", ParentPlanAssetID: null,
                  ParentPlanNodePath: null, ParentPlanNodeName: null } sharedGeometryLocator &&
              SamePath(sharedGeometryLocator.AssociationAssetID!, geometryPath),
            "Two focused Plans sharing one source Geometry produce a parentless Matching Layers row with exact association identity.");

        Dictionary<string, byte[]> planReadOnlyBytes = CaptureBytes(readOnlyPaths);
        MapGeometrySnapshot sharedGeometrySnapshot = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(sharedGeometry), PageSize: 512,
                PlanNodes: sharedPlanLocators));
        Check(sharedGeometrySnapshot.PlanNodes.Length == 2 &&
              sharedGeometrySnapshot.PlanNodes.Zip(sharedPlanLocators)
                  .All(pair => SameLocator(pair.First, pair.Second)) &&
              SamePath(sharedGeometrySnapshot.GeometryCanonicalPath, geometryPath),
            "Matching Geometry loading uses the complete exact Focused Plans set and echoes source owner identities.");
        CatalogTreeNode sharedBoundary = FindChild(
            sharedPlanTree.Roots.Single(node => node.Name == "Matching Layers"),
            "BoundaryCondition", manifest.BoundaryConditionName);
        Check(sharedBoundary.Locator is { AssociationKind: "BoundaryCondition",
                  ParentPlanAssetID: null, ParentPlanNodePath: null, ParentPlanNodeName: null } sharedBoundaryLocator &&
              SamePath(sharedBoundaryLocator.AssociationAssetID!, boundaryPath),
            "The two source Plans share a parentless Matching Layers BoundaryCondition row with its exact association path.");
        MapBoundaryGeometrySnapshot sharedBoundarySnapshot = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(planMap, RequiredLocator(sharedBoundary), boundaryRevision));
        Check(sharedBoundarySnapshot.MapType == "Plan" &&
              SamePath(sharedBoundarySnapshot.BoundaryPath, boundaryPath) &&
              sharedBoundarySnapshot.Lines.Length > 0 &&
              sharedBoundarySnapshot.Lines.Select((line, index) => line.SourceOrdinal == index).All(value => value),
            "Matching Plan boundary geometry validates the current ordered Plan set and preserves source line order.");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
            new MapBoundaryGeometryRequest(planMap, RequiredLocator(sharedBoundary), boundaryRevision,
                ExpectedContextToken: new string('0', 64))));
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(sharedGeometry), PageSize: 1,
                ContextToken: new string('0', 64), PlanNodes: sharedPlanLocators)));
        AssertBytes(planReadOnlyBytes,
            "Loading and rejecting stale shared Geometry requests does not change any source or saved map bytes.");

        MapTreeMutationResult focusedAlternate = MapTreeService.Perform(new MapTreeActionRequest(planMap,
            "focusPlan", SourcePath: alternatePlanPath, SourceRevision: Hash(alternatePlanPath)));
        planMap = planMap with { ExpectedVisualizationRevision = focusedAlternate.VisualizationRevision };
        MapTreeSnapshot threePlanTree = MapTreeService.Load(planMap);
        CatalogTreeNode matchingRoot = threePlanTree.Roots.Single(node => node.Name == "Matching Layers");
        CatalogTreeNode[] matchingGeometryRows = (matchingRoot.Children ?? [])
            .Where(node => node.Locator?.NodeType == "Geometry" && node.Name == manifest.GeometryName)
            .ToArray();
        Check(matchingGeometryRows.Length == 0,
            "A third focused Plan with a different actual Geometry prevents the source shared-Geometry row.");
        CatalogTreeNode[] threePlans = (threePlanTree.Roots.Single(node => node.Name == "Focused Plans").Children ?? [])
            .Where(node => node.Locator?.NodeType == "Plan").ToArray();
        Check(threePlans.Length == 3 && threePlans.All(node => node.Locator?.NodePath is { Length: >= 2 }),
            "The Plan map exposes all three exact focused Plan rows, including unchecked source rows.");
        await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(sharedGeometry), PageSize: 1,
                PlanNodes: sharedPlanLocators)));

        CatalogTreeNode alternatePlan = threePlans.Single(node => node.Name == manifest.AlternatePlanName);
        CatalogTreeNode alternateGeometry = FindChild(alternatePlan, "Geometry", manifest.AlternateGeometryName);
        Dictionary<string, byte[]> finalPlanReadOnlyBytes = CaptureBytes(readOnlyPaths);
        MapGeometrySnapshot alternateGeometrySnapshot = await ModelEditorAdapter.LoadMapGeometryAsync(
            new MapGeometryRequest(planMap, RequiredLocator(alternateGeometry), PageSize: 512,
                PlanNodes: [RequiredLocator(alternatePlan)]));
        Check(alternateGeometrySnapshot.PlanNodes.Length == 1 &&
              SameLocator(alternateGeometrySnapshot.PlanNodes[0], RequiredLocator(alternatePlan)) &&
              SamePath(alternateGeometrySnapshot.GeometryCanonicalPath, alternateGeometryPath),
            "A differing Geometry stays under its exact single Plan owner instead of being borrowed by Matching Layers.");

        AssertBytes(finalPlanReadOnlyBytes,
            "Plan/Boundary geometry reads preserve all exact Plan/Geometry HDF bytes and the captured .vis revision.");
        XDocument finalVisualization = XDocument.Load(visualizationPath);
        Check(finalVisualization.Root?.Element("R20VendorRoot")?.Attribute("Marker")?.Value == "preserve-root" &&
              finalVisualization.Root?.Element("Maps")?.Elements("Map").Single(item =>
                  (string?)item.Attribute("Name") == created.MapName)
                  .Element("R20VendorMapExtension")?.Attribute("Marker")?.Value == "preserve-map",
            "Creating the Plan map preserves unknown vendor XML at both .vis root and existing map scope.");

        await CheckDirectBoundaryMaps(projectPath, projectXml, projectXmlSHA, visualizationPath,
            created, boundaryPath, manifest.BoundaryConditionName);
        Check(DirectoryDigest(fixturePath) == fixtureDigestBefore,
            "The original acceptance fixture remains unchanged after private-copy Plan map reads.");

        Console.WriteLine("R20 Plan-owned and Result-owned geometry routes preserved exact HDF identities, source ordering, Result slot-zero context, actual culvert output, and read-only source bytes.");
    }

    private static void CheckCulvertProfile(MapTreeRequest map, MapResultSourcesResult sources,
        MapResultSourceChoice selected, CatalogTreeNode ownerNode, AcceptanceManifest manifest,
        ResultCapture expected, string resultPath, string role)
    {
        FixtureProfile profile = role == "signed-flow"
            ? expected.Profiles.First(item => item.Flow.Length == manifest.BarrelNames.Length &&
                Math.Abs(item.Flow[0]) > 0.001f && Math.Abs(item.Flow[1]) > 0.001f &&
                item.Flow[0] * item.Flow[1] < 0)
            : expected.Profiles.First(item => item.Flow.Length == manifest.BarrelNames.Length &&
                item.Flow.All(value => Math.Abs(value) <= 0.001f));
        MapResultCulvertProfileSnapshot actual = ModelEditorAdapter.LoadMapResultCulvertProfile(
            new MapResultCulvertProfileRequest(map, sources.ContextToken, null,
                RequiredLocator(ownerNode), 0, profile.Index));
        CatalogTreeNode geometry = FindChild(ownerNode, "Geometry", manifest.GeometryName);
        Check(actual.ContextToken == sources.ContextToken &&
              SameLocator(actual.ResultNode, RequiredLocator(ownerNode)) &&
              actual.SelectionIndex == 0 && SamePath(actual.SelectedResultPath, resultPath) &&
              actual.SelectedResultRevision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase) &&
              actual.ProfileIndex == profile.Index && actual.ProfileCount == expected.ProfileCount &&
              actual.ProfileNames.SequenceEqual(expected.ProfileNames, StringComparer.Ordinal) &&
              actual.GeometryAvailable && actual.OutputAvailable &&
              SamePath(actual.GeometryPath, resultPath) &&
              actual.GeometryRevision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase) &&
              actual.GeometryOwnerNode is { } geometryOwner && SameLocator(geometryOwner, RequiredLocator(geometry)),
            $"The {role} culvert profile is bound to the exact selected Result, embedded Geometry, and stored profile index.");
        Check(actual.Barrels.Select(barrel => barrel.SourceOrdinal).SequenceEqual(Enumerable.Range(0, manifest.BarrelNames.Length)) &&
              actual.Barrels.Select(barrel => barrel.Name).SequenceEqual(manifest.BarrelNames, StringComparer.Ordinal) &&
              actual.Barrels.Select(barrel => barrel.ID).SequenceEqual(manifest.BarrelNames.Select((_, index) => "barrel:source:" + index), StringComparer.Ordinal),
            $"The {role} stored output maps each array entry to the true source-order barrel identity.");
        Check(actual.Flow.SequenceEqual(profile.Flow.Select(value => (double)value)) &&
              actual.OutsideDepth.SequenceEqual(profile.OutsideDepth.Select(value => (double)value)) &&
              actual.OutletVelocity.SequenceEqual(profile.OutletVelocity.Select(value => (double)value)) &&
              actual.OutsideDepth.Length == actual.Flow.Length * 2 &&
              actual.OutletVelocity.Length == actual.Flow.Length,
            $"The {role} response returns exact OutputBlock arrays without reversing, synthesizing, or changing dimensions.");
        if (role == "signed-flow")
            Check(actual.Flow[0] * actual.Flow[1] < 0,
                "Stored signed flow remains source-oriented for oppositely directed barrels.");
        else
            Check(actual.Flow.All(value => Math.Abs(value) <= 0.001),
                "Stored zero-flow data remains within the retained particle-animation threshold.");
    }

    private static void CheckCulvertTimeSeries(MapTreeRequest map, MapResultSourcesResult sources,
        MapResultSourceChoice selected, CatalogTreeNode ownerNode, ResultCapture expected,
        string resultPath, string expectedProjectRevision, AcceptanceManifest manifest, string role)
    {
        var owner = new MapResultGeometryOwner(RequiredLocator(ownerNode), sources.ContextToken,
            null, 0, selected.ResultPath, selected.Revision);
        string[] selectedIDs = manifest.BarrelNames.Length >= 2
            ? ["barrel:source:1", "barrel:source:0"]
            : ["barrel:source:0"];
        FixtureProfile[] orderedProfiles = expected.Profiles.OrderBy(profile => profile.Index).ToArray();
        string[] expectedTimes = orderedProfiles.Select(profile => DateTime.Parse(profile.Time,
            CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind)
            .ToString("O", CultureInfo.InvariantCulture)).ToArray();
        using var selectedResult = new Ras.Layers.Result(selected.ResultPath);
        DefaultUnits expectedUnits = DefaultUnits.FromDefault(selectedResult.EmbeddedUnitSystem);

        foreach (string variable in new[] { "Flow", "Velocity" })
        {
            MapResultCulvertTimeSeriesResult actual = ModelEditorAdapter.LoadMapResultCulvertTimeSeries(
                new MapResultCulvertTimeSeriesRequest(map, owner, selectedIDs, variable));
            Check(SamePath(actual.ProjectCanonicalPath, map.ProjectPath) &&
                  actual.ProjectRevision.Equals(expectedProjectRevision, StringComparison.OrdinalIgnoreCase) &&
                  actual.ProjectXmlSHA.Equals(map.ProjectXmlSHA, StringComparison.OrdinalIgnoreCase) &&
                  actual.VisualizationRevision.Equals(map.ExpectedVisualizationRevision, StringComparison.OrdinalIgnoreCase) &&
                  actual.CoreLayerContextIdentity == (map.CoreLayerContext?.IdentityToken ?? string.Empty) &&
                  actual.MapID == map.MapID && actual.MapIndex == map.MapIndex &&
                  actual.MapName == map.MapName && actual.MapType == map.MapType &&
                  actual.ContextToken == sources.ContextToken && SameLocator(actual.ResultNode, RequiredLocator(ownerNode)) &&
                  actual.SelectionIndex == 0 && SamePath(actual.SelectedResultPath, resultPath) &&
                  actual.SelectedResultRevision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase) &&
                  actual.Variable == variable &&
                  actual.Units == (variable == "Flow" ? expectedUnits.FlowUnits : expectedUnits.ShortVelocityUnits) &&
                  actual.NoDataValue == -9999.0,
                $"The {role} culvert {variable} request is bound to the exact map, slot-zero Result HDF, project revision, and Core context.");
            Check(actual.Times.SequenceEqual(expectedTimes, StringComparer.Ordinal) &&
                  actual.Datasets.Select(dataset => dataset.ID).SequenceEqual(selectedIDs, StringComparer.Ordinal) &&
                  actual.Datasets.Select(dataset => dataset.SourceOrdinal)
                      .SequenceEqual(selectedIDs.Select(id => int.Parse(id.AsSpan("barrel:source:".Length),
                          CultureInfo.InvariantCulture))) &&
                  actual.Datasets.Select(dataset => dataset.Name)
                      .SequenceEqual(actual.Datasets.Select(dataset => manifest.BarrelNames[dataset.SourceOrdinal]),
                          StringComparer.Ordinal) &&
                  actual.Datasets.All(dataset => dataset.Values.Length == expectedTimes.Length &&
                      dataset.Values.All(double.IsFinite) && dataset.ColorRGBA.Length == 8 &&
                      dataset.StrokeWidth > 0 && double.IsFinite(dataset.StrokeWidth)),
                $"The {role} time axis and selected culvert series retain the original OutputBlock order and source-ordinal identities.");

            foreach (MapResultCulvertTimeSeriesDataset dataset in actual.Datasets)
            {
                int ordinal = dataset.SourceOrdinal;
                double[] expectedValues = orderedProfiles.Select(profile => (double)(
                    variable == "Flow" ? profile.Flow[ordinal] : profile.OutletVelocity[ordinal])).ToArray();
                Check(dataset.Values.SequenceEqual(expectedValues),
                    $"The {role} {variable} series for barrel ordinal {ordinal} exactly matches stored HDF values at every source time.");
            }
        }

        Expect<ArgumentException>(() => ModelEditorAdapter.LoadMapResultCulvertTimeSeries(
            new MapResultCulvertTimeSeriesRequest(map, owner with { SelectionIndex = 1 }, selectedIDs, "Flow")));
        Expect<ArgumentException>(() => ModelEditorAdapter.LoadMapResultCulvertTimeSeries(
            new MapResultCulvertTimeSeriesRequest(map, owner, [selectedIDs[0], selectedIDs[0]], "Flow")));
        Expect<ArgumentException>(() => ModelEditorAdapter.LoadMapResultCulvertTimeSeries(
            new MapResultCulvertTimeSeriesRequest(map, owner, ["barrel:source:" + manifest.BarrelNames.Length], "Flow")));
        Expect<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapResultCulvertTimeSeries(
            new MapResultCulvertTimeSeriesRequest(map,
                owner with { SelectedResultRevision = new string('0', 64) }, selectedIDs, "Flow")));
    }

    private static void AddStoredResultRows(string visualizationPath, string mapName,
        string mapType, AcceptanceManifest manifest, string signedPath)
    {
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement root = document.Root ?? throw new InvalidDataException("The .vis root is missing.");
        XElement map = root.Element("Maps")?.Elements("Map").Single(item =>
            (string?)item.Attribute("Name") == mapName)
            ?? throw new InvalidDataException("The saved source map is missing.");
        string resultRootName = mapType switch
        {
            "Project" => "Results",
            "Geometry" => "Layers",
            _ => throw new InvalidDataException("Stored Result rows are only injected into Project and Geometry maps.")
        };

        map.SetAttributeValue("R20VendorAttribute", "preserve-map");
        if (!map.Elements("R20VendorMapExtension").Any())
            map.Add(new XElement("R20VendorMapExtension", new XAttribute("Marker", "preserve-map")));
        if (!root.Elements("R20VendorRoot").Any())
            root.Add(new XElement("R20VendorRoot", new XAttribute("Marker", "preserve-root")));

        XElement[] existingTrees = map.Elements("Tree").ToArray();
        if (existingTrees.Length > 1)
            throw new InvalidDataException("The saved map has duplicate serialized trees.");
        XElement tree = existingTrees.SingleOrDefault() ?? new XElement("Tree");
        if (tree.Parent is null) map.Add(tree);
        XElement[] existingNodes = tree.Elements("Nodes").ToArray();
        if (existingNodes.Length > 1)
            throw new InvalidDataException("The saved map tree has duplicate node containers.");
        XElement nodes = existingNodes.SingleOrDefault() ?? new XElement("Nodes");
        if (nodes.Parent is null) tree.Add(nodes);
        XElement[] existingRoots = nodes.Elements("Node").Where(node =>
            (string?)node.Attribute("Type") == "Root" &&
            string.Equals((string?)node.Attribute("Name"), resultRootName, StringComparison.Ordinal)).ToArray();
        if (existingRoots.Length > 1)
            throw new InvalidDataException("The saved map tree has duplicate " + resultRootName + " roots.");
        XElement resultRoot = existingRoots.SingleOrDefault() ?? new XElement("Node",
            new XAttribute("Type", "Root"), new XAttribute("Name", resultRootName));
        if (resultRoot.Parent is null) nodes.Add(resultRoot);

        XElement[] resultRows =
        [
            new XElement("Node", new XAttribute("Type", "MultiResult"),
                new XAttribute("Name", manifest.PlanName), new XAttribute("IsChecked", true),
                new XAttribute("SelectedMapType", "Depth"), new XAttribute("ProfileIndex", 0),
                ResultChildren(manifest)),
            new XElement("Node", new XAttribute("Type", "Result"),
                new XAttribute("Name", Path.GetFileNameWithoutExtension(signedPath)),
                new XAttribute("IsChecked", true), new XAttribute("SelectedMapType", "Depth"),
                new XAttribute("ProfileIndex", 0), ResultChildren(manifest))
        ];
        foreach (XElement resultRow in resultRows)
        {
            if (resultRoot.Elements("Node").Any(existing =>
                    (string?)existing.Attribute("Type") == (string?)resultRow.Attribute("Type") &&
                    string.Equals((string?)existing.Attribute("Name"),
                        (string?)resultRow.Attribute("Name"), StringComparison.Ordinal)))
                throw new InvalidDataException("The saved map already contains the Result row being injected.");
            resultRoot.Add(new XElement(resultRow));
        }
        document.Save(visualizationPath, SaveOptions.DisableFormatting);

        static object[] ResultChildren(AcceptanceManifest source) =>
        [
            new XElement("Node", new XAttribute("Type", "Plan"), new XAttribute("Name", source.PlanName)),
            new XElement("Node", new XAttribute("Type", "Geometry"), new XAttribute("Name", source.GeometryName),
                new XAttribute("IsChecked", true)),
            new XElement("Node", new XAttribute("Type", "BoundaryCondition"), new XAttribute("Name", source.BoundaryConditionName),
                new XAttribute("IsChecked", true))
        ];
    }

    private static async Task CheckDirectBoundaryMaps(string projectPath, string projectXml,
        string projectXmlSHA, string visualizationPath, MapDocumentMutationReceipt projectMap,
        string boundaryPath, string boundaryName)
    {
        await CheckDirectBoundaryMap("Project", "Boundary Conditions", projectMap.MapIndex,
            projectMap.MapName, projectMap.MapType);

        foreach (string mapType in new[] { "Buildable", "Geometry" })
        {
            MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
                projectPath, projectXml, projectXmlSHA, Hash(visualizationPath), mapType,
                Name: "R20 Direct BC " + mapType));
            await CheckDirectBoundaryMap(mapType, "Layers", created.MapIndex,
                created.MapName, created.MapType);
        }

        async Task CheckDirectBoundaryMap(string mapType, string rootName, int mapIndex,
            string mapName, string receiptMapType)
        {
            if (receiptMapType != mapType) throw new InvalidDataException("The saved map type changed during creation.");
            AddDirectBoundaryRow(visualizationPath, mapIndex, mapName, rootName, boundaryName);
            string visualizationRevision = Hash(visualizationPath);
            var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
                "r20-direct-boundary-" + mapType.ToLowerInvariant(), mapIndex, mapName,
                mapType, visualizationRevision);
            MapTreeSnapshot tree = MapTreeService.Load(map);
            CatalogTreeNode row = FindNode(tree.Roots, rootName, "BoundaryCondition", boundaryName);
            CatalogTreeNodeLocator locator = RequiredLocator(row);
            Check(locator.RootName == rootName && locator.NodeType == "BoundaryCondition" &&
                  locator.NodePath is { Length: >= 2 } && row.AssetID is { } actualPath &&
                  SamePath(actualPath, boundaryPath) && locator.AssetID is { } locatorPath &&
                  SamePath(locatorPath, boundaryPath),
                $"The {mapType} direct BoundaryCondition row resolves to its exact source HDF and serialized path.");

            Dictionary<string, byte[]> sourceBytes = CaptureBytes([projectPath, boundaryPath, visualizationPath]);
            MapBoundaryGeometrySnapshot boundary = await ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
                new MapBoundaryGeometryRequest(map, locator, Hash(boundaryPath)));
            Check(boundary.MapType == mapType && boundary.BoundaryEffectiveVisible &&
                  SamePath(boundary.BoundaryPath, boundaryPath) &&
                  boundary.Lines.Length > 0 && boundary.Lines.Select((line, index) =>
                      line.SourceOrdinal == index && line.Coordinates is { Length: >= 2 }).All(value => value),
                $"The {mapType} direct BoundaryCondition route reads source lines without borrowing a Geometry or Plan owner.");
            AssertBytes(sourceBytes, $"The {mapType} direct BoundaryCondition read leaves source HDF, project, and .vis bytes unchanged.");

            string wrongRootName = rootName == "Boundary Conditions" ? "Layers" : "Boundary Conditions";
            Check(wrongRootName != locator.RootName, "The rejected boundary request must actually change its source root.");
            await ExpectAsync<SourceFileChangedException>(() => ModelEditorAdapter.LoadMapBoundaryGeometryAsync(
                new MapBoundaryGeometryRequest(map, locator with { RootName = wrongRootName },
                    Hash(boundaryPath))));
        }
    }

    private static void AddDirectBoundaryRow(string visualizationPath, int mapIndex,
        string mapName, string rootName, string boundaryName)
    {
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement map = document.Root?.Element("Maps")?.Elements("Map").ElementAtOrDefault(mapIndex)
            ?? throw new InvalidDataException("The direct BoundaryCondition test map is missing.");
        if (!string.Equals((string?)map.Attribute("Name"), mapName, StringComparison.Ordinal))
            throw new InvalidDataException("The direct BoundaryCondition map index no longer identifies its captured map.");
        XElement tree = map.Element("Tree") ?? new XElement("Tree");
        if (tree.Parent is null) map.Add(tree);
        XElement nodes = tree.Element("Nodes") ?? new XElement("Nodes");
        if (nodes.Parent is null) tree.Add(nodes);
        XElement[] roots = nodes.Elements("Node").Where(node =>
            (string?)node.Attribute("Type") == "Root" &&
            string.Equals((string?)node.Attribute("Name"), rootName, StringComparison.Ordinal)).ToArray();
        if (roots.Length > 1) throw new InvalidDataException("The test map has duplicate source roots.");
        XElement root = roots.SingleOrDefault() ?? new XElement("Node",
            new XAttribute("Type", "Root"), new XAttribute("Name", rootName));
        if (root.Parent is null) nodes.Add(root);
        root.Add(new XElement("Node", new XAttribute("Type", "BoundaryCondition"),
            new XAttribute("Name", boundaryName), new XAttribute("IsChecked", true)));
        document.Save(visualizationPath, SaveOptions.DisableFormatting);
    }

    private static CatalogTreeNode FindNode(IEnumerable<CatalogTreeNode> roots,
        string rootName, string nodeType, string nodeName)
    {
        CatalogTreeNode root = roots.Single(node => node.Name == rootName && node.Locator?.NodeType == "Root");
        CatalogTreeNode[] matches = (root.Children ?? []).Where(node =>
            node.Locator?.NodeType == nodeType && node.Name == nodeName).ToArray();
        if (matches.Length != 1) throw new InvalidDataException(
            $"Expected exactly one {nodeType} '{nodeName}' under {rootName}, found {matches.Length}.");
        return matches[0];
    }

    private static CatalogTreeNode FindChild(CatalogTreeNode parent, string nodeType, string nodeName)
    {
        CatalogTreeNode[] matches = (parent.Children ?? []).Where(node =>
            node.Locator?.NodeType == nodeType && node.Name == nodeName).ToArray();
        if (matches.Length != 1) throw new InvalidDataException(
            $"Expected exactly one direct {nodeType} child '{nodeName}' under '{parent.Name}', found {matches.Length}.");
        return matches[0];
    }

    private static CatalogTreeNodeLocator RequiredLocator(CatalogTreeNode node) => node.Locator
        ?? throw new InvalidDataException("A source map row omitted its exact serialized locator.");

    private static bool SameLocator(CatalogTreeNodeLocator left, CatalogTreeNodeLocator right) =>
        left.RootName == right.RootName && left.NodeType == right.NodeType && left.NodeName == right.NodeName &&
        (left.NodePath ?? []).SequenceEqual(right.NodePath ?? []) && SameOptionalPath(left.AssetID, right.AssetID) &&
        SameOptionalPath(left.ParentPlanAssetID, right.ParentPlanAssetID) &&
        (left.ParentPlanNodePath ?? []).SequenceEqual(right.ParentPlanNodePath ?? []) &&
        left.ParentPlanNodeName == right.ParentPlanNodeName &&
        left.ParentResultNodeType == right.ParentResultNodeType &&
        SameOptionalPath(left.ParentResultAssetID, right.ParentResultAssetID) &&
        (left.ParentResultNodePath ?? []).SequenceEqual(right.ParentResultNodePath ?? []) &&
        left.ParentResultNodeName == right.ParentResultNodeName &&
        string.Equals(left.ParentResultRevision, right.ParentResultRevision, StringComparison.OrdinalIgnoreCase);

    private static bool SameOptionalPath(string? left, string? right) => left is null || right is null
        ? left is null && right is null
        : SamePath(left, right);

    private static IEnumerable<CatalogTreeNode> Walk(IEnumerable<CatalogTreeNode> nodes)
    {
        foreach (CatalogTreeNode node in nodes)
        {
            yield return node;
            if (node.Children is { Length: > 0 } children)
                foreach (CatalogTreeNode child in Walk(children)) yield return child;
        }
    }

    private static string FixturePath(string root, string relative)
    {
        string path = Path.GetFullPath(Path.Combine(root,
            relative.Replace('/', Path.DirectorySeparatorChar)));
        string prefix = Path.GetFullPath(root) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new InvalidDataException("The acceptance manifest path escapes its private fixture copy.");
        if (!File.Exists(path)) throw new FileNotFoundException("A source fixture file is missing.", path);
        return path;
    }

    private static Dictionary<string, byte[]> CaptureBytes(IEnumerable<string> paths) =>
        paths.Distinct(PathComparer()).ToDictionary(path => path, File.ReadAllBytes, PathComparer());

    private static void AssertBytes(IReadOnlyDictionary<string, byte[]> original, string message)
    {
        Check(original.All(item => File.Exists(item.Key) && File.ReadAllBytes(item.Key).SequenceEqual(item.Value)), message);
    }

    private static string DirectoryDigest(string directory)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (string path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)
                     .OrderBy(path => Path.GetRelativePath(directory, path), StringComparer.Ordinal))
        {
            string relative = Path.GetRelativePath(directory, path).Replace(Path.DirectorySeparatorChar, '/');
            hash.AppendData(Encoding.UTF8.GetBytes(relative + "\0"));
            using FileStream stream = File.OpenRead(path);
            hash.AppendData(SHA256.HashData(stream));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static void CopyFixtureDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string folder in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, folder)));
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(destination, Path.GetRelativePath(source, file)), overwrite: false);
    }

    private static void RequireRevision(string path, string expected, string description) =>
        Check(Hash(path).Equals(expected, StringComparison.OrdinalIgnoreCase), description + " SHA matches the manifest.");

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static bool SamePath(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static StringComparer PathComparer() => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private sealed record FixtureProfile(int Index, string Name, string Time,
        float[] Flow, float[] OutsideDepth, float[] OutletVelocity);

    private sealed record ResultCapture(string Role, string Path, string Revision,
        int ProfileCount, string[] ProfileNames, FixtureProfile[] Profiles);

    private sealed record AcceptanceManifest(string ProjectRelativePath, string PlanRelativePath,
        string SharedPlanRelativePath, string AlternatePlanRelativePath,
        string GeometryRelativePath, string AlternateGeometryRelativePath,
        string BoundaryConditionRelativePath, string TerrainRasterRelativePath,
        string PlanName, string SharedPlanName, string AlternatePlanName,
        string GeometryName, string AlternateGeometryName,
        string BoundaryConditionName, string[] BarrelNames,
        ResultCapture[] Results);

}
