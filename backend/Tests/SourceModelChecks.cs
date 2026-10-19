using Geospatial.IO.Vectors;
using Geospatial.PairedData;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using H5Assist;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Hydraulics.CrossSections;
using Ras.Layers;
using Ras.Layers.Terrains;
using Ras.Observables.Layers;
using Ras.Output;

internal static class SourceModelChecks
{
    internal static void Run()
    {
        var banks = new BankProperties();
        long version = banks.AttributeVersion;
        banks.LeftStation = 3;
        banks.CenterStation = 4;
        banks.RightStation = 5;
        Check(banks.AttributeVersion == version + 3, "Bank changes invalidate attribute version");
        banks.RightStation = 5;
        Check(banks.AttributeVersion == version + 3, "Unchanged banks retain their version");

        Mesh mesh = CreateMesh();
        mesh.SetFaceCentroidStations(new float[] { .2f, .3f, .4f, .5f });
        using var directory = new TemporaryDirectory();
        string filename = Path.Combine(directory.FullName, "网格.hdf");
        using (var writer = new H5Writer(filename)) Check(MeshReader.Write(mesh, writer, "/Mesh"), "Write actual HEC mesh schema");
        using (var reader = new H5Reader(filename))
        {
            Check(MeshReader.Read(reader, "/Mesh", out Mesh loaded), "Read actual HEC mesh schema");
            Check(loaded.FaceCount == 4 && loaded.CellCount == 1 && loaded.FaceCentroidStations.Span.SequenceEqual(mesh.FaceCentroidStations.Span), "Mesh geometry and low elevation centroids survive HDF roundtrip");
        }

        var tables = MeshPropertyTables.CreateEmpty(mesh);
        tables.CellMinimumElevations = new float[] { 100 };
        var water = new MeshWaterState(mesh, tables) { CellElevation = new double[] { 102.75 }, FaceVelocity = new double[] { .5, -1, 2, 3 } };
        var timestep = new MeshTimestep(water, 1L);
        using var geometry = Geometry.CreateInMemory("Computed snapshot check");
        geometry.FlowAreaLayer.Add(new FlowArea(mesh, "Mesh") { PropertyTables = tables });
        var block = new ComputedTimestepOutputBlock(geometry, new[] { timestep }, tables, new[] { new DateTime(2000, 1, 1) });
        float[] depth = new float[1], velocity = new float[4];
        Check(block.TryReadPerMesh(OutputVariables.Depth, 0, new Memory<float>[] { depth }) && depth[0] == 2.75f, "Computed output converts actual water stage to source mesh depth");
        Check(block.TryReadPerMesh(OutputVariables.Velocity, 0, new Memory<float>[] { velocity }) && velocity.SequenceEqual(new float[] { .5f, -1, 2, 3 }), "Computed output retains face velocity and direction");

        var profile = new ObservableChannelProfile(new ChannelProfile { Name = "河道", Profile = new StationElevationProfile(new double[] { 0, 10 }, new double[] { 1, 2 }) });
        int changes = 0;
        profile.DataChanged += changed => { Check(ReferenceEquals(changed, profile), "Profile event identifies the actual source"); changes++; };
        profile.Name = "河道二";
        profile.Name = "河道二";
        Check(changes == 1, "Profile mutations notify once and unchanged assignments remain quiet");
        Console.WriteLine("HEC mesh HDF, bank version, computed output and source profile checks passed.");
    }

    private static Mesh CreateMesh()
    {
        Point[] points = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)];
        Face[] faces = Enumerable.Range(0, 4).Select(i => new Face { fpA = i, fpB = (i + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point) { Faces = new int[] { (index + 3) % 4, index } }).ToArray();
        return new Mesh(new Polygon(points), new Cell[] { new() { Faces = new int[] { 0, 1, 2, 3 } } }, faces, nodes, new Point[] { new(.5, .5) }, null!);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
