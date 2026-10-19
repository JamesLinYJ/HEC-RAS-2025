using System.Security.Cryptography;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using Geospatial.Rasters;
using H5Assist;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Output;
using Utility.Units;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

/// <summary>
/// Builds explicit HDF result fixtures from retained HEC-RAS writers. The
/// multi-mesh arrays below are test data written with the source H5Writer; they
/// are not presented as computed hydraulic output.
/// </summary>
internal static class ResultProfileChecks
{
    private static readonly DateTime Start = new(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc);

    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        CheckSingleMeshOutputBlockWriter(directory.FullName);
        CheckMultiMeshStoredDatasets(directory.FullName);
        Console.WriteLine("Read-only Result profile HDF, real OutputBlock writer, two-mesh indexing, unit and source-revision checks passed.");
    }

    private static void CheckSingleMeshOutputBlockWriter(string root)
    {
        var models = CreateModels(root, "Single profile writer", UnitSystem.USCustomary,
            [("Single Cell", CreateMesh(cellCount: 1), 100f)]);
        try
        {
            string resultPath = models.Project.GetUniqueResultFilename(models.Plan.Name);
            using (Result prepared = Result.PrepareResult(resultPath, models.Plan, models.Geometry, models.Boundary, null!))
                Check(File.Exists(resultPath), "Prepare the source Result HDF before writing profiles.");

            string original = HashFile(resultPath);
            var emptyCatalog = ResultProfileService.Catalog(new(resultPath, original));
            Check(emptyCatalog.OutputBlocks.Length == 0 && emptyCatalog.FlowAreas.Single() is { CellCount: 1, FaceCount: 4 },
                "An uncomputed result reports its embedded mesh but does not expose an empty synthetic output block.");
            var emptyMap = ResultProfileService.Map(new(resultPath, original, 0, "Cell"));
            Check(emptyMap.Available && emptyMap.IsComplete && emptyMap.TotalElements == 1
                && emptyMap.Elements.Single().ElementIndex == 0,
                "The read-only map picker uses the embedded Result mesh even when the result has no stored profiles.");
            var emptySeries = ResultProfileService.Read(new(resultPath, original, "Base Output", "Cell Depth", 0, 0));
            Check(!emptySeries.Available && emptySeries.Points.Length == 0,
                "The prepared result without stored profiles returns unavailable and no fabricated points.");
            Check(HashFile(resultPath) == original, "Cataloging and reading an uncomputed result leaves its HDF byte-identical.");

            if (!Result.TryLoad(resultPath, out Result? loaded) || loaded is null)
                throw new InvalidDataException("Could not reopen the prepared source Result for OutputBlock writing.");
            using (loaded)
            using (var output = OutputBlock.CreateNew(loaded, "Base Output"))
            {
                output.EnableWriting();
                double[][] stageByProfile = [[102.75], [103.5], [104.25]];
                double[][] velocityByProfile =
                [
                    [0.25, -0.5, 1.25, -2.0],
                    [1.5, 0.0, -1.25, 4.0],
                    [-0.75, 2.5, 0.125, -3.0]
                ];
                for (int profile = 0; profile < stageByProfile.Length; profile++)
                {
                    FlowArea area = loaded.Geometry.FlowAreaLayer[0];
                    var state = new MeshWaterState(area.Mesh, area.PropertyTables)
                    {
                        tMicros = profile * 1_800_000_000L,
                        CellElevation = stageByProfile[profile],
                        FaceVelocity = velocityByProfile[profile]
                    };
                    output.AddTimestep(new MeshTimestep(state, profile));
                }
                output.FinishWriting();
            }

            string revision = HashFile(resultPath);
            var catalog = ResultProfileService.Catalog(new(resultPath, revision));
            var block = catalog.OutputBlocks.Single(item => item.Name == "Base Output");
            Check(block.ProfileCount == 3 && block.Times.Length == 3 && block.ProfileNames.Length == 3,
                "OutputBlock's retained writer publishes all real stored profile names and timestamps.");
            Check(catalog.FlowAreas.Single() is { Name: "Single Cell", CellCount: 1, FaceCount: 4 },
                "The profile catalog uses the Result's embedded mesh dimensions.");
            Check(block.Variables.Single(item => item.Id == "Cell Depth") is { Quantity: "Length", Units: "ft" }
                && block.Variables.Single(item => item.Id == "Face Velocity") is { Quantity: "Velocity", Units: "ft/s" },
                "Profile variable dimensions and unit labels come from the embedded US customary Result units.");

            var cellMap = ResultProfileService.Map(new(resultPath, revision, 0, "Cell"));
            Check(cellMap.Available && cellMap.IsComplete && !cellMap.RequiresZoom
                && cellMap.TotalElements == 1 && cellMap.IntersectingElements == 1
                && cellMap.Elements.Single().ElementIndex == 0
                && cellMap.Elements.Single().Paths.Single().Length == 5
                && cellMap.Elements.Single().Paths.Single().First() == cellMap.Elements.Single().Paths.Single().Last(),
                "The source mesh picker returns its exact embedded cell polygon with the HDF mesh-local index.");
            var faceMap = ResultProfileService.Map(new(resultPath, revision, 0, "Face"));
            Check(faceMap.Available && faceMap.IsComplete && faceMap.TotalElements == 4
                && faceMap.Elements.Count(element => element.ElementIndex == 2) == 1
                && faceMap.Elements.Single(element => element.ElementIndex == 2).Paths.Single().Length == 2,
                "The face picker returns the source face polyline and its exact HDF face ordinal.");
            var sourceVertices = models.Geometry.FlowAreaLayer[0].Mesh.CellPolygon(0).Points
                .Select(point => (point.X, point.Y)).ToHashSet();
            Check(cellMap.Elements.Single().Paths.Single().Select(point => (point.X, point.Y)).ToHashSet()
                    .SetEquals(sourceVertices),
                "Map coordinates come from the embedded Result geometry rather than the current project mesh.");
            var mappedCell = cellMap.Elements.Single();
            var depth = ResultProfileService.Read(new(resultPath, revision, "Base Output", "Cell Depth", 0,
                mappedCell.ElementIndex));
            Check(depth.Available && depth.Quantity == "Length" && depth.Units == "ft"
                && depth.Points.Select(point => point.Value).SequenceEqual(new double?[] { 2.75, 3.5, 4.25 }),
                "Selecting the mapped source cell reads its actual OutputBlock.AddTimestep depth rows.");
            var mappedFace = faceMap.Elements.Single(element => element.ElementIndex == 2);
            var velocity = ResultProfileService.Read(new(resultPath, revision, "Base Output", "Face Velocity", 0,
                mappedFace.ElementIndex));
            Check(velocity.Available && velocity.Quantity == "Velocity" && velocity.Units == "ft/s"
                && velocity.Points.Select(point => point.Value).SequenceEqual(new double?[] { 1.25, -1.25, 0.125 }),
                "ReadColumn returns the selected actual face velocity from each OutputBlock profile.");
            Check(HashFile(resultPath) == revision, "Profile catalog and series reads never mutate the source HDF result.");

            ExportForSwiftIfRequested(resultPath);
        }
        finally { DisposeProject(models.Project); }
    }

    private static void CheckMultiMeshStoredDatasets(string root)
    {
        var models = CreateModels(root, "Multi mesh profile fixture", UnitSystem.SI,
        [
            ("Small Mesh", CreateMesh(cellCount: 1), 100f),
            ("Large Mesh", CreateMesh(cellCount: 2), 200f)
        ]);
        try
        {
            string resultPath = models.Project.GetUniqueResultFilename(models.Plan.Name);
            using (Result prepared = Result.PrepareResult(resultPath, models.Plan, models.Geometry, models.Boundary, null!))
                Check(File.Exists(resultPath), "Prepare the embedded two-mesh source Result HDF.");

            DateTime[] times = [Start, Start.AddMinutes(30), Start.AddHours(1)];
            using (var writer = new H5Writer(resultPath))
            {
                WriteProfileBlock(writer, "Base Output", times);
                Write2D(writer, "Base Output", "Small Mesh", "Cell Depth",
                    new float[,] { { 1.5f }, { 2.5f }, { 3.5f } });
                Write2D(writer, "Base Output", "Small Mesh", "Face Velocity",
                    new float[,] { { 0.5f, -1f, 3.5f, 4f }, { 1f, -2f, -1f, 5f }, { 1.5f, 2f, 0.5f, 6f } });
                Write2D(writer, "Base Output", "Large Mesh", "Cell Depth",
                    new float[,] { { 10f, 20f }, { 11f, 21f }, { 12f, 22f } });
                // Deliberately malformed test data: source face count is seven,
                // but this stored test dataset has eight columns.
                Write2D(writer, "Base Output", "Large Mesh", "Face Velocity",
                    new float[,] { { 1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f }, { 2f, 3f, 4f, 5f, 6f, 7f, 8f, 9f }, { 3f, 4f, 5f, 6f, 7f, 8f, 9f, 10f } });

                WriteProfileBlock(writer, "Cells Only", times);
                Write2D(writer, "Cells Only", "Small Mesh", "Cell Depth",
                    new float[,] { { 1.5f }, { 2.5f }, { 3.5f } });
                Write2D(writer, "Cells Only", "Large Mesh", "Cell Depth",
                    new float[,] { { 10f, 20f }, { 11f, 21f }, { 12f, 22f } });
            }

            string revision = HashFile(resultPath);
            var catalog = ResultProfileService.Catalog(new(resultPath, revision));
            Check(catalog.FlowAreas.Select(area => (area.Index, area.Name, area.CellCount, area.FaceCount)).SequenceEqual(
                    new[] { (0, "Small Mesh", 1, 4), (1, "Large Mesh", 2, 7) }),
                "The catalog preserves flow-area source indices and each embedded cell/face dimension.");
            var oversized = ResultProfileService.Map(new(resultPath, revision, 1, "Cell", Limit: 1));
            Check(oversized.TotalElements == 2 && oversized.ReturnedElements == 0
                && oversized.Elements.Length == 0 && oversized.IntersectingElements is null
                && !oversized.IsComplete && oversized.RequiresZoom && oversized.ElementLimit == 1,
                "An oversized map extent reports the mesh count and limit without returning a selectable partial set.");
            var zoomed = ResultProfileService.Map(new(resultPath, revision, 1, "Cell",
                new GeometryTopologyExtent(0, 0, 0.9, 1), Limit: 1));
            Check(zoomed.IsComplete && !zoomed.RequiresZoom && zoomed.IntersectingElements == 1
                && zoomed.Elements.Single().ElementIndex == 0,
                "A zoomed viewport returns a complete exact subset using source cell IDs.");
            var largeCell = ResultProfileService.Read(new(resultPath, revision, "Base Output", "Cell Depth", 1, 1));
            Check(largeCell.Available && largeCell.Units == "m"
                && largeCell.Points.Select(point => point.Value).SequenceEqual(new double?[] { 20, 21, 22 }),
                "The actual HDF column reader selects a nonzero cell in a different-sized embedded flow area.");
            var smallFace = ResultProfileService.Read(new(resultPath, revision, "Base Output", "Face Velocity", 0, 2));
            Check(smallFace.Available && smallFace.Units == "m/s"
                && smallFace.Points.Select(point => point.Value).SequenceEqual(new double?[] { 3.5, -1, 0.5 }),
                "The actual HDF column reader uses the selected mesh face count and values.");

            Expect<InvalidDataException>(() => ResultProfileService.Read(
                new(resultPath, revision, "Base Output", "Face Velocity", 1, 0)));
            var missing = ResultProfileService.Read(new(resultPath, revision, "Cells Only", "Face Velocity", 0, 0));
            Check(!missing.Available && missing.Units == "m/s" && missing.Points.Length == 0
                && missing.UnavailableReason?.Contains("no stored values", StringComparison.Ordinal) == true,
                "An absent HDF variable is an explicit unavailable response with no fabricated series or points.");

            byte[] original = File.ReadAllBytes(resultPath);
            File.AppendAllText(resultPath, "stale revision marker");
            Expect<SourceFileChangedException>(() => ResultProfileService.Read(
                new(resultPath, revision, "Base Output", "Cell Depth", 1, 1)));
            Expect<SourceFileChangedException>(() => ResultProfileService.Map(
                new(resultPath, revision, 1, "Cell")));
            File.WriteAllBytes(resultPath, original);
            Expect<FileNotFoundException>(() => ResultProfileService.Catalog(
                new(Path.Combine(root, "missing-result.hdf"), revision)));
            Expect<FileNotFoundException>(() => ResultProfileService.Map(
                new(Path.Combine(root, "missing-result.hdf"), revision, 0, "Cell")));
            Check(HashFile(resultPath) == revision,
                "Stale SHA rejection and missing-file handling do not alter the source result bytes.");
        }
        finally { DisposeProject(models.Project); }
    }

    private static TestModels CreateModels(string root, string name, UnitSystem units,
        (string Name, Mesh Mesh, float MinimumElevation)[] meshes)
    {
        string projectPath = Path.Combine(root, name + ".ras");
        Project project = Project.CreateNew(projectPath, units);
        Geometry geometry = project.AddNewGeometry(name + " Geometry");
        foreach (var item in meshes)
        {
            var elevations = new ConstantValueResampler<float>(item.MinimumElevation, Extent.Infinite, -9999f);
            var roughness = new ConstantValueResampler<float>(0.03f, Extent.Infinite, -9999f);
            var computed = MeshPropertyTables.ComputeFrom(item.Mesh, elevations, roughness,
                PropertyTableOptions.Default(units), out MeshPropertyTables tables);
            Check(computed.Result, "The retained property-table builder prepares complete flat-terrain fixture tables.");
            geometry.FlowAreaLayer.Add(new FlowArea(item.Mesh, item.Name) { PropertyTables = tables });
        }
        geometry.Save();
        BoundaryCondition boundary = project.AddNewBoundaryCondition(name + " Boundary", Start, TimeSpan.FromHours(2));
        Plan plan = project.AddNewPlan(name + " Plan", geometry, boundary);
        project.Save();
        return new TestModels(project, geometry, boundary, plan);
    }

    private static void WriteProfileBlock(H5Writer writer, string blockName, IList<DateTime> times) =>
        OutputBlock.WriteTimestepsHowYouExpectToReadThem(writer, blockName, times);

    private static void Write2D(H5Writer writer, string blockName, string meshName, string variable, float[,] values) =>
        writer.WriteDataset(OutputBlock.RootMeshOutputPath(blockName, meshName) + variable, values);

    private static Mesh CreateMesh(int cellCount)
    {
        Point[] points = cellCount == 1
            ? [new(0, 0), new(1, 0), new(1, 1), new(0, 1)]
            : [new(0, 0), new(1, 0), new(2, 0), new(0, 1), new(1, 1), new(2, 1)];
        if (cellCount == 1)
        {
            Face[] faces = Enumerable.Range(0, 4)
                .Select(index => new Face { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
            FacePoint[] nodes = points.Select((point, index) => new FacePoint(point)
                { Faces = [(index + 3) % 4, index] }).ToArray();
            return new Mesh(new Polygon(points), [new Cell { Faces = new int[] { 0, 1, 2, 3 } }], faces, nodes,
                [new Point(0.5, 0.5)], null!);
        }

        Face[] twoCellFaces =
        [
            new() { fpA = 0, fpB = 1, cellA = 0, cellB = -1 },
            new() { fpA = 1, fpB = 4, cellA = 0, cellB = 1 },
            new() { fpA = 4, fpB = 3, cellA = 0, cellB = -1 },
            new() { fpA = 3, fpB = 0, cellA = 0, cellB = -1 },
            new() { fpA = 1, fpB = 2, cellA = 1, cellB = -1 },
            new() { fpA = 2, fpB = 5, cellA = 1, cellB = -1 },
            new() { fpA = 5, fpB = 4, cellA = 1, cellB = -1 }
        ];
        FacePoint[] twoCellNodes =
        [
            new(points[0]) { Faces = [0, 3] }, new(points[1]) { Faces = [0, 1, 4] },
            new(points[2]) { Faces = [4, 5] }, new(points[3]) { Faces = [2, 3] },
            new(points[4]) { Faces = [1, 2, 6] }, new(points[5]) { Faces = [5, 6] }
        ];
        return new Mesh(new Polygon(new Point[] { points[0], points[1], points[2], points[5], points[4], points[3] }),
            [new Cell { Faces = new int[] { 0, 1, 2, 3 } }, new Cell { Faces = new int[] { 1, 4, 5, 6 } }],
            twoCellFaces, twoCellNodes, [new Point(0.5, 0.5), new Point(1.5, 0.5)], null!);
    }

    private static void ExportForSwiftIfRequested(string resultPath)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_RESULT_PROFILE_ACCEPTANCE_RESULT");
        if (string.IsNullOrWhiteSpace(destination)) return;
        destination = Path.GetFullPath(destination);
        if (File.Exists(destination) || Directory.Exists(destination))
            throw new IOException("The Result profile acceptance fixture destination already exists.");
        string parent = Path.GetDirectoryName(destination) ?? throw new IOException("The fixture destination has no parent directory.");
        Directory.CreateDirectory(parent);
        File.Copy(resultPath, destination);
    }

    private static string HashFile(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static void DisposeProject(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                     .Concat(project.Geometries).Concat(project.Terrains)
                     .Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
    }

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

    private sealed record TestModels(Project Project, Geometry Geometry, BoundaryCondition Boundary, Plan Plan);
}
