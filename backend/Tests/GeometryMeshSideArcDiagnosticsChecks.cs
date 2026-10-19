using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryMeshSideArcDiagnosticsChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Incomplete Quad source.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Incomplete Quad geometry");
        Topology sourceTopology = Topology.FromExtent(new Extent(0, 20, 0, 10));
        sourceTopology.RemoveArc(0);
        geometry.ConceptualMeshLayer.Topology = sourceTopology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();
        byte[] original = File.ReadAllBytes(assetPath);

        var model = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot topology = await ModelEditorAdapter.LoadGeometryTopologyAsync(
            new GeometryTopologyLoadRequest(new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath)));
        int regionFID = topology.Regions.Rows.Single().FID;
        GeometryMeshSnapshot mesh = await ModelEditorAdapter.LoadGeometryMeshAsync(
            new GeometryMeshLoadRequest(model, Revision: topology.Revision,
                TopologyDraftState: topology.DraftState, SelectedRegionIDs: [regionFID]));

        GeometryMeshDimensionCheck(mesh, regionFID, "NorthSouth");
        GeometryMeshDimensionCheck(mesh, regionFID, "EastWest");

        bool mutationRejected = false;
        try
        {
            _ = await ModelEditorAdapter.EditGeometryMeshAsync(new GeometryMeshEditRequest(model,
                mesh.Revision, mesh.DraftState, topology.DraftState, [regionFID],
                new GeometryMeshMutation("resizePatch", FeatureIDs: [regionFID], Value: "0.5",
                    Axis: "NorthSouth")));
        }
        catch (InvalidOperationException exception)
        {
            mutationRejected = exception.Message.Contains($"Region FID {regionFID}:", StringComparison.Ordinal);
        }
        Check(mutationRejected,
            "A failed source side derivation is reported and cannot silently resize a partial set of arcs");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(original),
            "Inspecting and rejecting an incomplete side operation does not write the source geometry");
    }

    private static void GeometryMeshDimensionCheck(GeometryMeshSnapshot mesh, int regionFID, string axis)
    {
        GeometryMeshPatchDimension dimension = mesh.PatchSizing?.Dimensions.Single(item => item.ID == axis)
            ?? throw new InvalidOperationException($"The {axis} Quad dimension was omitted.");
        GeometryMeshPatchSideArcIssue[] issues = dimension.SideArcIssues ?? [];
        Check(issues.Length > 0
            && issues.Any(issue => issue.RegionFID == regionFID && issue.Axis == axis),
            $"The {axis} dimension preserves a source diagnostic for the incomplete region");
        Check(!dimension.CanApply && !dimension.CanResize && !dimension.CanChangeMode,
            $"The {axis} dimension cannot edit a partial source side");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
