using System.Globalization;
using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryMeshArcPreviewChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Quad arc preview.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry("Quad geometry");
        geometry.ConceptualMeshLayer.Topology = Topology.FromExtent(new Extent(0, 20, 0, 10));
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        var topologyModel = new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath);
        var meshModel = new GeometryMeshModelRequest(assetPath, "Geometry", projectPath);
        GeometryTopologySnapshot baseline = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(topologyModel));
        int regionFID = baseline.Regions.Rows.Single().FID;
        GeometryMeshSnapshot baselineMesh = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel,
            Revision: baseline.Revision, TopologyDraftState: baseline.DraftState,
            SelectedRegionIDs: [regionFID]));

        CheckSide(baselineMesh, baseline, regionFID, "NorthSouth");
        CheckSide(baselineMesh, baseline, regionFID, "EastWest");

        int arcFID = baseline.Arcs.Rows.First().FID;
        GeometryTopologyArcPointsSnapshot arcPoints = await ModelEditorAdapter.LoadGeometryTopologyArcPointsAsync(
            new GeometryTopologyArcPointsRequest(topologyModel, baseline.Revision, baseline.DraftState, arcFID));
        GeometryTopologyArcPoint start = arcPoints.Rows.Single(row => row.PointKind == "start");
        double movedX = start.X + 0.5;
        GeometryTopologySnapshot movedTopology = await ModelEditorAdapter.EditGeometryTopologyAsync(
            new GeometryTopologyEditRequest(topologyModel, baseline.Revision, baseline.DraftState,
                new GeometryTopologyMutation("setArcPointCoordinate", "arc", [arcFID])
                {
                    PointKind = "start",
                    EndpointNodeIndex = start.EndpointNodeIndex,
                    Axis = "X",
                    RawValue = movedX.ToString("R", CultureInfo.InvariantCulture)
                }));
        GeometryMeshSnapshot movedMesh = await ModelEditorAdapter.LoadGeometryMeshAsync(new(meshModel,
            Revision: baseline.Revision, TopologyDraftState: movedTopology.DraftState,
            SelectedRegionIDs: [regionFID]));

        Check(movedMesh.TopologyFingerprint != baselineMesh.TopologyFingerprint,
            "The side selection is recomputed against the current parent topology draft");
        CheckSide(movedMesh, movedTopology, regionFID, "NorthSouth");
        CheckSide(movedMesh, movedTopology, regionFID, "EastWest");
        GeometryTopologyMapFeature movedSourceArc = movedTopology.Map!.Features.Single(feature =>
            feature.FeatureKind == "arc" && feature.FID == arcFID);
        GeometryTopologyMapFeature movedMeshArc = movedMesh.Map!.Topology.Features.Single(feature =>
            feature.FeatureKind == "arc" && feature.FID == arcFID);
        Check(movedSourceArc.Paths.Single().SequenceEqual(movedMeshArc.Paths.Single())
            && movedMeshArc.Paths.Single().Any(point => point.X == movedX),
            "The mesh preview reuses the exact modified source arc polyline from the current topology draft");

        void CheckSide(GeometryMeshSnapshot meshSnapshot, GeometryTopologySnapshot topologySnapshot,
            int selectedFID, string axis)
        {
            GeometryMeshPatchDimension dimension = meshSnapshot.PatchSizing?.Dimensions
                .Single(item => item.ID == axis)
                ?? throw new InvalidOperationException("The Quad mesh response omitted a side dimension.");
            GeometryMeshPatchArcSelection selection = dimension.SideArcSelection
                ?? throw new InvalidOperationException("The Quad mesh response omitted side arc identities.");
            Check(selection.SourceRevision == meshSnapshot.Revision
                && selection.TopologyFingerprint == meshSnapshot.TopologyFingerprint
                && selection.Axis == axis
                && selection.SelectedRegionIDs.SequenceEqual(new[] { selectedFID })
                && selection.ArcFeatureIDs.Length > 0
                && selection.ArcFeatureIDs.Length == dimension.ArcCount
                && selection.ArcFeatureIDs.Distinct().Count() == selection.ArcFeatureIDs.Length,
                axis + " preview is bound to the exact source revision, topology, selection and source arc set");

            GeometryTopologyMapFeature[] meshArcs = meshSnapshot.Map!.Topology.Features
                .Where(feature => feature.FeatureKind == "arc"
                    && feature.FID is int fid && selection.ArcFeatureIDs.Contains(fid))
                .ToArray();
            Check(meshArcs.Length == dimension.ArcCount,
                axis + " preview references only source arc map features, without copying their geometry into the contract");
            foreach (GeometryTopologyMapFeature meshArc in meshArcs)
            {
                GeometryTopologyMapFeature sourceArc = topologySnapshot.Map!.Features.Single(feature =>
                    feature.FeatureKind == "arc" && feature.FID == meshArc.FID);
                Check(meshArc.Paths.Length == 1 && meshArc.Paths.Single().Length >= 2
                    && meshArc.Paths.Single().SequenceEqual(sourceArc.Paths.Single()),
                    axis + " preview uses the exact retained source GetArcPolyline geometry");
            }
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
