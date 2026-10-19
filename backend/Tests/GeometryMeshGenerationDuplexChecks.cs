using System.Text.Json;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryMeshGenerationDuplexChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Mesh generation progress.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Progress geometry");
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(0, 20, 0, 20));
        geometry.Save();
        project.Save();
        string assetPath = geometry.Filename;
        geometry.Dispose();

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

        var model = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryMeshSnapshot loaded = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model,
            TopologyDraftState: sized.DraftState));
        byte[] original = File.ReadAllBytes(assetPath);

        const string cancelID = "mesh-generation-cancel-test";
        var cancelReader = new CancellationControlReader();
        var cancelProgress = new List<BackendOperationProgress>();
        await using (var controls = new BackendDuplexControlReader(cancelID, cancelReader))
        {
            GeometryMeshGenerateResult cancelled = await ModelEditorAdapter.GenerateGeometryMeshDuplexAsync(
                new(model, loaded.Revision, loaded.DraftState, sized.DraftState, [], cancelID),
                update =>
                {
                    cancelProgress.Add(update);
                    if (update.TaskName is not null) cancelReader.SendCancel(cancelID);
                }, controls);
            GeometryMeshMutation cancelledMutation = JsonSerializer.Deserialize<GeometryMeshDraftState>(
                cancelled.Snapshot.DraftState, BackendJson.Options)!.Mutations.Single();
            Check(cancelled.OperationID == cancelID && cancelled.Revision == loaded.Revision && cancelled.Cancelled,
                "The duplex control frame reaches the retained mesh reporter and the terminal response is tied to its operation and source revision");
            Check(cancelled.Snapshot.IsDirty && cancelled.Snapshot.FlowAreas.Length == 0
                && cancelled.Snapshot.GenerationReport is { MeshWasReplaced: true }
                && cancelledMutation.Operation == "generate" && cancelledMutation.GeneratedMeshPayload == "",
                "Source cancellation preserves the original Generate Mesh clear-then-return behavior in the parent draft without adding a partial mesh");
            Check(cancelProgress.Any(update => update.TaskName?.Contains("Mesh Generation", StringComparison.Ordinal) == true),
                "The running tree job receives the actual source BatchJob name");
        }

        var progress = new List<BackendOperationProgress>();
        const string operationID = "mesh-generation-success-test";
        await using (var controls = new BackendDuplexControlReader(operationID, TextReader.Null))
        {
            GeometryMeshGenerateResult generated = await ModelEditorAdapter.GenerateGeometryMeshDuplexAsync(
                new(model, loaded.Revision, loaded.DraftState, sized.DraftState, [], operationID),
                progress.Add, controls);
            Check(!generated.Cancelled && generated.OperationID == operationID
                && generated.Revision == loaded.Revision
                && generated.Snapshot.GenerationReport is { Succeeded: true, MeshWasReplaced: true, CellCount: > 0 },
                "Duplex generation returns the source BuildConceptualMesh result for the exact loaded revision");
            Check(progress.Any(update => update.Fraction is > 0 and <= 1)
                && progress.Any(update => !string.IsNullOrWhiteSpace(update.Message)),
                "The real ProgressReporter fraction and messages reach the duplex consumer");
            Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
                "Mesh generation remains an in-memory child draft and never writes the source geometry HDF");

            GeometryMeshDraftState state = JsonSerializer.Deserialize<GeometryMeshDraftState>(
                generated.Snapshot.DraftState, BackendJson.Options)!;
            Check(state.Mutations.Single() is { Operation: "generate", GeneratedMeshPayload.Length: > 0 },
                "The child ledger retains the exact generated mesh artifact needed by the parent save");
            ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(new ModelSaveRequest(assetPath, "Geometry",
                projectPath, generated.Revision, [], [], GeometryTopologyState: sized.DraftState,
                GeometryMeshState: generated.Snapshot.DraftState));
            GeometryMeshSnapshot reopened = await ModelEditorAdapter.LoadGeometryMeshAsync(new(model, saved.Revision));
            Check(reopened.FlowAreas.Length == 1 && reopened.FlowAreas[0].CellCount == generated.Snapshot.FlowAreas[0].CellCount,
                "The parent geometry save and independent mesh reload preserve the exact generated source artifact");
        }
    }

    private sealed class CancellationControlReader : TextReader
    {
        private readonly TaskCompletionSource<string?> line = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int cancelSent;
        private int lineRead;

        public void SendCancel(string id)
        {
            if (Interlocked.Exchange(ref cancelSent, 1) != 0) return;
            line.TrySetResult(JsonSerializer.Serialize(new
            {
                id,
                controlSequence = 1,
                control = new { type = "cancel" }
            }));
        }

        public override ValueTask<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            if (Interlocked.Exchange(ref lineRead, 1) != 0)
                return ValueTask.FromResult<string?>(null);
            return new(line.Task.WaitAsync(cancellationToken));
        }
    }
}
