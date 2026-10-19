using Geospatial.Vectors;
using Geospatial.Vectors.Topology;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class GeometryTopologyRenderInputChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Topology render inputs.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var geometry = project.AddNewGeometry("Topology render input geometry");
        Topology sourceTopology = Topology.FromExtent(new Extent(0, 20, 0, 20));
        geometry.ConceptualMeshLayer.Topology = sourceTopology;
        string assetPath = geometry.Filename;
        project.Save();
        geometry.Save();
        geometry.Dispose();

        byte[] projectBefore = File.ReadAllBytes(projectPath);
        byte[] sourceBefore = File.ReadAllBytes(assetPath);
        GeometryTopologySnapshot snapshot = await ModelEditorAdapter.LoadGeometryTopologyAsync(new(
            new GeometryTopologyModelRequest(assetPath, "Geometry", projectPath)));
        GeometryTopologyMap map = snapshot.Map
            ?? throw new InvalidOperationException("Topology reader omitted its source map.");
        GeometryTopologyMapFeature[] nodes = map.Features
            .Where(feature => feature.FeatureKind == "node" && feature.GeometryType == "point")
            .ToArray();

        Check(nodes.Length == sourceTopology.NodeCount,
            "Node render inputs cover each source topology node");
        foreach (GeometryTopologyMapFeature feature in nodes)
        {
            int fid = feature.FID
                ?? throw new InvalidOperationException("Source node render input omitted its FID.");
            Node sourceNode = sourceTopology.Nodes[fid];
            GeometryTopologyIncidentArc[] expected = sourceNode.Arcs
                .Select(connection => new GeometryTopologyIncidentArc(connection.ArcID,
                    sourceTopology.GetArcPolyline(connection.ArcID).Length))
                .ToArray();
            Check(feature.IncidentArcs is not null && feature.IncidentArcs.SequenceEqual(expected),
                $"Node {fid} render inputs preserve source incident arc order, IDs, and polyline lengths");
        }
        Check(nodes.Any(feature => feature.IncidentArcs is { Length: 2 } arcs
                && arcs[0].ArcID != arcs[1].ArcID),
            "Node render inputs preserve the source exactly-two-distinct-arcs color predicate");

        Check(map.Features.Where(feature => feature.FeatureKind != "node")
                .All(feature => feature.IncidentArcs is null),
            "Non-node map features do not receive invented incident-arc relationships");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBefore)
            && File.ReadAllBytes(assetPath).SequenceEqual(sourceBefore),
            "Reading node render inputs leaves the project and geometry source unchanged");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
