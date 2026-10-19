using System.Text.Json;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class GeometryMeshPropertyTablesChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Property tables.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("Property-table terrain");
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
        NValueLayer roughness = project.AddNewNValueLayer("Property-table roughness");
        roughness.SetConstant(0.035f);
        Geometry geometry = project.AddNewGeometry("Property-table geometry", terrain, roughness);
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(4, 24, 4, 24));
        geometry.Save();
        terrain.Save();
        roughness.Save();
        project.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();
        terrain.Dispose();
        roughness.Dispose();

        var topologyModel = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topology = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        GeometryTopologySnapshot triangle = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, topology.DraftState,
            new("setField", "region", [0], "PatchType", "TrianglePaver")));
        GeometryTopologySnapshot primary = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, triangle.DraftState,
            new("setField", "region", [0], "ConstantSize", "4")));
        GeometryTopologySnapshot sized = await ModelEditorAdapter.EditGeometryTopologyAsync(new(topologyModel,
            topology.Revision, primary.DraftState,
            new("setField", "region", [0], "SecondaryConstantSize", "4")));

        var meshModel = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryMeshSnapshot loaded = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel,
            TopologyDraftState: sized.DraftState));
        GeometryMeshSnapshot generated = await ModelEditorAdapter.EditGeometryMeshAsync(new(meshModel,
            loaded.Revision, loaded.DraftState, sized.DraftState, [], new("generate")));
        Check(generated.GenerationReport is { Succeeded: true, MeshWasReplaced: true },
            "Property-table action fixture has a source-generated mesh");
        byte[] sourceBeforeCompute = File.ReadAllBytes(assetPath);

        bool staleRevisionRejected = false;
        await using (var staleControls = new BackendDuplexControlReader("property-tables-stale", TextReader.Null))
        {
            try
            {
                await ModelEditorAdapter.ComputeGeometryMeshPropertyTablesDuplexAsync(
                    new(meshModel, "stale-source-revision", generated.DraftState, sized.DraftState, []),
                    null, staleControls);
            }
            catch (SourceFileChangedException) { staleRevisionRejected = true; }
        }
        Check(staleRevisionRejected,
            "Property-table computation rejects a revision that no longer identifies the captured source HDF");

        var progress = new List<BackendOperationProgress>();
        await using (var controls = new BackendDuplexControlReader("property-tables-success", TextReader.Null))
        {
            GeometryMeshPropertyTablesResult computed = await ModelEditorAdapter.ComputeGeometryMeshPropertyTablesDuplexAsync(
                new(meshModel, generated.Revision, generated.DraftState, sized.DraftState, []),
                progress.Add, controls);
            Check(computed.Succeeded && !computed.Cancelled
                && computed.Snapshot.FlowAreas.Single().HasPropertyTables
                && computed.Snapshot.FlowAreas.Single().PropertyTablesQueuedForParentSave,
                "The explicit mesh action runs the source terrain/N-value property-table computation and retains a parent-save intent");
            Check(computed.Snapshot.DraftState != generated.DraftState
                && JsonSerializer.Deserialize<GeometryMeshDraftState>(computed.Snapshot.DraftState, BackendJson.Options)!
                    .Mutations.Count(mutation => mutation.Operation == "computePropertyTables") == 1,
                "Only a successful source computation appends one replay marker to the exact child draft");
            Check(File.ReadAllBytes(assetPath).SequenceEqual(sourceBeforeCompute),
                "The property-table preview never writes directly to the user's source geometry HDF");

            ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
                projectPath, generated.Revision, [], [], GeometryTopologyState: sized.DraftState,
                GeometryMeshState: computed.Snapshot.DraftState));
            Check(!File.ReadAllBytes(assetPath).SequenceEqual(sourceBeforeCompute),
                "The source geometry HDF remains untouched by preview and changes only during the parent save");

            GeometryMeshSnapshot reopened = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel, saved.Revision));
            Check(reopened.FlowAreas.Single().HasPropertyTables
                && !reopened.FlowAreas.Single().PropertyTablesQueuedForParentSave,
                "A fresh mesh read reports source property tables persisted by the parent save, not a stale pending marker");
            Project reopenedProject = new(projectPath);
            Geometry reopenedGeometry = reopenedProject.Geometries.Single(item => item.Name == "Property-table geometry");
            Check(reopenedGeometry.FlowAreaLayer.Features.Single().PropertyTables is not null,
                "Independent project reopen reads the actual source property-table HDF payload");
        }

        Check(progress.Any(item => item.TaskName is not null || item.Fraction is not null),
            "The retained source operation reports progress through the duplex route");
        Console.WriteLine("Geometry mesh property-table action, progress, child draft, parent save and source HDF readback checks passed.");
    }
}
