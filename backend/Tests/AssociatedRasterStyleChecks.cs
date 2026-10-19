using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;

/// <summary>
/// Exercises the retained continuous-raster style editor against real source
/// Geometry, Plan, and Result owners. All edits happen in private fixture
/// copies and are committed only to their saved map visualization.
/// </summary>
internal static class AssociatedRasterStyleChecks
{
    private const int PixelWidth = 32;
    private const int PixelHeight = 24;
    private static readonly MapGeometryViewport Viewport = new(0, 0, 16, 16);
    private static readonly JsonSerializerOptions WebJSON = new(JsonSerializerDefaults.Web);

    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        string associatedFixturePath = RequiredDirectory("HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY");
        string cpuFixturePath = RequiredDirectory("HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY");
        string associatedSourceDigest = DirectoryDigest(associatedFixturePath);
        string cpuSourceDigest = DirectoryDigest(cpuFixturePath);

        using var temporary = new TemporaryDirectory();
        string associatedRoot = Path.Combine(temporary.FullName, "associated");
        string cpuRoot = Path.Combine(temporary.FullName, "cpu");
        CopyDirectory(associatedFixturePath, associatedRoot);
        CopyDirectory(cpuFixturePath, cpuRoot);

        AssociatedFixture associated = ReadAssociatedFixture(associatedRoot);
        CpuFixture cpu = PrepareCpuFixture(cpuRoot);
        ExportAcceptanceFixture(temporary.FullName, associated, cpu);

        Dictionary<string, byte[]> protectedFiles = CaptureNonVisualizationFiles(associatedRoot, cpuRoot);
        var phase = new SourceCheckPhase();
        phase.Run("Optional Hillshade and Contours lifecycle",
            () => ExerciseOptionalStyleChildren(associated)).GetAwaiter().GetResult();
        phase.Run("Geometry-owned raster styles and rendering",
            () => ExerciseGeometryOwners(associated)).GetAwaiter().GetResult();
        phase.Run("Focused and shared Plan raster styles",
            () => ExercisePlanOwner(cpu)).GetAwaiter().GetResult();
        phase.Run("Nil Plan association style and rendering",
            () => ExerciseNilPlanAssociation(cpu)).GetAwaiter().GetResult();
        phase.Run("Previous-selected implicit Result-owned raster styles and rendering",
            () => ExercisePreviousResultOwner(cpu)).GetAwaiter().GetResult();
        phase.Run("Result-owned raster styles",
            () => ExerciseResultOwner(cpu)).GetAwaiter().GetResult();
        phase.Run("Protected source files and original fixtures", () =>
        {
            Dictionary<string, byte[]> protectedFilesAfter = CaptureNonVisualizationFiles(associatedRoot, cpuRoot);
            Check(SameFiles(protectedFiles, protectedFilesAfter),
                "Style load, Apply, reset, palette changes, stale-source checks, and rendering changed no Project, HDF, TIFF, or sidecar source bytes.");
            Check(DirectoryDigest(associatedFixturePath) == associatedSourceDigest &&
                  DirectoryDigest(cpuFixturePath) == cpuSourceDigest,
                "All operations preserve both original acceptance fixture directories; only private copies are edited.");
        }).GetAwaiter().GetResult();
        phase.ThrowIfFailed();

