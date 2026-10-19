using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using H5Assist;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.Terrains;
using Ras.Output;
using Utility.Units;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

/// <summary>
/// Exercises the current-map Result raster route with an independently
/// reopenable Result HDF produced by retained source writers. Output values
/// are deterministic test data, not solver output.
/// </summary>
internal static class MapResultRenderChecks
{
    private static readonly DateTime Start = new(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc);

    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        Fixture fixture = CreateFixture(directory.FullName, velocityVariesByProfile: true);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);

        MapResultSourcesResult sources = MapResultChartService.Sources(new(fixture.Map, []));
        MapResultActiveNode node = sources.ActiveNodes.Single(item => item.NodeKind == "Result");
        RasterMapViewExtent viewport = new(0, 0, 1, 1, 32, 32);
        MapResultRenderResult first = MapResultRenderService.Render(new(fixture.Map, [],
            sources.ContextToken, node.Node, 0, viewport));
        MapResultRenderResult last = MapResultRenderService.Render(new(fixture.Map, [],
            sources.ContextToken, node.Node, 2, viewport));

        string expectedNodeIdentity = SwiftSourceIdentity(node.Node);
        Check(first.SourceID == expectedNodeIdentity && last.SourceID == expectedNodeIdentity &&
              first.Layers.Single().SourceID == expectedNodeIdentity &&
              last.Layers.Single().SourceID == expectedNodeIdentity,
            "Map Result render echoes the full Swift 21-field node identity in both profile responses and raster layers.");
        Check(first.Steps.Length == 3 && first.Steps.Select(step => step.Id).SequenceEqual([0, 1, 2]),
            "The map renderer returns the Result's actual stored profile indices and full timeline.");
        Check(first.Layers.Length == 1 && last.Layers.Length == 1
            && first.Layers[0].SourceMapID == fixture.Map.MapID
            && last.Layers[0].SourceMapID == fixture.Map.MapID
            && first.Layers[0].ResultPath == last.Layers[0].ResultPath
            && first.Layers[0].ProfileIndex == 0 && last.Layers[0].ProfileIndex == 2,
            "Each raster is bound to the exact active map, Result source and requested profile.");
        Check(first.Layers[0].Width == viewport.PixelWidth && first.Layers[0].Height == viewport.PixelHeight
            && first.Layers[0].Rgba.Length == viewport.PixelWidth * viewport.PixelHeight * 4
            && MapSourceTestPaths.SameFile(first.Layers[0].TerrainPath, fixture.TerrainPath)
            && first.Layers[0].TerrainRevision.Length == 64,
            "The response carries viewport-sized RGBA sampled against the current project's resolved terrain.");
        Check(!first.Layers[0].Rgba.SequenceEqual(last.Layers[0].Rgba),
            "The rendered surface colors change with actual stored Result profile values.");
        Check(first.Layers[0].LegendStops.Length > 1
            && first.Layers[0].NoDataValue == -9999f
            && first.Layers[0].Units.Length > 0,
            "The raster retains the source default symbology ramp, no-data marker and unit label.");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
            && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore)
            && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore),
            "Rendering profile frames leaves the project, .vis, Result HDF and associated terrain byte-identical.");

        Expect<SourceFileChangedException>(() => MapResultRenderService.Render(new(fixture.Map, [],
            new string('0', 64), node.Node, 1, viewport)));
        CheckComputeLeasePreservesReadableSiblingSlots(directory.FullName);
        MapResultVelocityFieldChecks.Run();
        ExportFixtureIfRequested(directory.FullName);
        Console.WriteLine("Map-scoped Result raster rendering, real HDF profile changes, terrain association, RGBA/no-data/ramp metadata, stale context rejection and read-only source checks passed.");
    }

    internal static Fixture CreateFixture(string directory, bool velocityVariesByProfile = false)
    {
        string projectPath = Path.Combine(directory, "Map Result Render.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.USCustomary);
        try
        {
            Terrain terrain = project.AddNewTerrain("Render terrain");
            terrain.Add(new ConstantTerrainInput(terrain, 100f, new Extent(0, 1, 0, 1), "Flat bed"));
            terrain.Save();
            project.DefaultTerrain = terrain;

            Geometry geometry = project.AddNewGeometry("Render geometry");
            Mesh mesh = CreateMesh();
            var elevations = new ConstantValueResampler<float>(100f, Extent.Infinite, -9999f);
            var roughness = new ConstantValueResampler<float>(0.03f, Extent.Infinite, -9999f);
            var computed = MeshPropertyTables.ComputeFrom(mesh, elevations, roughness,
                PropertyTableOptions.Default(UnitSystem.USCustomary), out MeshPropertyTables tables);
            Check(computed.Result, "The retained mesh-property builder creates the embedded Result fixture geometry.");
            geometry.FlowAreaLayer.Add(new FlowArea(mesh, "Render flow area") { PropertyTables = tables });
            geometry.Save();

            BoundaryCondition boundary = project.AddNewBoundaryCondition("Render boundary", Start, TimeSpan.FromHours(2));
            Plan plan = project.AddNewPlan("Render plan", geometry, boundary);
            project.Save();
            terrain.Save();
            Directory.CreateDirectory(project.ResultsDirectory);

            string resultPath = project.GetUniqueResultFilename(plan.Name);
            using (Result prepared = Result.PrepareResult(resultPath, plan, geometry, boundary, null!))
                Check(File.Exists(resultPath), "The retained Result writer creates a standalone Result HDF fixture.");
            if (!Result.TryLoad(resultPath, out Result? loaded) || loaded is null)
                throw new InvalidDataException("Could not reopen the Result fixture for OutputBlock writing.");
            using (loaded)
            using (var output = OutputBlock.CreateNew(loaded, "Base Output"))
            {
                output.EnableWriting();
                float[] stages = [102f, 104f, 106f];
                for (int index = 0; index < stages.Length; index++)
                {
                    FlowArea area = loaded.Geometry.FlowAreaLayer[0];
                    var state = new MeshWaterState(area.Mesh, area.PropertyTables)
                    {
                        tMicros = index * 1_800_000_000L,
                        CellElevation = [stages[index]],
                        FaceVelocity = velocityVariesByProfile
                            ? [0.25f + index * 0.25f, 0.5f + index * 0.25f,
                                0.75f + index * 0.25f, 1f + index * 0.25f]
                            : [0.25f, 0.5f, 0.75f, 1f]
                    };
                    output.AddTimestep(new MeshTimestep(state, index));
                }
                output.FinishWriting();
            }

            string projectXml = File.ReadAllText(projectPath);
            string projectXmlSHA = Hash(Encoding.UTF8.GetBytes(projectXml));
            MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
                projectPath, projectXml, projectXmlSHA, null, "Project", Name: "Render map"));
            string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
            XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
            XElement map = visualization.Root!.Element("Maps")!.Elements("Map").ElementAt(created.MapIndex);
            map.Add(new XElement("Tree", new XElement("Nodes",
                new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Results"),
                    new XElement("Node", new XAttribute("Type", "Result"),
                        new XAttribute("Name", Path.GetFileNameWithoutExtension(resultPath)),
                        new XAttribute("IsChecked", true), new XAttribute("SelectedMapType", "Depth"),
                        new XAttribute("ProfileIndex", 0))))));
            visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

            string visualizationRevision = Hash(visualizationPath);
            string mapID = Guid.NewGuid().ToString("D");
            var mapRequest = new MapTreeRequest(projectPath, projectXml, projectXmlSHA,
                mapID, created.MapIndex, created.MapName, created.MapType, visualizationRevision);
            return new Fixture(projectPath, visualizationPath, resultPath, terrain.Filename, mapRequest);
        }
        finally
        {
            foreach (Result result in project.Results) result.Dispose();
            foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                         .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                         .Concat(project.ClassificationLayers))
                layer.Dispose();
        }
    }

    private static void CheckComputeLeasePreservesReadableSiblingSlots(string directory)
    {
        string fixtureDirectory = Path.Combine(directory, "compute-slot-keyframe");
        Directory.CreateDirectory(fixtureDirectory);
        Fixture fixture = CreateFixture(fixtureDirectory, velocityVariesByProfile: true);
        string stablePath = Path.Combine(Path.GetDirectoryName(fixture.ResultPath)!, "Render historical copy.h5");
        File.Copy(fixture.ResultPath, stablePath);

        using (Result loaded = Result.TryLoad(fixture.ResultPath, out Result? writerResult) && writerResult is not null
                   ? writerResult
                   : throw new InvalidDataException("Could not read the generated Result keyframe fixture."))
        {
            string planName = loaded.Plan?.Name
                ?? throw new InvalidDataException("The generated Result fixture has no Plan identity.");
            XDocument visualization = XDocument.Load(fixture.VisualizationPath, LoadOptions.PreserveWhitespace);
            XElement resultRoot = visualization.Root!.Element("Maps")!.Elements("Map")
                .ElementAt(fixture.Map.MapIndex).Element("Tree")!.Element("Nodes")!.Elements("Node")
                .Single(item => (string?)item.Attribute("Name") == "Results");
            // This check isolates MultiResult slot masking. The shared fixture
            // also contains a checked standalone Result row, whose independent
            // serialized selection is outside this sibling-slot contract.
            resultRoot.Elements("Node").Single(item => (string?)item.Attribute("Type") == "Result")
                .SetAttributeValue("IsChecked", false);
            resultRoot.Add(new XElement("Node", new XAttribute("Type", "MultiResult"),
                new XAttribute("Name", planName), new XAttribute("IsChecked", true),
                new XAttribute("SelectedMapType", "Depth"), new XAttribute("ProfileIndex", 0)));
            visualization.Save(fixture.VisualizationPath, SaveOptions.DisableFormatting);

            byte[] projectBytes = File.ReadAllBytes(fixture.ProjectPath);
            byte[] visualizationBytes = File.ReadAllBytes(fixture.VisualizationPath);
            byte[] writerBytes = File.ReadAllBytes(fixture.ResultPath);
            byte[] stableBytes = File.ReadAllBytes(stablePath);
            byte[] terrainBytes = File.ReadAllBytes(fixture.TerrainPath);

            MapTreeRequest map = fixture.Map with
            { ExpectedVisualizationRevision = Hash(fixture.VisualizationPath) };
            MapResultActiveNode initialGroup = MapResultChartService.Sources(new(map, []))
                .ActiveNodes.Single(item => item.NodeKind == "MultiResult");
            MapResultSourceChoice writerChoice = initialGroup.Selections[0].Choices.Single(choice =>
                SourceFilePaths.SameSourceFile(choice.ResultPath, fixture.ResultPath));
            MapResultSourceChoice stableChoice = initialGroup.Selections[0].Choices.Single(choice =>
                SourceFilePaths.SameSourceFile(choice.ResultPath, stablePath));
            string runID = Guid.NewGuid().ToString("D");
            var lease = new MapResultComputeReadLease(Guid.NewGuid().ToString("D"), runID,
                fixture.ProjectPath, [fixture.ResultPath], fixture.ResultPath);
            MapTreeRequest leasedMap = map with { ComputeReadLease = lease };
            RasterMapViewExtent viewport = new(0, 0, 1, 1, 32, 32);

            IHorizontalOutputBlock output = loaded.BaseOutputBlock
                ?? throw new InvalidDataException("The generated Result fixture has no Base Output block.");
            MapResultRenderLiveKeyframeAnchor anchor = new(initialGroup.Node, 0, runID,
                fixture.ResultPath, output.Name, output.ProfileCount, 1,
                output.ProfileNames[1], output.Times[1].ToString("O", CultureInfo.InvariantCulture));

            MapResultSelectionOverride[] writerFirstOverrides =
            [
                new(initialGroup.Node, 0, "Explicit", writerChoice.ResultPath, writerChoice.Revision),
                new(initialGroup.Node, 1, "Explicit", stableChoice.ResultPath, stableChoice.Revision)
            ];
            MapResultSourcesResult writerFirstSources = MapResultChartService.Sources(new(leasedMap,
                writerFirstOverrides));
            MapResultActiveNode writerFirstGroup = writerFirstSources.ActiveNodes.Single(item =>
                item.NodeKind == "MultiResult");
            Check(writerFirstGroup.Selections.Length == 2
                && writerFirstGroup.Selections[0].SelectionIndex == 0
                && writerFirstGroup.Selections[0].SelectedResult is null
                && writerFirstGroup.Selections[1].SelectionIndex == 1
                && writerFirstGroup.Selections[1].SelectedResult is { } selectedSibling
                && SourceFilePaths.SameSourceFile(selectedSibling.ResultPath, stablePath),
                "A protected explicit slot remains in the MultiResult selection array while its readable sibling retains index one.");
            MapResultRenderResult writerFirstFrame = MapResultRenderService.Render(new(leasedMap,
                writerFirstOverrides, writerFirstSources.ContextToken, writerFirstGroup.Node,
                1, viewport, [0], anchor));
            Check(writerFirstFrame.Layers.Length == 1
                && SourceFilePaths.SameSourceFile(writerFirstFrame.Layers[0].ResultPath, stablePath)
                && writerFirstFrame.Layers[0].ProfileIndex == 1
                && writerFirstFrame.Sources.Length == 1
                && writerFirstFrame.Sources[0].SelectionIndices.SequenceEqual([1])
                && !writerFirstFrame.Sources.Any(status => SourceFilePaths.SameSourceFile(status.ResultPath,
                    fixture.ResultPath)),
                "A callback-owned slot-zero ProfileName/time anchors real rendering for the safe slot one without returning writer-owned source status or pixels.");

            MapResultSelectionOverride[] writerSecondOverrides =
            [
                new(initialGroup.Node, 0, "Explicit", stableChoice.ResultPath, stableChoice.Revision),
                new(initialGroup.Node, 1, "Explicit", writerChoice.ResultPath, writerChoice.Revision)
            ];
            MapResultSourcesResult writerSecondSources = MapResultChartService.Sources(new(leasedMap,
                writerSecondOverrides));
            MapResultActiveNode writerSecondGroup = writerSecondSources.ActiveNodes.Single(item =>
                item.NodeKind == "MultiResult");
            Check(writerSecondGroup.Selections.Length == 2
                && SourceFilePaths.SameSourceFile(writerSecondGroup.Selections[0].SelectedResult!.ResultPath,
                    stablePath)
                && writerSecondGroup.Selections[1].SelectedResult is null,
                "A protected explicit slot one stays pending without shifting readable slot zero.");
            MapResultRenderResult writerSecondFrame = MapResultRenderService.Render(new(leasedMap,
                writerSecondOverrides, writerSecondSources.ContextToken, writerSecondGroup.Node,
                2, viewport, [1]));
            Check(writerSecondFrame.Layers.Length == 1
                && SourceFilePaths.SameSourceFile(writerSecondFrame.Layers[0].ResultPath, stablePath)
                && writerSecondFrame.Layers[0].ProfileIndex == 2
                && writerSecondFrame.Sources.Single().SelectionIndices.SequenceEqual([0]),
                "A safe slot-zero Result keeps its stored timeline and frame while the protected slot one is excluded from rendering.");

            Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBytes)
                && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBytes)
                && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(writerBytes)
                && File.ReadAllBytes(stablePath).SequenceEqual(stableBytes)
                && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBytes),
                "Both slot orders preserve the project, visualization, writer-owned Result, historical Result and terrain bytes.");
        }
    }

    private static Mesh CreateMesh()
    {
        Point[] points = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)];
        Face[] faces = Enumerable.Range(0, 4)
            .Select(index => new Face { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point)
            { Faces = [(index + 3) % 4, index] }).ToArray();
        return new Mesh(new Polygon(points), [new Cell { Faces = new int[] { 0, 1, 2, 3 } }],
            faces, nodes, [new Point(0.5, 0.5)], null!);
    }

    private static void ExportFixtureIfRequested(string sourceRoot)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string source = Path.GetFullPath(sourceRoot);
        if (Directory.Exists(target) || File.Exists(target) ||
            target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The map-result render acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Map Result raster render fixture built with Result.PrepareResult and OutputBlock.CreateNew. "
            + "The three stored profile values are deterministic test data, not solver output. "
            + "A checked standalone Result node is rendered as Depth against the current project's flat associated terrain.");
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static string SwiftSourceIdentity(CatalogTreeNodeLocator locator)
    {
        StringBuilder identity = new();
        Append(locator.RootName);
        Append(locator.NodeType);
        Append(locator.NodeName);
        Append(NodePath(locator.NodePath));
        Append(locator.AssetID ?? string.Empty);
        Append(locator.MapType ?? string.Empty);
        Append(locator.Filename ?? string.Empty);
        Append(locator.FilenameRelative ?? string.Empty);
        Append(locator.ParentGeometryAssetID ?? string.Empty);
        Append(NodePath(locator.ParentGeometryNodePath));
        Append(locator.ParentGeometryNodeName ?? string.Empty);
        Append(locator.ParentPlanAssetID ?? string.Empty);
        Append(NodePath(locator.ParentPlanNodePath));
        Append(locator.ParentPlanNodeName ?? string.Empty);
        Append(locator.ParentResultNodeType ?? string.Empty);
        Append(locator.ParentResultAssetID ?? string.Empty);
        Append(NodePath(locator.ParentResultNodePath));
        Append(locator.ParentResultNodeName ?? string.Empty);
        Append(locator.ParentResultRevision ?? string.Empty);
        Append(locator.AssociationAssetID ?? string.Empty);
        Append(locator.AssociationKind ?? string.Empty);
        return identity.ToString();

        void Append(string component)
        {
            if (identity.Length > 0) identity.Append('|');
            identity.Append(Encoding.UTF8.GetByteCount(component).ToString(CultureInfo.InvariantCulture))
                .Append(':').Append(component);
        }
    }

    private static string NodePath(int[]? path) => path is null
        ? string.Empty
        : string.Join('.', path.Select(index => index.ToString(CultureInfo.InvariantCulture)));

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

    internal sealed record Fixture(string ProjectPath, string VisualizationPath, string ResultPath,
        string TerrainPath, MapTreeRequest Map);
}
