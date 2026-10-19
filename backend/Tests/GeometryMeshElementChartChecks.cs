using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using Geospatial.Vectors.Topology;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class GeometryMeshElementChartChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Mesh element chart.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Chart terrain");
        string rasterPath = Path.Combine(terrain.SourceDirectory, "flat.tif");
        using (var driver = Gdal.GetDriverByName("GTiff"))
        using (var raster = driver.Create(rasterPath, 32, 32, 1, DataType.GDT_Float32,
            ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
        {
            raster.SetGeoTransform([0, 1, 0, 32, 0, -1]);
            using var band = raster.GetRasterBand(1);
            band.Fill(42, 0);
        }
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, rasterPath));
        NValueLayer roughness = project.AddNewNValueLayer("Chart roughness");
        roughness.SetConstant(0.035f);
        Geometry geometry = project.AddNewGeometry("Chart geometry", terrain, roughness);
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(4, 24, 4, 24));
        geometry.Save();
        terrain.Save();
        roughness.Save();
        project.Save();
        string assetPath = geometry.Filename;
        DisposeProject(project);

        var topologyModel = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topology = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        GeometryTopologySnapshot triangle = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, topology.DraftState,
            new("setField", "region", [0], "PatchType", "TrianglePaver")));
        GeometryTopologySnapshot sized = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, triangle.DraftState,
            new("setField", "region", [0], "ConstantSize", "4")));
        var model = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryMeshSnapshot loaded = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model,
            TopologyDraftState: sized.DraftState));
        GeometryMeshSnapshot generated = await ModelEditorAdapter.EditGeometryMeshAsync(new(model,
            loaded.Revision, loaded.DraftState, sized.DraftState, [], new("generate")));
        Check(generated.GenerationReport is { Succeeded: true, MeshWasReplaced: true },
            "The real source Geometry mesh is generated before chart table computation.");
        GeometryMeshFlowAreaRow flowArea = generated.FlowAreas.Single(row => row.HasMesh);
        string sessionID = Guid.NewGuid().ToString("D");
        byte[] sourceBeforeCompute = File.ReadAllBytes(assetPath);

        GeometryMeshPropertyTablesResult computed;
        GeometryMeshElementPropertyChartResult cell;
        GeometryMeshElementPropertyChartResult face;
        var computeProgress = new List<BackendOperationProgress>();
        using (new ReadOnlyFiles([assetPath]))
        {
            GeometryMeshElementPropertyChartResult missingTables = await LoadChart(model,
                generated.Revision, generated.DraftState, sized.DraftState, flowArea,
                sessionID, "Cell", 0, null, null);
            Check(missingTables.State == "requiresPropertyTables"
                && missingTables.FlowAreaIndex == flowArea.RowIndex,
                "A missing table produces an exact selected-element response with a draft Compute action, without asking for parent save.");

            await using (var controls = new BackendDuplexControlReader("chart-child-compute", TextReader.Null))
            {
                computed = await ModelEditorAdapter.ComputeGeometryMeshPropertyTablesDuplexAsync(
                    new(model, generated.Revision, generated.DraftState, sized.DraftState, []),
                    computeProgress.Add, controls);
            }
            Check(computed.Succeeded && computed.Snapshot.IsDirty
                && computed.Snapshot.FlowAreas.Single(row => row.ID == flowArea.ID).HasPropertyTables,
                "The original Geometry child Compute algorithm produces an unsaved property-table draft while the source HDF is read-only.");
            Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBeforeCompute),
                "Child Compute leaves the source Geometry HDF byte-for-byte unchanged.");

            byte[] beforePlot = File.ReadAllBytes(assetPath);
            var replayProgress = new List<BackendOperationProgress>();
            cell = await LoadChart(model, computed.Snapshot.Revision,
                computed.Snapshot.DraftState, sized.DraftState, flowArea, sessionID,
                "Cell", 0, replayProgress.Add, null);
            face = await LoadChart(model, computed.Snapshot.Revision,
                computed.Snapshot.DraftState, sized.DraftState, flowArea, sessionID,
                "Face", 0, replayProgress.Add, null);
            Check(cell.State == "ready" && cell.Points.Length >= 2
                && cell.XQuantity == "Volume" && cell.XUnits == "m³"
                && cell.YQuantity == "Elevation" && cell.YUnits == "m",
                "An unsaved child Compute marker is replayed in the temporary context and returns the original Cell volume/elevation table with SI units.");
            Check(face.State == "ready" && face.Points.Length >= 2
                && face.XQuantity == "Area" && face.XUnits == "m²"
                && face.YQuantity == "Elevation" && face.YUnits == "m",
                "The same unsaved child Compute marker returns the original Face area/elevation table with SI units.");
            Check(replayProgress.Any(item => item.Fraction is not null || item.TaskName is not null || item.Message is not null),
                "Temporary property-table replay reports progress through the duplex request.");
            Check(File.ReadAllBytes(assetPath).SequenceEqual(beforePlot),
                "Cell and Face chart replay never commits the source Geometry HDF.");

            var cancelRequest = Request(model, computed.Snapshot.Revision, computed.Snapshot.DraftState,
                sized.DraftState, flowArea, sessionID, "Cell", 0);
            string cancelLine = JsonSerializer.Serialize(new
            {
                id = cancelRequest.OperationID,
                controlSequence = 1,
                control = new { type = "cancel" }
            }) + "\n";
            await using (var cancelControls = new BackendDuplexControlReader(cancelRequest.OperationID,
                new StringReader(cancelLine)))
            {
                await Task.Delay(50);
                GeometryMeshElementPropertyChartResult cancelled = await ModelEditorAdapter
                    .LoadGeometryMeshElementPropertyChartDuplexAsync(cancelRequest, null, cancelControls);
                Check(cancelled.State == "cancelled",
                    "A prequeued duplex cancel interrupts source property-table replay and returns a cancelled state.");
            }
            Check(File.ReadAllBytes(assetPath).SequenceEqual(beforePlot),
                "A cancelled chart replay leaves the source Geometry HDF unchanged.");

            ExportSwiftWireFixtureIfRequested(directory.FullName, model, generated, sized.DraftState,
                flowArea, sessionID);
        }

        _ = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
            projectPath, computed.Snapshot.Revision, [], [], GeometryTopologyState: sized.DraftState,
            GeometryMeshState: computed.Snapshot.DraftState));
        Check(!File.ReadAllBytes(assetPath).SequenceEqual(sourceBeforeCompute),
            "Only the explicit parent Geometry save changes the source HDF.");

        Project reopened = new(projectPath);
        Geometry savedGeometry = reopened.Geometries.Single(item => SamePath(item.Filename, assetPath));
        FlowArea savedFlowArea = savedGeometry.FlowAreaLayer.Features[flowArea.RowIndex];
        MeshPropertyTables tables = savedFlowArea.PropertyTables
            ?? throw new InvalidDataException("The saved Geometry did not persist its real property tables.");
        CheckMatches(cell.Points, tables.CellTableStart![0], tables.CellTableCount![0],
            tables.CellVolumeTable!, tables.CellElevationTable!, "Cell volume/elevation");
        CheckMatches(face.Points, tables.FaceTableStart![0], tables.FaceTableCount![0],
            tables.FaceAreaTable!, tables.FaceElevationTable!, "Face area/elevation");
        DisposeProject(reopened);

        Check(computeProgress.Any(item => item.TaskName is not null || item.Fraction is not null),
            "The source Geometry child Compute operation reports progress.");
        Console.WriteLine("Geometry mesh element chart: actual Cell/Face ranges, SI units, unsaved child replay, cancellation and source-HDF preservation passed.");
    }

    private static async Task<GeometryMeshElementPropertyChartResult> LoadChart(
        GeometryMeshModelRequest model, string revision, string draftState, string? topologyState,
        GeometryMeshFlowAreaRow flowArea, string sessionID, string kind, int index,
        Action<BackendOperationProgress>? progress, string? operationID)
    {
        GeometryMeshElementPropertyChartRequest request = Request(model, revision, draftState,
            topologyState, flowArea, sessionID, kind, index, operationID);
        await using var controls = new BackendDuplexControlReader(request.OperationID, TextReader.Null);
        return await ModelEditorAdapter.LoadGeometryMeshElementPropertyChartDuplexAsync(request,
            progress, controls);
    }

    private static GeometryMeshElementPropertyChartRequest Request(GeometryMeshModelRequest model,
        string revision, string draftState, string? topologyState, GeometryMeshFlowAreaRow flowArea,
        string sessionID, string kind, int index, string? operationID = null) => new(
            operationID ?? Guid.NewGuid().ToString("D"), sessionID, "geometry-mesh-chart-fixture",
            model, revision, draftState, topologyState, Hash(draftState), Hash(topologyState ?? string.Empty),
            flowArea.ID, flowArea.Name, kind, index);

    private static void CheckMatches(GeometryMeshElementPropertyChartPoint[] points, int start, short count,
        float[] x, float[] y, string description)
    {
        Check(points.Length == count && count >= 2 && start >= 0
            && start <= x.Length - count && start <= y.Length - count,
            description + " uses its exact source start/count slice.");
        for (int index = 0; index < count; index++)
            Check(Math.Abs(points[index].X - x[start + index]) < 1e-6
                && Math.Abs(points[index].Y - y[start + index]) < 1e-6,
                description + " values match the reopened source HDF table at the exact range.");
    }

    private static void ExportSwiftWireFixtureIfRequested(string sourceDirectory,
        GeometryMeshModelRequest model, GeometryMeshSnapshot generated, string topologyState,
        GeometryMeshFlowAreaRow flowArea, string sessionID)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_GEOMETRY_MESH_ELEMENT_CHART_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string source = Path.GetFullPath(sourceDirectory);
        if (Directory.Exists(target) || File.Exists(target) ||
            target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The Geometry mesh chart acceptance directory already exists or is inside the temporary source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }
        string copiedProjectPath = Path.Combine(target, Path.GetRelativePath(source, model.ProjectPath!));
        string copiedAssetPath = Path.Combine(target, Path.GetRelativePath(source, model.AssetPath));
        string copiedProjectXml = File.ReadAllText(copiedProjectPath);
        string copiedDraft = JsonSerializer.Serialize(
            JsonSerializer.Deserialize<GeometryMeshDraftState>(generated.DraftState, BackendJson.Options)!
                with { AssetPath = copiedAssetPath }, BackendJson.Options);
        string copiedTopology = JsonSerializer.Serialize(
            JsonSerializer.Deserialize<GeometryTopologyDraftState>(topologyState, BackendJson.Options)!
                with { AssetPath = copiedAssetPath }, BackendJson.Options);
        GeometryMeshModelRequest copiedModel = model with
        {
            AssetPath = copiedAssetPath,
            ProjectPath = copiedProjectPath,
            ProjectXml = copiedProjectXml
        };
        var fixture = new
        {
            projectSessionID = sessionID,
            assetID = "geometry-mesh-chart-fixture",
            model = copiedModel,
            revision = generated.Revision,
            draftState = copiedDraft,
            topologyDraftState = copiedTopology,
            meshDraftSHA256 = Hash(copiedDraft),
            topologyDraftSHA256 = Hash(copiedTopology),
            flowAreaID = flowArea.ID,
            expectedFlowAreaName = flowArea.Name,
            elementKind = "Cell",
            elementIndex = 0
        };
        File.WriteAllText(Path.Combine(target, "chart-request.json"),
            JsonSerializer.Serialize(fixture, BackendJson.Options));
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Temporary Geometry mesh with a real generated mesh and child ComputePropertyTables draft. "
            + "The request is deliberately pre-compute so the bundled Swift wire test runs the actual Compute child operation, then the exact chart replay without parent save.");
    }

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static bool SamePath(string left, string right) =>
        Path.GetFullPath(left).Equals(Path.GetFullPath(right), StringComparison.Ordinal);

    private static void DisposeProject(Project project)
    {
        foreach (Geometry geometry in project.Geometries) geometry.Dispose();
        foreach (Terrain terrain in project.Terrains) terrain.Dispose();
        foreach (NValueLayer layer in project.NValues) layer.Dispose();
        foreach (Plan plan in project.Plans) plan.Dispose();
        foreach (BoundaryCondition boundary in project.BoundaryConditions) boundary.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private sealed class ReadOnlyFiles : IDisposable
    {
        private readonly Dictionary<string, FileAttributes> originalAttributes = [];

        internal ReadOnlyFiles(IEnumerable<string> paths)
        {
            try
            {
                foreach (string path in paths.Distinct(StringComparer.Ordinal))
                {
                    FileAttributes attributes = File.GetAttributes(path);
                    originalAttributes.Add(path, attributes);
                    File.SetAttributes(path, attributes | FileAttributes.ReadOnly);
                }
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            foreach ((string path, FileAttributes attributes) in originalAttributes)
                File.SetAttributes(path, attributes);
            originalAttributes.Clear();
        }
    }
}