        Console.WriteLine("Associated raster styles round-trip against exact Geometry, Plan and selected Result owners; renderer output changes and source files remain byte-identical.");
    }

    private static AssociatedFixture ReadAssociatedFixture(string root)
    {
        string manifestPath = Path.Combine(root, "manifest.json");
        AssociatedMapManifest manifest = JsonSerializer.Deserialize<AssociatedMapManifest>(
            File.ReadAllText(manifestPath), WebJSON)
            ?? throw new InvalidDataException("The retained associated-map fixture manifest is missing.");
        string projectPath = FixturePath(root, manifest.Project);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        var map = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
            "r20-associated-raster-style-geometry", manifest.Map.MapIndex,
            manifest.Map.MapName, manifest.Map.MapType, Hash(visualizationPath));
        MapTreeSnapshot tree = MapTreeService.Load(map);

        CatalogTreeNodeLocator[] geometryNodes = manifest.Geometries.Select(geometry =>
        {
            string path = FixturePath(root, geometry.Path);
            CatalogTreeNode node = FindNode(tree.Roots, candidate =>
                candidate.Locator is { RootName: "Focused Geometries", NodeType: "Geometry" } locator &&
                locator.NodeName == geometry.NodeName && locator.AssetID is { } asset && SamePath(asset, path),
                "focused Geometry " + geometry.NodeName);
            return RequiredLocator(node);
        }).ToArray();

        AssociatedAssociationEntry terrainAssociation = manifest.Associations.Single(item => item.Kind == "Terrain");
        CatalogTreeNodeLocator terrain = FindAssociation(tree.Roots, "Terrain", terrainAssociation.Name,
            FixturePath(root, terrainAssociation.Path));
        AssociatedAssociationEntry nvalueAssociation = manifest.Associations.Single(item => item.Kind == "NValue");
        CatalogTreeNodeLocator nvalue = FindAssociation(tree.Roots, "NValue", nvalueAssociation.Name,
            FixturePath(root, nvalueAssociation.Path));
        return new(root, manifest, projectPath, visualizationPath, map, geometryNodes,
            terrain, nvalue);
    }

    private static CpuFixture PrepareCpuFixture(string root)
    {
        CpuAcceptanceManifest manifest = JsonSerializer.Deserialize<CpuAcceptanceManifest>(
            File.ReadAllText(Path.Combine(root, "acceptance.json")), WebJSON)
            ?? throw new InvalidDataException("The retained CPU solver fixture manifest is missing.");
        if (manifest.Results.Length != 2 ||
            !manifest.Results.Select(result => result.Role).SequenceEqual(["signed-flow", "zero-flow"]))
            throw new InvalidDataException("The CPU solver fixture must contain its real signed-flow and zero-flow Results in source order.");

        string projectPath = FixturePath(root, manifest.ProjectRelativePath);
        string planPath = FixturePath(root, manifest.PlanRelativePath);
        string geometryPath = FixturePath(root, manifest.GeometryRelativePath);
        string terrainRasterPath = FixturePath(root, manifest.TerrainRasterRelativePath);
        string[] resultPaths = manifest.Results.Select(result => FixturePath(root, result.Path)).ToArray();
        byte[][] resultBytes = resultPaths.Select(File.ReadAllBytes).ToArray();
        ConfigureAlternatePlanTerrain(projectPath, manifest.AlternateGeometryName, terrainRasterPath);
        Check(resultPaths.Select((path, index) =>
                  File.ReadAllBytes(path).SequenceEqual(resultBytes[index])).All(unchanged => unchanged),
            "The private Plan association setup leaves both solver Result HDFs byte-identical.");

        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        string? initialRevision = File.Exists(visualizationPath) ? Hash(visualizationPath) : null;
        string planRevision = Hash(planPath);
        MapDocumentMutationReceipt planReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, initialRevision, "Plan",
            Name: "R20 Associated Style Plan", InitialPlanPath: planPath,
            InitialPlanRevision: planRevision));
        var planMap = MapRequest(projectPath, projectXml, projectXmlSHA,
            "r20-associated-raster-style-plan", planReceipt);
        MapDocumentMutationReceipt resultMapReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA, planReceipt.VisualizationRevision,
            "Geometry", Name: "R20 Associated Style Result",
            InitialGeometryPath: geometryPath, InitialGeometryRevision: Hash(geometryPath)));
        var resultMap = MapRequest(projectPath, projectXml, projectXmlSHA,
            "r20-associated-raster-style-result", resultMapReceipt);
        CpuResultManifest selectedResult = manifest.Results.Single(result => result.Role == "signed-flow");
        string resultPath = FixturePath(root, selectedResult.Path);
        MapTreeMutationResult added = MapTreeService.Perform(new MapTreeActionRequest(
            resultMap, "addResult", SourcePath: resultPath, SourceRevision: Hash(resultPath)));
        resultMap = resultMap with
        {
            ExpectedVisualizationRevision = added.VisualizationRevision,
            ResultSelectionOverrides = [new MapTreeResultSelectionOverride(planPath,
                manifest.PlanName, resultPath, Hash(resultPath))]
        };
        MapTreeSnapshot resultTree = MapTreeService.Load(resultMap);
        CatalogTreeNode resultGroup = FindNode(resultTree.Roots, candidate =>
            candidate.Locator is { RootName: "Layers", NodeType: "MultiResult" } locator &&
            locator.NodeName == manifest.PlanName,
            "the exact Plan Result group in the saved Geometry map");
        CatalogTreeNodeLocator resultLocator = RequiredLocator(resultGroup);
        MapResultSourcesResult resultSources = MapResultChartService.Sources(new(resultMap, []));
        MapResultActiveNode activeResult = resultSources.ActiveNodes.Single(candidate =>
            candidate.NodeKind == "MultiResult" && SameLocator(candidate.Node, resultLocator));
        MapResultSourceChoice selected = activeResult.Selections.Single(slot => slot.SelectionIndex == 0)
            .SelectedResult ?? throw new InvalidDataException("The exact Result map group did not resolve its selected source HDF.");
        if (!SamePath(selected.ResultPath, resultPath) ||
            !string.Equals(selected.Revision, Hash(resultPath), StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
        CatalogTreeNode resultTerrain = FindNode(resultTree.Roots, candidate =>
            candidate.Locator is { NodeType: "Terrain", ParentResultNodeType: "MultiResult" } locator &&
            locator.ParentResultNodeName == manifest.PlanName &&
            locator.ParentResultRevision is { } revision &&
            revision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase) &&
            locator.ParentResultAssetID is { } parent && SamePath(parent, selected.ResultPath),
            "Terrain under the exact selected Result HDF");

        return new(root, manifest, projectPath, planPath, manifest.PlanName,
            FixturePath(root, manifest.SharedPlanRelativePath), manifest.SharedPlanName,
            FixturePath(root, manifest.AlternatePlanRelativePath), manifest.AlternatePlanName,
            planMap, resultMap, resultLocator, selected,
            RequiredLocator(resultTerrain), SourcePath(resultTerrain));
    }

    private static void ConfigureAlternatePlanTerrain(string projectPath,
        string alternateGeometryName, string sourceRasterPath)
    {
        Project project = new(projectPath);
        try
        {
            Geometry alternateGeometry = project.Geometries.Single(geometry =>
                geometry.Name == alternateGeometryName);
            Terrain alternateTerrain = project.AddNewTerrain("R20 Alternate Plan Terrain");
            string alternateRasterPath = Path.Combine(alternateTerrain.SourceDirectory,
                "R20 Alternate Plan Terrain.tif");
            Directory.CreateDirectory(alternateTerrain.SourceDirectory);
            File.Copy(sourceRasterPath, alternateRasterPath);
            alternateTerrain.Add(RasterTerrainInput.CreateAndScan(alternateTerrain,
                alternateRasterPath));
            project.GetGeometryAssociation(alternateGeometry).Terrain = alternateTerrain;
            alternateTerrain.Save();
            project.Save();
        }
        finally
        {
            foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                .Concat(project.Geometries).Concat(project.Terrains).Concat(project.BoundaryConditions)
                .Concat(project.NValues).Concat(project.ClassificationLayers))
                layer.Dispose();
            foreach (Result result in project.Results) result.Dispose();
        }
    }

    private static void ExerciseGeometryOwners(AssociatedFixture fixture)
    {
        MapTreeSnapshot tree = MapTreeService.Load(RefreshMapRevision(fixture.Map));
        CatalogTreeNodeLocator terrain = FindAssociationLocator(tree.Roots, "Terrain", fixture.Terrain.NodeName,
            fixture.Terrain.AssociationAssetID ?? fixture.Terrain.AssetID!);
        CatalogTreeNodeLocator nvalue = FindAssociationLocator(tree.Roots, "NValue", fixture.NValue.NodeName,
            fixture.NValue.AssociationAssetID ?? fixture.NValue.AssetID!);
        var terrainRequest = StyleRequest(fixture.Map, terrain,
            SourcePath(terrain), geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot terrainInitial = AssociatedRasterStyleService.Load(terrainRequest);
        Check(terrainInitial.SourceKind == "Terrain" && terrainInitial.CanComputeHistogram &&
              terrainInitial.SourceHistogramValues is { Length: >= 2 } values && values.All(double.IsFinite) &&
              terrainInitial.Draft.ValueSource == "Histogram",
            "The exact shared Geometry/Terrain row reports its retained histogram source, finite source-derived values and actual histogram capability.");
        Check(terrainInitial.GeometryNodes.Select(node => node.NodeName).SequenceEqual(
                fixture.GeometryNodes.Select(node => node.NodeName)) &&
              terrainInitial.Dependencies.Any(item => item.Role == "geometry-hdf" &&
                  fixture.GeometryNodes.All(geometry => terrainInitial.Dependencies.Any(dependency =>
                      dependency.Role == "geometry-hdf" && SamePath(dependency.Path, geometry.AssetID!)))) &&
              terrainInitial.Dependencies.Any(item => item.Role == "terrain-input-raster" && item.Revision != "missing"),
            "The style snapshot binds the complete shared-Geometry owner set, Terrain HDF and real TIFF dependency by exact identity and revision.");

        var nvalueRequest = StyleRequest(fixture.Map, nvalue,
            SourcePath(nvalue), geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot nvalueInitial = AssociatedRasterStyleService.Load(nvalueRequest);
        Check(nvalueInitial.SourceKind == "NValue" && nvalueInitial.Draft.ValueSource == "Manual" &&
              nvalueInitial.CanComputeHistogram &&
              nvalueInitial.Dependencies.Any(item => item.Role == "classification-source-hdf") &&
              nvalueInitial.Dependencies.Any(item => item.Role == "classification-input-raster" && item.Revision != "missing"),
            "The exact shared Geometry/NValue row retains its Manual default and includes its associated Classification HDF/TIFF dependencies.");

        AssociatedMapLayerSnapshot terrainBefore = Render(fixture.Map, fixture.GeometryNodes, terrain);
        AssociatedMapLayerSnapshot nvalueBefore = Render(fixture.Map, fixture.GeometryNodes, nvalue);
        Check(terrainBefore.Status == "available" && terrainBefore.Rgba.Length == PixelWidth * PixelHeight * 4 &&
              nvalueBefore.Status == "available" && nvalueBefore.Rgba.Length == PixelWidth * PixelHeight * 4,
            "Both exact shared source rows render actual retained pixels before style edits.");

        InjectUnknownVisualizationData(fixture.Map, terrain);
        MapTreeRequest map = RefreshMapRevision(fixture.Map);
        terrain = FindAssociationLocator(MapTreeService.Load(map).Roots, "Terrain",
            terrain.NodeName, terrain.AssociationAssetID ?? terrain.AssetID!);
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        terrainInitial = AssociatedRasterStyleService.Load(terrainRequest);

        string customPalette = "R20 Raster Palette";
        AssociatedRasterStyleDraft manual = MakeDraft(terrainInitial.Draft, "Manual",
            "R20 Manual Palette", ["#FFFF00FF", "#FF00FFFF"]);
        AssociatedRasterStyleService.Apply(ApplyRequest(terrainRequest, manual,
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: customPalette)));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        terrain = FindAssociationLocator(tree.Roots, "Terrain", terrain.NodeName,
            terrain.AssociationAssetID ?? terrain.AssetID!);
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot manualReadback = AssociatedRasterStyleService.Load(terrainRequest);
        Check(manualReadback.Draft.ValueSource == "Manual" && manualReadback.Draft.Name == customPalette &&
              manualReadback.Palettes.Any(palette => palette.IsCustom && palette.Name == customPalette) &&
              manualReadback.Draft.Stops.Length == 2 &&
              manualReadback.Draft.Stops[0].Color == "#FFFF00FF" &&
              manualReadback.Draft.Stops[1].Color == "#FF00FFFF",
            "A real Manual palette can be saved, selected and reopened with its exact color/value stops.");
        AssociatedMapLayerSnapshot terrainAfterManual = Render(map, fixture.GeometryNodes, terrain);
        Check(terrainAfterManual.Status == "available" &&
              !terrainBefore.Rgba.SequenceEqual(terrainAfterManual.Rgba),
            "Applying the Manual palette changes actual Terrain RGBA pixels through AssociatedMapLayersService.");

        AssociatedRasterStyleDraft linear = MakeDraft(manualReadback.Draft, "Linear",
            "R20 Linear Ramp", ["#FF000000", "#FFFFA500", "#FFFFFFFF"]);
        AssociatedRasterStyleService.Apply(ApplyRequest(terrainRequest, linear));
        map = RefreshMapRevision(map);
        terrain = FindAssociationLocator(MapTreeService.Load(map).Roots, "Terrain",
            terrain.NodeName, terrain.AssociationAssetID ?? terrain.AssetID!);
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot linearReadback = AssociatedRasterStyleService.Load(terrainRequest);
        Check(linearReadback.Draft.ValueSource == "Linear" && linearReadback.Draft.Stops.Length == 3 &&
              NearlyEqual(linearReadback.Draft.Stops[1].Value,
                  (linearReadback.Draft.Stops[0].Value + linearReadback.Draft.Stops[^1].Value) / 2),
            "Linear interpolation stores explicit endpoints and recomputes the interior source value evenly.");

        AssociatedRasterStyleDraft histogram = MakeDraft(linearReadback.Draft, "Histogram",
            "R20 Histogram Ramp", ["#FF2E3192", "#FF1BFFFF", "#FFFFD200"]);
        AssociatedRasterStyleService.Apply(ApplyRequest(terrainRequest, histogram));
        map = RefreshMapRevision(map);
        terrain = FindAssociationLocator(MapTreeService.Load(map).Roots, "Terrain",
            terrain.NodeName, terrain.AssociationAssetID ?? terrain.AssetID!);
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot histogramReadback = AssociatedRasterStyleService.Load(terrainRequest);
        Check(histogramReadback.Draft.ValueSource == "Histogram" &&
              histogramReadback.CanComputeHistogram && histogramReadback.SourceHistogramValues is
                  { Length: 3 } histogramValues && histogramReadback.Draft.Stops.Select(stop => stop.Value)
                  .SequenceEqual(histogramValues),
            "Histogram mode recomputes values from the exact retained source and reopens the same values in the editor.");

        AssociatedRasterStyleService.Apply(ApplyRequest(terrainRequest, histogramReadback.ResetDraft,
            new AssociatedRasterStylePaletteMutation("deleteCustom", PaletteID: customPalette)));
        map = RefreshMapRevision(map);
        terrain = FindAssociationLocator(MapTreeService.Load(map).Roots, "Terrain",
            terrain.NodeName, terrain.AssociationAssetID ?? terrain.AssetID!);
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot resetReadback = AssociatedRasterStyleService.Load(terrainRequest);
        Check(EquivalentStyle(resetReadback.Draft, resetReadback.ResetDraft) &&
              !resetReadback.Palettes.Any(palette => palette.Name == customPalette),
            "Reset returns the exact current source defaults, and deleting a custom palette is committed with the map style.");
        AssertUnknownVisualizationData(map, terrain);

        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        nvalue = FindAssociationLocator(tree.Roots, "NValue", nvalue.NodeName,
            nvalue.AssociationAssetID ?? nvalue.AssetID!);
        nvalueRequest = StyleRequest(map, nvalue, SourcePath(nvalue),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot nvalueCurrent = AssociatedRasterStyleService.Load(nvalueRequest);
        map = ExerciseDuplicateWindSpeedPalettes(map, nvalueRequest, nvalueCurrent);
        tree = MapTreeService.Load(map);
        nvalue = FindAssociationLocator(tree.Roots, "NValue", nvalue.NodeName,
            nvalue.AssociationAssetID ?? nvalue.AssetID!);
        nvalueRequest = StyleRequest(map, nvalue, SourcePath(nvalue),
            geometryNodes: fixture.GeometryNodes);
        nvalueCurrent = AssociatedRasterStyleService.Load(nvalueRequest);
        AssertUnknownVisualizationData(map, terrain);
        AssociatedRasterStyleDraft nvalueManual = MakeDraft(nvalueCurrent.Draft, "Manual",
            "R20 NValue Contrast", ["#FF000000", "#FFFF4000"]);
        AssociatedRasterStyleService.Apply(ApplyRequest(nvalueRequest, nvalueManual));
        map = RefreshMapRevision(map);
        nvalue = FindAssociationLocator(MapTreeService.Load(map).Roots, "NValue", nvalue.NodeName,
            nvalue.AssociationAssetID ?? nvalue.AssetID!);
        nvalueRequest = StyleRequest(map, nvalue, SourcePath(nvalue),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot nvalueManualReadback = AssociatedRasterStyleService.Load(nvalueRequest);
        Check(nvalueManualReadback.Draft.ValueSource == "Manual" &&
              nvalueManualReadback.Draft.Stops.Select(stop => stop.Value).SequenceEqual(
                  nvalueManual.Stops.Select(stop => stop.Value)),
            "Manual NValue endpoints preserve user-entered values on readback.");
        AssociatedMapLayerSnapshot nvalueAfterManual = Render(map, fixture.GeometryNodes, nvalue);
        Check(nvalueAfterManual.Status == "available" &&
              !nvalueBefore.Rgba.SequenceEqual(nvalueAfterManual.Rgba),
            "Applying the Manual NValue style changes actual rendered NValue pixels.");

        AssociatedRasterStyleDraft nvalueHistogram = MakeDraft(nvalueManualReadback.Draft,
            "Histogram", "R20 NValue Histogram", ["#FF30123B", "#FF04D8C7", "#FFFCEB00"]);
        AssociatedRasterStyleService.Apply(ApplyRequest(nvalueRequest, nvalueHistogram));
        map = RefreshMapRevision(map);
        nvalue = FindAssociationLocator(MapTreeService.Load(map).Roots, "NValue", nvalue.NodeName,
            nvalue.AssociationAssetID ?? nvalue.AssetID!);
        nvalueRequest = StyleRequest(map, nvalue, SourcePath(nvalue),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot nvalueHistogramReadback = AssociatedRasterStyleService.Load(nvalueRequest);
        Check(nvalueHistogramReadback.Draft.ValueSource == "Histogram" &&
              nvalueHistogramReadback.CanComputeHistogram && nvalueHistogramReadback.SourceHistogramValues is
                  { Length: 3 } nvalueHistogramValues && nvalueHistogramReadback.Draft.Stops.Select(stop => stop.Value)
                  .SequenceEqual(nvalueHistogramValues),
            "NValue Histogram mode is available only with its actual Classification source and reopens computed values.");
        AssociatedRasterStyleService.Apply(ApplyRequest(nvalueRequest, nvalueHistogramReadback.ResetDraft));

        // A Matching Layers row is valid only with the complete exact owner
        // list. A subset cannot borrow a same-named Geometry's association.
        map = RefreshMapRevision(fixture.Map);
        tree = MapTreeService.Load(map);
        terrain = FindAssociationLocator(tree.Roots, "Terrain", fixture.Terrain.NodeName,
            fixture.Terrain.AssociationAssetID ?? fixture.Terrain.AssetID!);
        Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Load(
            StyleRequest(map, terrain, SourcePath(terrain),
                geometryNodes: [fixture.GeometryNodes[0]])));

        // Source HDF and TIFF changes invalidate captured requests. The bytes
        // are restored immediately so the following tests use the real source.
        terrainRequest = StyleRequest(map, terrain, SourcePath(terrain),
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot staleSource = AssociatedRasterStyleService.Load(terrainRequest);
        byte[] hdfBytes = File.ReadAllBytes(staleSource.SourcePath);
        File.WriteAllBytes(staleSource.SourcePath, [.. hdfBytes, 0]);
        try
        {
            Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Apply(
                ApplyRequest(terrainRequest, staleSource.Draft)));
        }
        finally { File.WriteAllBytes(staleSource.SourcePath, hdfBytes); }

        AssociatedRasterStyleSnapshot staleRaster = AssociatedRasterStyleService.Load(terrainRequest);
        AssociatedRasterStyleDependency raster = staleRaster.Dependencies.Single(item =>
            item.Role == "terrain-input-raster" && item.Revision != "missing");
        byte[] rasterBytes = File.ReadAllBytes(raster.Path);
        File.WriteAllBytes(raster.Path, [.. rasterBytes, 0]);
        try
        {
            Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Apply(
                ApplyRequest(terrainRequest, staleRaster.Draft)));
        }
        finally { File.WriteAllBytes(raster.Path, rasterBytes); }

        AssociatedRasterStyleSnapshot staleVisualization = AssociatedRasterStyleService.Load(terrainRequest);
        var visibilityChange = MapTreeService.Perform(new MapTreeActionRequest(map,
            "visibility", Node: terrain, Checked: false));
        Check(visibilityChange.VisualizationRevision != map.ExpectedVisualizationRevision,
            "A real saved visibility change advances the map visualization revision.");
        Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Apply(
            ApplyRequest(terrainRequest, staleVisualization.Draft)));
    }

    private static MapTreeRequest ExerciseDuplicateWindSpeedPalettes(MapTreeRequest map,
        AssociatedRasterStyleRequest request, AssociatedRasterStyleSnapshot initial)
    {
        AssociatedRasterStylePalette[] windSpeed = initial.Palettes
            .Where(palette => palette.Name == "Wind Speed")
            .OrderBy(palette => palette.Id, StringComparer.Ordinal)
            .ToArray();
        if (windSpeed.Length != 2)
            throw new InvalidDataException($"Expected two retained Wind Speed palettes; found {windSpeed.Length}.");
        double[] firstWindValues = windSpeed[0].Values ??
            throw new InvalidDataException("The first retained Wind Speed palette has no source values.");
        double[] secondWindValues = windSpeed[1].Values ??
            throw new InvalidDataException("The second retained Wind Speed palette has no source values.");
        Check(initial.Palettes.Select(palette => palette.Id).Distinct(StringComparer.Ordinal).Count() ==
              initial.Palettes.Length,
            "Every palette returned for the real NValue source has a unique stable selector ID.");
        Check(windSpeed.All(palette => palette.Colors.Length == 25 &&
                  palette.ValueSource == "Manual") && firstWindValues.Length == 25 &&
              secondWindValues.Length == 25 && !firstWindValues.SequenceEqual(secondWindValues),
            "Both retained Wind Speed palettes expose their distinct 25-color Manual ramps and value ranges.");

        AssociatedRasterStyleDraft currentDraft = initial.Draft;
        foreach (AssociatedRasterStylePalette palette in windSpeed)
        {
            double[] values = palette.Values ??
                throw new InvalidDataException("A retained Wind Speed palette lost its source value range.");
            AssociatedRasterStyleDraft selected = currentDraft with
            {
                PaletteID = palette.Id,
                Name = palette.Name,
                Stops = palette.Colors.Select((color, index) =>
                    new AssociatedRasterStyleColorStop(index, color, values[index])).ToArray(),
                ValueSource = palette.ValueSource,
                IsEditing = true
            };
            AssociatedRasterStyleService.Apply(ApplyRequest(request, selected));

            map = RefreshMapRevision(map);
            request = StyleRequest(map, request.Node, request.SourcePath,
                geometryNodes: request.GeometryNodes);
            AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(request);
            Check(reopened.Draft.PaletteID == palette.Id &&
                  reopened.Draft.ValueSource == palette.ValueSource &&
                  reopened.Draft.Stops.Length == 25 &&
                  reopened.Draft.Stops.Select(stop => stop.Index).SequenceEqual(Enumerable.Range(0, 25)) &&
                  reopened.Draft.Stops.Select(stop => stop.Color).SequenceEqual(palette.Colors) &&
                  reopened.Draft.Stops.Select(stop => stop.Value).SequenceEqual(values),
                "Applying and reopening a duplicate-name Wind Speed palette preserves its exact ID and all 25 stops without selecting the other range.");
            currentDraft = reopened.Draft;
        }
        return map;
    }

    private static void ExerciseOptionalStyleChildren(AssociatedFixture fixture)
    {
        MapTreeRequest map = RefreshMapRevision(fixture.Map);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNodeLocator nvalue = FindAssociationLocator(tree.Roots, "NValue",
            fixture.NValue.NodeName, fixture.NValue.AssociationAssetID ?? fixture.NValue.AssetID!);
        string sourcePath = SourcePath(nvalue);
        AssociatedRasterStyleRequest request = StyleRequest(map, nvalue, sourcePath,
            geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot initial = AssociatedRasterStyleService.Load(request);
        Check(!initial.Draft.HillshadeEnabled && !initial.ResetDraft.HillshadeEnabled &&
              !initial.Draft.ContoursEnabled && !initial.ResetDraft.ContoursEnabled &&
              initial.Draft.HillshadeZFactor == 3 && initial.Draft.HillshadeAzimuth == 315 &&
              initial.Draft.HillshadeZenith == 45 && initial.Draft.ContoursAuto &&
              initial.Draft.ContourInterval == 10 && initial.Draft.ContourIndexEvery == 5 &&
              initial.Draft.ContourColorArgb == -16777216 && initial.Draft.ContourOpacity == 70 &&
              initial.Draft.ContourShowLabels && initial.Draft.ContourDensity == 1,
            "A sparse source NValue starts with the retained Hillshade and Contours defaults.");

        XElement InitialNode() => ResolveSavedTreeNode(
            SavedMap(XDocument.Load(Path.ChangeExtension(map.ProjectPath, ".vis"),
                LoadOptions.PreserveWhitespace), map.MapIndex), nvalue.NodePath ??
                throw new InvalidDataException("The sparse NValue row needs its exact saved source path."));

        Check(InitialNode().Element("RasterSymbology") is null,
            "The source NValue starts without a serialized RasterSymbology node.");
        AssociatedRasterStyleService.Apply(ApplyRequest(request, initial.Draft));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        nvalue = FindAssociationLocator(tree.Roots, "NValue", fixture.NValue.NodeName,
            fixture.NValue.AssociationAssetID ?? fixture.NValue.AssetID!);
        request = StyleRequest(map, nvalue, sourcePath, geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot defaultReadback = AssociatedRasterStyleService.Load(request);
        XElement defaultNode = ResolveSavedTreeNode(
            SavedMap(XDocument.Load(Path.ChangeExtension(map.ProjectPath, ".vis"),
                LoadOptions.PreserveWhitespace), map.MapIndex), nvalue.NodePath!);
        XElement defaultRaster = defaultNode.Element("RasterSymbology") ??
            throw new InvalidDataException("Applying source defaults should preserve the base raster style.");
        Check(defaultRaster.Element("Hillshade") is null && defaultRaster.Element("Contours") is null &&
              !defaultReadback.Draft.HillshadeEnabled && !defaultReadback.Draft.ContoursEnabled,
            "Applying default Hillshade and Contours to a sparse source succeeds while omitting both optional XML children.");

        AssociatedRasterStyleDraft enabled = defaultReadback.Draft with
        {
            HillshadeEnabled = true,
            HillshadeZFactor = 4.25,
            HillshadeAzimuth = 220,
            HillshadeZenith = 35,
            ContoursEnabled = true,
            ContoursAuto = false,
            ContourInterval = 2.5,
            ContourIndexEvery = 2,
            ContourColorArgb = unchecked((int)0xFF35A7D4),
            ContourOpacity = 85,
            ContourShowLabels = false,
            ContourDensity = 1.25
        };
        AssociatedRasterStyleService.Apply(ApplyRequest(request, enabled));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        nvalue = FindAssociationLocator(tree.Roots, "NValue", fixture.NValue.NodeName,
            fixture.NValue.AssociationAssetID ?? fixture.NValue.AssetID!);
        request = StyleRequest(map, nvalue, sourcePath, geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(request);
        XElement reopenedNode = ResolveSavedTreeNode(
            SavedMap(XDocument.Load(Path.ChangeExtension(map.ProjectPath, ".vis"),
                LoadOptions.PreserveWhitespace), map.MapIndex), nvalue.NodePath!);
        XElement reopenedRaster = reopenedNode.Element("RasterSymbology") ??
            throw new InvalidDataException("The edited raster style was not persisted.");
        Check(reopened.Draft.HillshadeEnabled && reopened.Draft.HillshadeZFactor == 4.25 &&
              reopened.Draft.HillshadeAzimuth == 220 && reopened.Draft.HillshadeZenith == 35 &&
              reopened.Draft.ContoursEnabled && !reopened.Draft.ContoursAuto &&
              reopened.Draft.ContourInterval == 2.5 && reopened.Draft.ContourIndexEvery == 2 &&
              reopened.Draft.ContourColorArgb == unchecked((int)0xFF35A7D4) &&
              reopened.Draft.ContourOpacity == 85 && !reopened.Draft.ContourShowLabels &&
              reopened.Draft.ContourDensity == 1.25 &&
              reopenedRaster.Element("Hillshade") is { } savedHillshade &&
              (string?)savedHillshade.Attribute("IsEnabled") == "true" &&
              (string?)savedHillshade.Attribute("ZFactor") == "4.25" &&
              reopenedRaster.Element("Contours") is { } savedContours &&
              (string?)savedContours.Attribute("IsEnabled") == "true" &&
              (string?)savedContours.Attribute("Auto") == "false" &&
              (string?)savedContours.Attribute("Interval") == "2.5" &&
              (string?)savedContours.Attribute("IndexEvery") == "2",
            "Non-default Hillshade and Contours attributes persist in the exact source row and reopen with their values.");

        AssociatedRasterStyleService.Apply(ApplyRequest(request, reopened.ResetDraft));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        nvalue = FindAssociationLocator(tree.Roots, "NValue", fixture.NValue.NodeName,
            fixture.NValue.AssociationAssetID ?? fixture.NValue.AssetID!);
        request = StyleRequest(map, nvalue, sourcePath, geometryNodes: fixture.GeometryNodes);
        AssociatedRasterStyleSnapshot reset = AssociatedRasterStyleService.Load(request);
        XElement resetNode = ResolveSavedTreeNode(
            SavedMap(XDocument.Load(Path.ChangeExtension(map.ProjectPath, ".vis"),
                LoadOptions.PreserveWhitespace), map.MapIndex), nvalue.NodePath!);
        XElement resetRaster = resetNode.Element("RasterSymbology") ??
            throw new InvalidDataException("Reset should retain the source surface fill.");
        Check(!reset.Draft.HillshadeEnabled && !reset.Draft.ContoursEnabled &&
              resetRaster.Element("Hillshade") is null && resetRaster.Element("Contours") is null,
            "Resetting to the exact NValue defaults removes the previously serialized optional children.");
    }

    private static void ExercisePlanOwner(CpuFixture fixture)
    {
        MapTreeRequest map = RefreshMapRevision(fixture.PlanMap);
        map = FocusPlan(map, fixture.SharedPlanPath);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode[] focusedPlans = FindFocusedPlans(tree.Roots);
        Check(focusedPlans.Length == 2 && SamePath(focusedPlans[0].Locator!.AssetID!, fixture.PlanPath) &&
              SamePath(focusedPlans[1].Locator!.AssetID!, fixture.SharedPlanPath),
            "The shared Plan fixture contains two exact focused source Plans before resolving a common association.");
        CatalogTreeNode terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { RootName: "Matching Layers", NodeType: "Terrain", AssociationKind: "Terrain" },
            "shared Terrain row under Plan Matching Layers");
        CatalogTreeNodeLocator[] sharedPlanLocators = focusedPlans.Select(RequiredLocator).ToArray();
        CatalogTreeNodeLocator terrainLocator = RequiredLocator(terrain);
        string sourcePath = SourcePath(terrain);
        AssociatedRasterStyleRequest request = StyleRequest(map, terrainLocator,
            sourcePath, planNodes: sharedPlanLocators);
        AssociatedRasterStyleSnapshot initial = AssociatedRasterStyleService.Load(request);
        Check(initial.MapType == "Plan" && initial.PlanNodes is { Length: 2 } owners &&
              owners.Select(owner => owner.NodeName).SequenceEqual(sharedPlanLocators.Select(owner => owner.NodeName)) &&
              owners.All(owner => sharedPlanLocators.Any(expected => SameLocator(owner, expected))) &&
              initial.Dependencies.Count(dependency => dependency.Role == "plan-hdf") == 2 &&
              initial.Dependencies.Any(dependency => dependency.Role == "plan-hdf" &&
                  SamePath(dependency.Path, fixture.PlanPath) &&
                  dependency.Revision.Equals(Hash(fixture.PlanPath), StringComparison.OrdinalIgnoreCase)) &&
              initial.Dependencies.Any(dependency => dependency.Role == "plan-hdf" &&
                  SamePath(dependency.Path, fixture.SharedPlanPath) &&
                  dependency.Revision.Equals(Hash(fixture.SharedPlanPath), StringComparison.OrdinalIgnoreCase)),
            "A shared Plan Matching Layers style echoes both exact Plan owners and captures each HDF dependency.");
        AssociatedRasterStyleService.Apply(ApplyRequest(request,
            MakeDraft(initial.Draft, "Manual", "R20 Shared Plan Style", ["#FF102030", "#FFE0D0C0"]),
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: "R20 Shared Plan Style")));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        focusedPlans = FindFocusedPlans(tree.Roots);
        terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { RootName: "Matching Layers", NodeType: "Terrain", AssociationKind: "Terrain" },
            "reopened shared Terrain row");
        request = StyleRequest(map, RequiredLocator(terrain), SourcePath(terrain),
            planNodes: focusedPlans.Select(RequiredLocator).ToArray());
        AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(request);
        Check(reopened.Draft.ValueSource == "Manual" && reopened.Draft.Name == "R20 Shared Plan Style" &&
              reopened.PlanNodes is { Length: 2 } &&
              reopened.PlanNodes.Any(owner => SamePath(owner.AssetID!, fixture.PlanPath)) &&
              reopened.PlanNodes.Any(owner => SamePath(owner.AssetID!, fixture.SharedPlanPath)),
            "The shared Plan Terrain style persists and reopens with the same exact focused Plan owner set.");

        // A second map focuses two Plans whose source Geometry HDFs differ.
        // A style request for one Plan child must carry only that exact parent,
        // even though another Plan is also focused on this saved map.
        string projectXml = File.ReadAllText(fixture.ProjectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        MapDocumentMutationReceipt nonsharedReceipt = MapTreeService.CreateMap(new MapDocumentRequest(
            fixture.ProjectPath, projectXml, projectXmlSHA,
            Hash(Path.ChangeExtension(fixture.ProjectPath, ".vis")),
            "Plan", Name: "R20 Nonshared Plan Styles", InitialPlanPath: fixture.PlanPath,
            InitialPlanRevision: Hash(fixture.PlanPath)));
        MapTreeRequest nonsharedMap = MapRequest(fixture.ProjectPath, projectXml, projectXmlSHA,
            "r20-associated-style-nonshared-plan", nonsharedReceipt);
        nonsharedMap = FocusPlan(nonsharedMap, fixture.AlternatePlanPath);
        MapTreeSnapshot nonsharedTree = MapTreeService.Load(nonsharedMap);
        CatalogTreeNode[] nonsharedPlans = FindFocusedPlans(nonsharedTree.Roots);
        Check(nonsharedPlans.Length == 2 &&
              nonsharedPlans.Select(plan => (plan.Children ?? []).Single(child =>
                      child.Locator?.NodeType == "Geometry").Locator!.AssetID!)
                  .Distinct(PathComparer).Count() == 2,
            "The second saved Plan map focuses two Plans with distinct source Geometry owners.");
        CatalogTreeNode mainPlan = nonsharedPlans.Single(plan =>
            SamePath(plan.Locator!.AssetID!, fixture.PlanPath));
        CatalogTreeNode alternatePlan = nonsharedPlans.Single(plan =>
            SamePath(plan.Locator!.AssetID!, fixture.AlternatePlanPath));
        CatalogTreeNodeLocator mainPlanLocator = RequiredLocator(mainPlan);
        CatalogTreeNodeLocator alternatePlanLocator = RequiredLocator(alternatePlan);
        CatalogTreeNode mainTerrain = FindNode(mainPlan.Children ?? [], candidate => candidate.Locator is
            { NodeType: "Terrain" } locator && IsDirectPlanChild(locator, mainPlanLocator),
            "Terrain below one exact focused Plan");
        CatalogTreeNode alternateTerrain = FindNode(alternatePlan.Children ?? [], candidate => candidate.Locator is
            { NodeType: "Terrain" } locator && IsDirectPlanChild(locator, alternatePlanLocator),
            "Terrain below the other exact focused Plan");
        Check(!SamePath(SourcePath(mainTerrain), SourcePath(alternateTerrain)),
            "The two focused Plans retain distinct Terrain HDF owners, so the main Plan child is not promoted into Matching Layers.");
        AssociatedRasterStyleRequest singletonRequest = StyleRequest(nonsharedMap,
            RequiredLocator(mainTerrain), SourcePath(mainTerrain), planNodes: [mainPlanLocator]);
        AssociatedRasterStyleSnapshot singleton = AssociatedRasterStyleService.Load(singletonRequest);
        Check(singleton.PlanNodes is { Length: 1 } && SameLocator(singleton.PlanNodes[0], mainPlanLocator) &&
              singleton.Dependencies.Count(dependency => dependency.Role == "plan-hdf") == 1,
            "A focused Plan child resolves and hashes only its singleton exact parent owner.");
        AssociatedRasterStyleService.Apply(ApplyRequest(singletonRequest,
            MakeDraft(singleton.Draft, "Manual", "R20 Singleton Plan Style", ["#FF122334", "#FFEECCAA"]),
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: "R20 Singleton Plan Style")));
        nonsharedMap = RefreshMapRevision(nonsharedMap);
        nonsharedTree = MapTreeService.Load(nonsharedMap);
        nonsharedPlans = FindFocusedPlans(nonsharedTree.Roots);
        mainPlan = nonsharedPlans.Single(plan => SamePath(plan.Locator!.AssetID!, fixture.PlanPath));
        mainPlanLocator = RequiredLocator(mainPlan);
        mainTerrain = FindNode(mainPlan.Children ?? [], candidate => candidate.Locator is
            { NodeType: "Terrain" } locator && IsDirectPlanChild(locator, mainPlanLocator),
            "reopened singleton Plan Terrain");
        AssociatedRasterStyleSnapshot singletonReadback = AssociatedRasterStyleService.Load(StyleRequest(
            nonsharedMap, RequiredLocator(mainTerrain), SourcePath(mainTerrain),
            planNodes: [mainPlanLocator]));
        Check(singletonReadback.Draft.Name == "R20 Singleton Plan Style" &&
              singletonReadback.PlanNodes is { Length: 1 } &&
              SamePath(singletonReadback.PlanNodes[0].AssetID!, fixture.PlanPath),
            "A focused Plan child persists with singleton ownership while a different Plan remains focused.");
        CatalogTreeNodeLocator[] wrongOwners = [RequiredLocator(mainPlan),
            RequiredLocator(nonsharedPlans.Single(plan =>
                SamePath(plan.Locator!.AssetID!, fixture.AlternatePlanPath)))];
        Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Load(StyleRequest(
            nonsharedMap, RequiredLocator(mainTerrain), SourcePath(mainTerrain), planNodes: wrongOwners)));
    }

    private static bool IsDirectPlanChild(CatalogTreeNodeLocator locator,
        CatalogTreeNodeLocator plan)
    {
        return locator.ParentPlanAssetID is { } parentAsset &&
               SamePath(parentAsset, plan.AssetID!) &&
               locator.ParentPlanNodeName == plan.NodeName &&
               locator.ParentPlanNodePath is { } parentPath &&
               plan.NodePath is { } planPath && parentPath.SequenceEqual(planPath) &&
               locator.ParentResultNodeType is null &&
               locator.ParentResultAssetID is null &&
               locator.ParentResultNodePath is null &&
               locator.ParentResultNodeName is null &&
               locator.ParentResultRevision is null;
    }

    private static void ExerciseNilPlanAssociation(CpuFixture fixture)
    {
        using var temporary = new TemporaryDirectory();
        string root = Path.Combine(temporary.FullName, "nil-plan-association");
        CopyDirectory(fixture.Root, root);
        string projectPath = FixturePath(root, fixture.Manifest.ProjectRelativePath);
        string planPath = FixturePath(root, fixture.Manifest.PlanRelativePath);
        string planWithoutGeometryPath = FixturePath(root, fixture.Manifest.AlternatePlanRelativePath);
        Project project = new(projectPath);
        try
        {
            Plan planWithoutGeometry = project.Plans.Single(plan =>
                plan.Name == fixture.AlternatePlanName);
            XElement metadata = XElement.Load(projectPath, LoadOptions.PreserveWhitespace);
            XElement association = metadata.Element("PlanAssociations")?.Elements("PlanAssociation")
                .Single(row => (string?)row.Attribute("Plan") == planWithoutGeometry.Name)
                ?? throw new InvalidDataException("The private fixture has no exact Plan association to clear.");
            association.SetAttributeValue("Geometry", "");
            project.ApplyEditorMetadata(metadata);
            Check(project.GetPlanAssociation(planWithoutGeometry).Geometry is null,
                "The retained metadata parser clears the exact private Plan Geometry association.");
            project.Save();
        }
        finally
        {
            foreach (Result result in project.Results) result.Dispose();
            foreach (CoreLayerBase sourceLayer in project.Plans.Cast<CoreLayerBase>()
                         .Concat(project.Geometries).Concat(project.Terrains)
                         .Concat(project.BoundaryConditions).Concat(project.NValues)
                         .Concat(project.ClassificationLayers))
                sourceLayer.Dispose();
        }
        byte[] projectBeforeRead = File.ReadAllBytes(projectPath);
        string projectXml = File.ReadAllText(projectPath);
        string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            projectPath, projectXml, projectXmlSHA,
            File.Exists(visualizationPath) ? Hash(visualizationPath) : null,
            "Plan", Name: "R20 Nil Shared Association", InitialPlanPath: planPath,
            InitialPlanRevision: Hash(planPath)));
        MapTreeRequest map = MapRequest(projectPath, projectXml, projectXmlSHA,
            "r20-associated-style-nil-plan", created);
        map = FocusPlan(map, planWithoutGeometryPath);
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode[] plans = FindFocusedPlans(tree.Roots);
        Check(plans.Length == 2 && plans.Any(plan => SamePath(plan.Locator!.AssetID!, planPath)) &&
              plans.Any(plan => SamePath(plan.Locator!.AssetID!, planWithoutGeometryPath)) &&
              (plans.Single(plan => SamePath(plan.Locator!.AssetID!, planWithoutGeometryPath))
                  .Children ?? []).All(child => child.Locator?.NodeType != "Geometry"),
            "The temporary source Project has two focused Plans and the second has a retained null Geometry relation.");
        CatalogTreeNode terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { RootName: "Matching Layers", NodeType: "Terrain", AssociationKind: "Terrain" },
            "Terrain still matched from a non-null Plan despite a nil source association");
        CatalogTreeNodeLocator[] planLocators = plans.Select(RequiredLocator).ToArray();
        AssociatedRasterStyleRequest request = StyleRequest(map, RequiredLocator(terrain),
            SourcePath(terrain), planNodes: planLocators);
        AssociatedRasterStyleSnapshot initial = AssociatedRasterStyleService.Load(request);
        Check(initial.PlanNodes is { Length: 2 } && initial.Dependencies.Count(dependency =>
                  dependency.Role == "plan-hdf") == 2,
            "A shared style keeps every focused Plan dependency while ignoring one nil source relation.");
        AssociatedRasterStyleService.Apply(ApplyRequest(request,
            MakeDraft(initial.Draft, "Manual", "R20 Nil Relation Shared Style", ["#FF101010", "#FFF0E0D0"]),
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: "R20 Nil Relation Shared Style")));
        map = RefreshMapRevision(map);
        tree = MapTreeService.Load(map);
        plans = FindFocusedPlans(tree.Roots);
        terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { RootName: "Matching Layers", NodeType: "Terrain", AssociationKind: "Terrain" },
            "reopened Terrain matching row with one nil relation");
        AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(StyleRequest(map,
            RequiredLocator(terrain), SourcePath(terrain), planNodes: plans.Select(RequiredLocator).ToArray()));
        Check(reopened.Draft.Name == "R20 Nil Relation Shared Style" &&
              File.ReadAllBytes(projectPath).SequenceEqual(projectBeforeRead),
            "Style Apply/reopen preserves the nil Plan association and never saves the Project file.");

        MapTreeMutationResult shown = MapTreeService.Perform(new MapTreeActionRequest(map,
            "visibility", Node: RequiredLocator(terrain), Checked: true));
        map = map with { ExpectedVisualizationRevision = shown.VisualizationRevision };
        tree = MapTreeService.Load(map);
        plans = FindFocusedPlans(tree.Roots);
        terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { RootName: "Matching Layers", NodeType: "Terrain", AssociationKind: "Terrain" },
            "visible Terrain matching row with one nil relation");
        AssociatedMapLayersSnapshot rendered = AssociatedMapLayersService.Load(new(
            map, [], [RequiredLocator(terrain)], Viewport, PixelWidth, PixelHeight,
            PlanNodes: plans.Select(RequiredLocator).ToArray()));
        AssociatedMapLayerSnapshot layer = rendered.Layers.Single();
        Check(layer.Status == "available" && layer.Rgba.Length == PixelWidth * PixelHeight * 4 &&
              layer.PlanNodes is { Length: 2 } &&
              layer.Dependencies.Count(dependency => dependency.Role == "plan-hdf") == 2,
            "The retained Plan renderer ignores a nil association while rendering the real shared Terrain and retaining both Plan dependencies.");
    }

    private static void ExerciseResultOwner(CpuFixture fixture)
    {
        MapTreeRequest map = RefreshMapRevision(fixture.ResultMap);
        (CatalogTreeNode group, MapResultGeometryOwner owner, CatalogTreeNode terrain) =
            ResolveResultTerrain(map, fixture);
        CatalogTreeNodeLocator terrainLocator = RequiredLocator(terrain);
        string sourcePath = SourcePath(terrain);
        Check(terrainLocator.ParentResultNodeType == "MultiResult" &&
              terrainLocator.ParentResultNodeName == fixture.PlanName &&
              terrainLocator.ParentResultNodePath is { Length: >= 2 } parentPath &&
              group.Locator?.NodePath is { } groupPath && parentPath.SequenceEqual(groupPath) &&
              SamePath(terrainLocator.ParentResultAssetID!, owner.SelectedResultPath) &&
              terrainLocator.ParentResultRevision!.Equals(owner.SelectedResultRevision, StringComparison.OrdinalIgnoreCase) &&
              SamePath(owner.SelectedResultPath, fixture.SelectedResult.ResultPath),
            "The stored Result child inherits the exact MultiResult row path, selected Result HDF and SHA, not a project Geometry name match.");

        AssociatedRasterStyleRequest request = StyleRequest(map, terrainLocator, sourcePath,
            resultOwner: owner);
        AssociatedRasterStyleSnapshot initial = AssociatedRasterStyleService.Load(request);
        Check(initial.ResultOwner is { SelectionIndex: 0 } echoed &&
              SameLocator(echoed.ResultNode, owner.ResultNode) &&
              SamePath(echoed.SelectedResultPath, owner.SelectedResultPath) &&
              echoed.SelectedResultRevision.Equals(owner.SelectedResultRevision, StringComparison.OrdinalIgnoreCase) &&
              initial.Dependencies.Any(dependency => dependency.Role == "result-hdf" &&
                  SamePath(dependency.Path, owner.SelectedResultPath) &&
                  dependency.Revision.Equals(owner.SelectedResultRevision, StringComparison.OrdinalIgnoreCase)),
            "The Result-owned Terrain style snapshot echoes the current slot-zero source and includes that exact Result HDF dependency.");
        AssociatedRasterStyleService.Apply(ApplyRequest(request,
            MakeDraft(initial.Draft, "Manual", "R20 Result Owner Style", ["#FF241452", "#FFF1C40F"]),
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: "R20 Result Owner Style")));
        map = RefreshMapRevision(map);
        (group, owner, terrain) = ResolveResultTerrain(map, fixture);
        AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(StyleRequest(map,
            RequiredLocator(terrain), SourcePath(terrain), resultOwner: owner));
        Check(reopened.Draft.ValueSource == "Manual" && reopened.Draft.Name == "R20 Result Owner Style" &&
              reopened.ResultOwner is { } resultOwner && SameLocator(resultOwner.ResultNode, RequiredLocator(group)) &&
              SamePath(resultOwner.SelectedResultPath, fixture.SelectedResult.ResultPath),
            "The Result child style round-trips after refreshing the chart context token and retains its exact selected HDF owner.");

        MapResultGeometryOwner wrongOwner = owner with
        {
            SelectedResultRevision = new string('0', 64)
        };
        Expect<SourceFileChangedException>(() => AssociatedRasterStyleService.Load(StyleRequest(map,
            RequiredLocator(terrain), SourcePath(terrain), resultOwner: wrongOwner)));
    }

    private static void ExercisePreviousResultOwner(CpuFixture fixture)
    {
        MapTreeRequest map = RefreshMapRevision(fixture.ResultMap) with
        {
            ResultSelectionOverrides = null
        };
        MapTreeSnapshot initialTree = MapTreeService.Load(map);
        CatalogTreeNode initialGroup = FindNode(initialTree.Roots, candidate =>
            candidate.Locator is { RootName: "Layers", NodeType: "MultiResult" } locator &&
            locator.NodeName == fixture.PlanName,
            "the serialized MultiResult row before selecting its previous Result");
        CatalogTreeNodeLocator initialGroupLocator = RequiredLocator(initialGroup);
        InjectUnknownVisualizationData(map, initialGroupLocator);
        map = RefreshMapRevision(map) with { ResultSelectionOverrides = null };

        PreviousResultOwnerContext context = ResolvePreviousResultTerrain(map, fixture);
        CatalogTreeNodeLocator geometryLocator = RequiredLocator(context.Geometry);
        CatalogTreeNodeLocator terrainLocator = RequiredLocator(context.Terrain);
        Check(map.ResultSelectionOverrides is null && geometryLocator.NodePath is null &&
              terrainLocator.NodePath is null,
            "The Previous Result is resolved through its owner override while the map-level override is absent and its Geometry/Terrain children remain implicit.");
        Check(HasExactResultParent(context.Group, geometryLocator, context.Owner) &&
              HasExactResultParent(context.Group, terrainLocator, context.Owner) &&
              geometryLocator.AssetID is { } geometrySourcePath &&
              SamePath(geometrySourcePath, context.Owner.SelectedResultPath) &&
              terrainLocator.ParentGeometryNodeName == geometryLocator.NodeName &&
              terrainLocator.ParentGeometryAssetID is { } geometryAsset &&
              SamePath(geometryAsset, context.Owner.SelectedResultPath),
            "The implicit Geometry and Terrain rows belong to the exact selected Previous Result and its embedded Geometry.");

        string sourcePath = SourcePath(context.Terrain);
        AssociatedRasterStyleRequest request = StyleRequest(map, terrainLocator, sourcePath,
            resultOwner: context.Owner);
        AssociatedRasterStyleSnapshot initial = AssociatedRasterStyleService.Load(request);
        Check(initial.ResultOwner is { SelectionIndex: 0, SelectionOverrides: { Length: 1 } } echoed &&
              SameLocator(echoed.ResultNode, context.Owner.ResultNode) &&
              echoed.SelectionOverrides[0].Mode == "Previous" &&
              SameLocator(echoed.SelectionOverrides[0].Node, context.Owner.ResultNode) &&
              SamePath(echoed.SelectedResultPath, fixture.SelectedResult.ResultPath) &&
              echoed.SelectedResultRevision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase) &&
              initial.Dependencies.Any(dependency => dependency.Role == "result-hdf" &&
                  SamePath(dependency.Path, fixture.SelectedResult.ResultPath) &&
                  dependency.Revision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase)),
            "The style snapshot carries Previous only in the exact Result owner and depends on the selected signed-flow HDF.");

        AssociatedRasterStyleService.Apply(ApplyRequest(request,
            MakeDraft(initial.Draft, "Manual", "R20 Previous Result Owner Style", ["#FF172A43", "#FFF3C969"]),
            new AssociatedRasterStylePaletteMutation("saveCustom", Name: "R20 Previous Result Owner Style")));

        map = RefreshMapRevision(map) with { ResultSelectionOverrides = null };
        context = ResolvePreviousResultTerrain(map, fixture);
        CatalogTreeNodeLocator reopenedGeometry = RequiredLocator(context.Geometry);
        CatalogTreeNodeLocator reopenedTerrain = RequiredLocator(context.Terrain);
        Check(reopenedGeometry.NodePath is { Length: > 0 } geometryPath &&
              reopenedTerrain.NodePath is { Length: > 0 } terrainPath &&
              IsDescendantNodePath(geometryPath, context.Group.Locator?.NodePath) &&
              IsDescendantNodePath(terrainPath, geometryPath) &&
              HasExactResultParent(context.Group, reopenedGeometry, context.Owner) &&
              HasExactResultParent(context.Group, reopenedTerrain, context.Owner) &&
              reopenedGeometry.AssetID is { } reopenedGeometryAsset &&
              SamePath(reopenedGeometryAsset, context.Owner.SelectedResultPath) &&
              reopenedGeometry.NodeName == geometryLocator.NodeName &&
              reopenedTerrain.NodeName == terrainLocator.NodeName &&
              reopenedTerrain.ParentGeometryNodeName == reopenedGeometry.NodeName &&
              reopenedTerrain.ParentGeometryAssetID is { } reopenedParentGeometry &&
              SamePath(reopenedParentGeometry, context.Owner.SelectedResultPath) &&
              reopenedTerrain.ParentGeometryNodePath is { } terrainGeometryPath &&
              terrainGeometryPath.SequenceEqual(geometryPath),
            "Applying a style materializes the same implicit Result Geometry/Terrain path under the exact Previous owner.");
        AssociatedRasterStyleSnapshot reopened = AssociatedRasterStyleService.Load(StyleRequest(map,
            reopenedTerrain, SourcePath(context.Terrain), resultOwner: context.Owner));
        Check(reopened.Draft.ValueSource == "Manual" && reopened.Draft.Name == "R20 Previous Result Owner Style" &&
              reopened.ResultOwner is { SelectionOverrides: { Length: 1 } } reopenedOwner &&
              reopenedOwner.SelectionOverrides[0].Mode == "Previous" &&
              SamePath(reopenedOwner.SelectedResultPath, fixture.SelectedResult.ResultPath) &&
              reopenedOwner.SelectedResultRevision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase),
            "Reopening after Apply retains the Previous selection, exact selected HDF, and edited style.");

        MapTreeRequest selectedMap = context.SelectedTreeMap;
        selectedMap = SetResultNodeVisible(selectedMap,
            candidate => candidate.Locator is { NodeType: "MultiResult" } locator &&
                         SameLocator(locator, context.Owner.ResultNode),
            "selected MultiResult row");
        selectedMap = SetResultNodeVisible(selectedMap,
            candidate => candidate.Locator is { NodeType: "Geometry", ParentResultNodeType: "MultiResult" } locator &&
                         HasExactResultParent(context.Group, locator, context.Owner) &&
                         locator.NodeName == reopenedGeometry.NodeName,
            "selected Result Geometry row");
        selectedMap = SetResultNodeVisible(selectedMap,
            candidate => candidate.Locator is { NodeType: "Terrain", ParentResultNodeType: "MultiResult" } locator &&
                         HasExactResultParent(context.Group, locator, context.Owner) &&
                         locator.NodeName == reopenedTerrain.NodeName,
            "selected Result Terrain row");

        map = RefreshMapRevision(map) with { ResultSelectionOverrides = null };
        context = ResolvePreviousResultTerrain(map, fixture);
        AssociatedMapLayersSnapshot rendered = AssociatedMapLayersService.Load(
            new AssociatedMapLayersRequest(map, [RequiredLocator(context.Geometry)],
                [RequiredLocator(context.Terrain)], Viewport, PixelWidth, PixelHeight,
                ResultOwners: [context.Owner]));
        AssociatedMapLayerSnapshot layer = rendered.Layers.Single();
        Check(map.ResultSelectionOverrides is null && layer.Status == "available" &&
              layer.IsChecked && layer.EffectiveVisible &&
              layer.Rgba.Length == PixelWidth * PixelHeight * 4 &&
              layer.ResultOwners is { Length: 1 } resultOwners &&
              resultOwners[0].SelectionOverrides is { Length: 1 } selections &&
              selections[0].Mode == "Previous" &&
              SamePath(resultOwners[0].SelectedResultPath, fixture.SelectedResult.ResultPath) &&
              resultOwners[0].SelectedResultRevision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase),
            "The associated-raster renderer resolves visible pixels from the Previous Result owner without a map-level selection override.");
        AssertUnknownVisualizationData(map, RequiredLocator(context.Group));
    }

    private static PreviousResultOwnerContext ResolvePreviousResultTerrain(
        MapTreeRequest requestedMap, CpuFixture fixture)
    {
        MapTreeRequest map = RefreshMapRevision(requestedMap) with { ResultSelectionOverrides = null };
        MapTreeSnapshot unselectedTree = MapTreeService.Load(map);
        CatalogTreeNode unselectedGroup = FindNode(unselectedTree.Roots, candidate =>
            candidate.Locator is { RootName: "Layers", NodeType: "MultiResult" } locator &&
            locator.NodeName == fixture.PlanName,
            "MultiResult row for Latest/Previous selection");
        CatalogTreeNodeLocator groupLocator = RequiredLocator(unselectedGroup);

        MapResultSourcesResult latestSources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode latestNode = latestSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SameLocator(node.Node, groupLocator));
        MapResultSelectionState latestState = latestNode.Selections.Single(selection => selection.SelectionIndex == 0);
        MapResultSourceChoice latest = latestState.SelectedResult ??
            throw new InvalidDataException("The Result map has no Latest source choice.");
        Check(latestState.SelectionMode == "Latest",
            "The map without a selection override resolves its source default as Latest.");

        MapResultSelectionOverride previousOverride = new(groupLocator, 0, "Previous");
        MapResultSourcesResult previousSources = MapResultChartService.Selection(new(map,
            latestSources.ContextToken, null, [previousOverride]));
        MapResultActiveNode previousNode = previousSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SameLocator(node.Node, groupLocator));
        MapResultSelectionState previousState = previousNode.Selections.Single(selection => selection.SelectionIndex == 0);
        MapResultSourceChoice previous = previousState.SelectedResult ??
            throw new InvalidDataException("The Result map has no Previous source choice.");
        Check(previousState.SelectionMode == "Previous" &&
              !SamePath(latest.ResultPath, previous.ResultPath) &&
              SamePath(previous.ResultPath, fixture.SelectedResult.ResultPath) &&
              previous.Revision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase),
            "Previous is an actual non-Latest choice and resolves to the fixture's signed-flow Result HDF.");

        MapTreeRequest selectedTreeMap = map with
        {
            ResultSelectionOverrides = [new MapTreeResultSelectionOverride(fixture.PlanPath,
                fixture.PlanName, previous.ResultPath, previous.Revision)]
        };
        MapTreeSnapshot selectedTree = MapTreeService.Load(selectedTreeMap);
        CatalogTreeNode selectedGroup = FindNode(selectedTree.Roots, candidate =>
            candidate.Locator is { RootName: "Layers", NodeType: "MultiResult" } locator &&
            locator.NodeName == fixture.PlanName,
            "the exact MultiResult row in the Previous selection tree");
        CatalogTreeNodeLocator selectedGroupLocator = RequiredLocator(selectedGroup);
        if (!SameLocator(groupLocator, selectedGroupLocator))
            throw new SourceFileChangedException();

        CatalogTreeNode geometry = FindNode(selectedTree.Roots, candidate =>
            candidate.Locator is { NodeType: "Geometry", ParentResultNodeType: "MultiResult" } locator &&
            HasExactResultParent(selectedGroup, locator, previous.ResultPath, previous.Revision),
            "the implicit Geometry child of the Previous Result HDF");
        CatalogTreeNode terrain = FindNode(selectedTree.Roots, candidate =>
            candidate.Locator is { NodeType: "Terrain", ParentResultNodeType: "MultiResult" } locator &&
            HasExactResultParent(selectedGroup, locator, previous.ResultPath, previous.Revision),
            "the implicit Terrain child of the Previous Result HDF");
        MapResultGeometryOwner owner = new(selectedGroupLocator, previousSources.ContextToken,
            [previousOverride], 0, previous.ResultPath, previous.Revision);
        return new(map, selectedTreeMap, previousSources, selectedGroup, geometry, terrain, owner);
    }

    private static bool HasExactResultParent(CatalogTreeNode group,
        CatalogTreeNodeLocator child, MapResultGeometryOwner owner) =>
        HasExactResultParent(group, child, owner.SelectedResultPath, owner.SelectedResultRevision);

    private static bool HasExactResultParent(CatalogTreeNode group,
        CatalogTreeNodeLocator child, string resultPath, string resultRevision) =>
        child.ParentResultNodeType == "MultiResult" &&
        child.ParentResultNodeName == group.Name &&
        child.ParentResultNodePath is { } parentPath && group.Locator?.NodePath is { } groupPath &&
        parentPath.SequenceEqual(groupPath) &&
        child.ParentResultAssetID is { } parentAsset && SamePath(parentAsset, resultPath) &&
        child.ParentResultRevision is { } revision &&
        revision.Equals(resultRevision, StringComparison.OrdinalIgnoreCase);

    private static MapTreeRequest SetResultNodeVisible(MapTreeRequest selectedMap,
        Func<CatalogTreeNode, bool> predicate, string description)
    {
        selectedMap = RefreshMapRevision(selectedMap);
        MapTreeSnapshot tree = MapTreeService.Load(selectedMap);
        CatalogTreeNode node = FindNode(tree.Roots, predicate, description);
        if (node.Checked == "checked") return selectedMap;
        MapTreeMutationResult changed = MapTreeService.Perform(new MapTreeActionRequest(selectedMap,
            "visibility", Node: RequiredLocator(node), Checked: true));
        return selectedMap with { ExpectedVisualizationRevision = changed.VisualizationRevision };
    }

    private static bool IsDescendantNodePath(int[]? childPath, int[]? parentPath) =>
        childPath is { Length: > 0 } && parentPath is { Length: > 0 } &&
        childPath.Length > parentPath.Length && childPath.Take(parentPath.Length).SequenceEqual(parentPath);

    private static (CatalogTreeNode Group, MapResultGeometryOwner Owner, CatalogTreeNode Terrain)
        ResolveResultTerrain(MapTreeRequest map, CpuFixture fixture)
    {
        MapTreeSnapshot tree = MapTreeService.Load(map);
        CatalogTreeNode group = FindNode(tree.Roots, candidate =>
            candidate.Locator is { RootName: "Layers", NodeType: "MultiResult" } locator &&
            locator.NodeName == fixture.PlanName,
            "selected MultiResult group");
        CatalogTreeNodeLocator resultLocator = RequiredLocator(group);
        MapResultSourcesResult sources = MapResultChartService.Sources(new(map, []));
        MapResultActiveNode active = sources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SameLocator(node.Node, resultLocator));
        MapResultSourceChoice selected = active.Selections.Single(selection => selection.SelectionIndex == 0)
            .SelectedResult ?? throw new InvalidDataException("The selected MultiResult has no current keyframe.");
        if (!SamePath(selected.ResultPath, fixture.SelectedResult.ResultPath) ||
            !selected.Revision.Equals(fixture.SelectedResult.Revision, StringComparison.OrdinalIgnoreCase))
            throw new SourceFileChangedException();
        CatalogTreeNode terrain = FindNode(tree.Roots, candidate => candidate.Locator is
            { NodeType: "Terrain", ParentResultNodeType: "MultiResult" } locator &&
            locator.ParentResultNodeName == fixture.PlanName &&
            locator.ParentResultNodePath is { } parentPath && group.Locator?.NodePath is { } groupPath &&
            parentPath.SequenceEqual(groupPath) &&
            locator.ParentResultAssetID is { } parentAsset && SamePath(parentAsset, selected.ResultPath) &&
            locator.ParentResultRevision is { } revision &&
            revision.Equals(selected.Revision, StringComparison.OrdinalIgnoreCase),
            "Terrain child under the currently selected Result HDF");
        var owner = new MapResultGeometryOwner(resultLocator, sources.ContextToken,
            null, 0, selected.ResultPath, selected.Revision);
        return (group, owner, terrain);
    }

    private static AssociatedMapLayerSnapshot Render(MapTreeRequest map,
        CatalogTreeNodeLocator[] geometries, CatalogTreeNodeLocator association)
    {
        map = RefreshMapRevision(map);
        AssociatedMapLayersSnapshot rendered = AssociatedMapLayersService.Load(
            new AssociatedMapLayersRequest(map, geometries, [association], Viewport,
                PixelWidth, PixelHeight));
        return rendered.Layers.Single(layer => layer.Kind == association.NodeType);
    }

    private static AssociatedRasterStyleRequest StyleRequest(MapTreeRequest map,
        CatalogTreeNodeLocator node, string sourcePath,
        CatalogTreeNodeLocator[]? geometryNodes = null,
        CatalogTreeNodeLocator[]? planNodes = null,
        MapResultGeometryOwner? resultOwner = null)
    {
        AssociatedRasterStyleRequest request = new(RefreshMapRevision(map), node, sourcePath,
            Hash(sourcePath), GeometryNodes: geometryNodes, PlanNodes: planNodes,
            ResultOwner: resultOwner);
        AssociatedRasterStyleSnapshot captured = AssociatedRasterStyleService.Load(request);
        return request with { ContextToken = captured.ContextToken };
    }

    private static AssociatedRasterStyleApplyRequest ApplyRequest(
        AssociatedRasterStyleRequest request, AssociatedRasterStyleDraft draft,
        AssociatedRasterStylePaletteMutation? mutation = null) => new(
            RefreshMapRevision(request.Map), request.Node, request.SourcePath,
            request.SourceRevision, request.ContextToken ?? throw new InvalidOperationException(
                "A captured style request needs the current source context token."), draft,
            mutation, request.GeometryNodes, request.PlanNodes, request.ResultOwner);

    private static AssociatedRasterStyleDraft MakeDraft(AssociatedRasterStyleDraft current,
        string valueSource, string name, string[] colors)
    {
        if (colors.Length < 2) throw new ArgumentException("At least two actual color stops are required.");
        double start = current.Stops[0].Value;
        double end = current.Stops[^1].Value;
        if (!double.IsFinite(start) || !double.IsFinite(end) || end <= start)
        {
            start = 0;
            end = 1;
        }
        var stops = colors.Select((color, index) => new AssociatedRasterStyleColorStop(
            index, color, start + (end - start) * index / (colors.Length - 1))).ToArray();
        return current with
        {
            PaletteID = null,
            Name = name,
            Stops = stops,
            ValueSource = valueSource,
            IsEditing = true,
            IsSurfaceFillEnabled = true,
            Alpha = byte.MaxValue,
            HillshadeEnabled = false,
            ContoursEnabled = false
        };
    }

    private static bool EquivalentStyle(AssociatedRasterStyleDraft left,
        AssociatedRasterStyleDraft right) =>
        left.ValueSource == right.ValueSource && left.Name == right.Name &&
        left.IsSurfaceFillEnabled == right.IsSurfaceFillEnabled && left.Alpha == right.Alpha &&
        left.InterpolationMode == right.InterpolationMode && left.SmoothingRadius == right.SmoothingRadius &&
        left.ResampleCellSizeRatio == right.ResampleCellSizeRatio &&
        left.HillshadeEnabled == right.HillshadeEnabled && left.HillshadeZFactor == right.HillshadeZFactor &&
        left.HillshadeAzimuth == right.HillshadeAzimuth && left.HillshadeZenith == right.HillshadeZenith &&
        left.ContoursEnabled == right.ContoursEnabled && left.ContoursAuto == right.ContoursAuto &&
        left.ContourInterval == right.ContourInterval && left.ContourIndexEvery == right.ContourIndexEvery &&
        left.ContourColorArgb == right.ContourColorArgb && left.ContourOpacity == right.ContourOpacity &&
        left.ContourShowLabels == right.ContourShowLabels && left.ContourDensity == right.ContourDensity &&
        left.Stops.Select(stop => (stop.Index, stop.Color, stop.Value)).SequenceEqual(
            right.Stops.Select(stop => (stop.Index, stop.Color, stop.Value)));

    private static bool NearlyEqual(double left, double right) => Math.Abs(left - right) <= 1e-10 *
        Math.Max(1, Math.Max(Math.Abs(left), Math.Abs(right)));

    private static MapTreeRequest MapRequest(string projectPath, string projectXml,
        string projectXmlSHA, string mapID, MapDocumentMutationReceipt receipt) => new(
            projectPath, projectXml, projectXmlSHA, mapID, receipt.MapIndex,
            receipt.MapName, receipt.MapType, receipt.VisualizationRevision);

    private static MapTreeRequest RefreshMapRevision(MapTreeRequest map) => map with
    {
        ExpectedVisualizationRevision = Hash(Path.ChangeExtension(map.ProjectPath, ".vis"))
    };

    private static MapTreeRequest FocusPlan(MapTreeRequest map, string planPath)
    {
        MapTreeMutationResult focused = MapTreeService.Perform(new MapTreeActionRequest(
            RefreshMapRevision(map), "focusPlan", SourcePath: planPath, SourceRevision: Hash(planPath)));
        return map with { ExpectedVisualizationRevision = focused.VisualizationRevision };
    }

    private static CatalogTreeNode[] FindFocusedPlans(CatalogTreeNode[] roots)
    {
        CatalogTreeNode root = roots.SingleOrDefault(node => node.Name == "Focused Plans") ??
            throw new InvalidDataException("The saved Plan map has no Focused Plans root.");
        return (root.Children ?? []).Where(node => node.Locator is
            { RootName: "Focused Plans", NodeType: "Plan" }).ToArray();
    }

    private static CatalogTreeNodeLocator FindAssociation(CatalogTreeNode[] roots,
        string kind, string nodeName, string sourcePath) =>
        FindAssociationLocator(roots, kind, nodeName, sourcePath);

    private static CatalogTreeNodeLocator FindAssociationLocator(CatalogTreeNode[] roots,
        string kind, string nodeName, string sourcePath)
    {
        CatalogTreeNode node = FindNode(roots, candidate => candidate.Locator is
            { RootName: "Matching Layers" } locator && locator.NodeType == kind &&
            locator.AssociationKind == kind && locator.NodeName == nodeName &&
            (locator.AssociationAssetID ?? locator.AssetID) is { } asset && SamePath(asset, sourcePath),
            "exact Matching Layers " + kind + " association " + nodeName);
        return RequiredLocator(node);
    }

    private static CatalogTreeNode FindNode(IEnumerable<CatalogTreeNode> roots,
        Func<CatalogTreeNode, bool> predicate, string description)
    {
        CatalogTreeNode[] matches = Walk(roots).Where(predicate).ToArray();
        return matches.Length == 1 ? matches[0] : throw new InvalidDataException(
            $"Expected one {description}; found {matches.Length}.");
    }

    private static IEnumerable<CatalogTreeNode> Walk(IEnumerable<CatalogTreeNode> roots)
    {
        foreach (CatalogTreeNode node in roots)
        {
            yield return node;
            if (node.Children is { } children)
                foreach (CatalogTreeNode child in Walk(children)) yield return child;
        }
    }

    private static CatalogTreeNodeLocator RequiredLocator(CatalogTreeNode node) =>
        node.Locator ?? throw new InvalidDataException("The exact saved source map row has no locator.");

    private static string SourcePath(CatalogTreeNode node) => SourcePath(RequiredLocator(node));

    private static string SourcePath(CatalogTreeNodeLocator locator)
    {
        string path = locator.AssociationAssetID ?? locator.AssetID ??
            throw new InvalidDataException($"The exact {locator.NodeType} source row has no HDF path.");
        if (!Path.IsPathFullyQualified(path) || !File.Exists(path))
            throw new FileNotFoundException("The exact source-map HDF path is not readable.", path);
        return Path.GetFullPath(path);
    }

    private static void InjectUnknownVisualizationData(MapTreeRequest map,
        CatalogTreeNodeLocator targetLocator)
    {
        string visualizationPath = Path.ChangeExtension(map.ProjectPath, ".vis");
        XDocument document = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement root = document.Root ?? throw new InvalidDataException("The source visualization root is missing.");
        XElement savedMap = SavedMap(document, map.MapIndex);
        root.SetAttributeValue("R20UnknownRootAttribute", "preserve-root");
        root.Add(new XElement("R20UnknownRootSection", new XAttribute("token", "root")));
        savedMap.SetAttributeValue("R20UnknownMapAttribute", "preserve-map");
        savedMap.Add(new XElement("R20UnknownMapSection", new XAttribute("token", "map")));
        ResolveSavedTreeNode(savedMap, targetLocator.NodePath ??
            throw new InvalidDataException("The source style row must have a concrete serialized .vis path."))
            .Add(new XElement("R20UnknownRasterExtension", new XAttribute("token", "node")));
        document.Save(visualizationPath, SaveOptions.DisableFormatting);
    }

    private static void AssertUnknownVisualizationData(MapTreeRequest map,
        CatalogTreeNodeLocator targetLocator)
    {
        XDocument document = XDocument.Load(Path.ChangeExtension(map.ProjectPath, ".vis"),
            LoadOptions.PreserveWhitespace);
        XElement root = document.Root!;
        XElement savedMap = SavedMap(document, map.MapIndex);
        XElement savedNode = ResolveSavedTreeNode(savedMap, targetLocator.NodePath!);
        Check((string?)root.Attribute("R20UnknownRootAttribute") == "preserve-root" &&
              root.Elements("R20UnknownRootSection").Single().Attribute("token")?.Value == "root" &&
              (string?)savedMap.Attribute("R20UnknownMapAttribute") == "preserve-map" &&
              savedMap.Elements("R20UnknownMapSection").Single().Attribute("token")?.Value == "map" &&
              savedNode.Elements("R20UnknownRasterExtension").Single().Attribute("token")?.Value == "node",
            "Applying and reopening raster symbology preserves unknown XML at document, map and exact source-node scopes.");
    }

    private static XElement SavedMap(XDocument document, int index) =>
        document.Root?.Element("Maps")?.Elements("Map").ElementAtOrDefault(index)
        ?? throw new InvalidDataException("The selected source map was not serialized.");

    private static XElement ResolveSavedTreeNode(XElement map, int[] path)
    {
        XElement[] siblings = map.Element("Tree")?.Element("Nodes")?.Elements("Node").ToArray() ?? [];
        XElement? selected = null;
        foreach (int index in path)
        {
            if (index < 0 || index >= siblings.Length)
                throw new InvalidDataException("The source locator path does not match the saved map tree.");
            selected = siblings[index];
            siblings = selected.Elements("Node").ToArray();
        }
        return selected ?? throw new InvalidDataException("The source locator path is empty.");
    }

    private static void ExportAcceptanceFixture(string sourceRoot,
        AssociatedFixture associated, CpuFixture cpu)
    {
        string? configured = Environment.GetEnvironmentVariable("HECRAS_ASSOCIATED_STYLE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configured)) return;
        string target = Path.GetFullPath(configured);
        string source = Path.GetFullPath(sourceRoot);
        if (Directory.Exists(target) || File.Exists(target) || IsWithin(target, source))
            throw new IOException("The associated raster style acceptance directory must be absent and outside its source fixture.");

        Directory.CreateDirectory(target);
        string associatedDestination = Path.Combine(target, "associated");
        string cpuDestination = Path.Combine(target, "cpu");
        CopyDirectory(associated.Root, associatedDestination);
        CopyDirectory(cpu.Root, cpuDestination);

        string selectedRole = cpu.Manifest.Results.Single(result => result.Role == "signed-flow").Path;
        var manifest = new StyleAcceptanceManifest(
            SchemaVersion: 1,
            AssociatedProjectRelativePath: Relative(target, Path.Combine(associatedDestination,
                Path.GetRelativePath(associated.Root, associated.ProjectPath))),
            AssociatedMapName: associated.Manifest.Map.MapName,
            AssociatedMapType: associated.Manifest.Map.MapType,
            AssociatedTerrainName: associated.Manifest.Associations.Single(item => item.Kind == "Terrain").Name,
            AssociatedNValueName: associated.Manifest.Associations.Single(item => item.Kind == "NValue").Name,
            AssociatedClassificationName: associated.Manifest.Associations.Single(item => item.Kind == "Classification").Name,
            AssociatedGeometryNames: associated.Manifest.Geometries.Select(item => item.NodeName).ToArray(),
            PlanMapName: cpu.PlanMap.MapName,
            PlanName: cpu.PlanName,
            PlanRelativePath: Relative(target, Path.Combine(cpuDestination,
                Path.GetRelativePath(cpu.Root, cpu.PlanPath))),
            CpuProjectRelativePath: Relative(target, Path.Combine(cpuDestination,
                Path.GetRelativePath(cpu.Root, cpu.ProjectPath))),
            CpuPlanRelativePath: Relative(target, Path.Combine(cpuDestination,
                Path.GetRelativePath(cpu.Root, cpu.PlanPath))),
            CpuMapName: cpu.ResultMap.MapName,
            CpuMapType: cpu.ResultMap.MapType,
            CpuPlanName: cpu.PlanName,
            CpuResultRole: "signed-flow",
            CpuResultNodeName: cpu.PlanName,
            CpuResultRelativePath: Relative(target, Path.Combine(cpuDestination,
                Path.GetRelativePath(cpu.Root, FixturePath(cpu.Root, selectedRole)))),
            CpuResultRevision: cpu.SelectedResult.Revision);
        File.WriteAllText(Path.Combine(target, "manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions(JsonSerializerDefaults.Web)
            {
                WriteIndented = true
            }));
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Retained source associated-raster style fixture. Geometry uses the exact shared Terrain/NValue/Classification owners; CPU Result identity comes from the retained solver fixture. All fixture inputs are private copies.");
    }

    private static string RequiredDirectory(string environmentVariable)
    {
        string? value = Environment.GetEnvironmentVariable(environmentVariable);
        if (string.IsNullOrWhiteSpace(value) || !Directory.Exists(value))
            throw new DirectoryNotFoundException("The retained source fixture is unavailable: " + environmentVariable);
        return Path.GetFullPath(value);
    }

    private static string FixturePath(string root, string relativePath)
    {
        string path = Path.GetFullPath(Path.Combine(root, relativePath));
        if (!IsWithin(path, root) || !File.Exists(path))
            throw new FileNotFoundException("The fixture manifest references a missing or out-of-scope source file.", path);
        return path;
    }

    private static void CopyDirectory(string source, string destination)
    {
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException(source);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("A private source fixture destination already exists: " + destination);
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string target = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: false);
        }
    }

    private static Dictionary<string, byte[]> CaptureNonVisualizationFiles(params string[] roots)
    {
        var result = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        for (int index = 0; index < roots.Length; index++)
        {
            string root = roots[index];
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                if (string.Equals(Path.GetExtension(file), ".vis", StringComparison.OrdinalIgnoreCase)) continue;
                string key = index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "/" + Relative(root, file);
                result.Add(key, File.ReadAllBytes(file));
            }
        }
        return result;
    }

    private static bool SameFiles(Dictionary<string, byte[]> expected,
        Dictionary<string, byte[]> actual) => expected.Count == actual.Count &&
        expected.All(pair => actual.TryGetValue(pair.Key, out byte[]? bytes) &&
            pair.Value.AsSpan().SequenceEqual(bytes));

    private static string DirectoryDigest(string root)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
                     .OrderBy(path => Relative(root, path), StringComparer.Ordinal))
        {
            hash.AppendData(Encoding.UTF8.GetBytes(Relative(root, file)));
            hash.AppendData([0]);
            hash.AppendData(SHA256.HashData(File.ReadAllBytes(file)));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');

    private static bool IsWithin(string candidate, string parent)
    {
        string fullCandidate = Path.GetFullPath(candidate);
        string fullParent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return fullCandidate.StartsWith(fullParent, comparison);
    }

    private static bool SamePath(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static bool SameLocator(CatalogTreeNodeLocator left, CatalogTreeNodeLocator right) =>
        left == right || left.RootName == right.RootName && left.NodeType == right.NodeType &&
        left.NodeName == right.NodeName && left.NodePath is not null && right.NodePath is not null &&
        left.NodePath.SequenceEqual(right.NodePath) && left.AssetID == right.AssetID;

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static StringComparer PathComparer => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private sealed record AssociatedMapManifest(string Project, AssociatedMapIdentity Map,
        AssociatedGeometryEntry[] Geometries, AssociatedAssociationEntry[] Associations);
    private sealed record AssociatedMapIdentity(int MapIndex, string MapName, string MapType);
    private sealed record AssociatedGeometryEntry(string NodeName, string Path);
    private sealed record AssociatedAssociationEntry(string Kind, string Name, string Path);
    private sealed record CpuAcceptanceManifest(string ProjectRelativePath, string PlanRelativePath,
        string SharedPlanRelativePath, string AlternatePlanRelativePath, string GeometryRelativePath,
        string AlternateGeometryRelativePath, string BoundaryConditionRelativePath,
        string TerrainRasterRelativePath, string PlanName, string SharedPlanName,
        string AlternatePlanName, string GeometryName, string AlternateGeometryName,
        string BoundaryConditionName, string[] BarrelNames, CpuResultManifest[] Results);
    private sealed record CpuResultManifest(string Role, string Path, string Revision,
        int ProfileCount, string[] ProfileNames);
    private sealed record StyleAcceptanceManifest(int SchemaVersion,
        string AssociatedProjectRelativePath, string AssociatedMapName, string AssociatedMapType,
        string AssociatedTerrainName, string AssociatedNValueName, string AssociatedClassificationName,
        string[] AssociatedGeometryNames, string PlanMapName, string PlanName, string PlanRelativePath,
        string CpuProjectRelativePath, string CpuPlanRelativePath, string CpuMapName, string CpuMapType,
        string CpuPlanName, string CpuResultRole, string CpuResultNodeName,
        string CpuResultRelativePath, string CpuResultRevision);
    private sealed record AssociatedFixture(string Root, AssociatedMapManifest Manifest,
        string ProjectPath, string VisualizationPath, MapTreeRequest Map,
        CatalogTreeNodeLocator[] GeometryNodes, CatalogTreeNodeLocator Terrain,
        CatalogTreeNodeLocator NValue);
    private sealed record CpuFixture(string Root, CpuAcceptanceManifest Manifest,
        string ProjectPath, string PlanPath, string PlanName, string SharedPlanPath,
        string SharedPlanName, string AlternatePlanPath, string AlternatePlanName,
        MapTreeRequest PlanMap, MapTreeRequest ResultMap,
        CatalogTreeNodeLocator ResultLocator, MapResultSourceChoice SelectedResult,
        CatalogTreeNodeLocator ResultTerrain, string ResultTerrainPath);
    private sealed record PreviousResultOwnerContext(MapTreeRequest Map,
        MapTreeRequest SelectedTreeMap, MapResultSourcesResult Sources,
        CatalogTreeNode Group, CatalogTreeNode Geometry, CatalogTreeNode Terrain,
        MapResultGeometryOwner Owner);
}
