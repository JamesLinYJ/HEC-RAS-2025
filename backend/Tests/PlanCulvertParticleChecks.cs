using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Engine;
using Ras.Engine.Structures.Culverts;
using Ras.Hydraulics;
using Ras.Hydraulics.Culverts;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Ras.Layers.Payloads;
using Ras.Layers.Terrains;
using Ras.Output;
using Utility.Units;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

/// <summary>
/// Builds persisted culvert output by running the retained CPU Plan solver.
/// The acceptance copy is source output, never a manually populated HDF.
/// </summary>
internal static class PlanCulvertParticleChecks
{
    private static readonly DateTime Start = new(2026, 10, 17, 0, 0, 0, DateTimeKind.Local);
    private const string ProjectName = "Culvert Particle Acceptance.ras";
    private const string PlanName = "Culvert Particle CPU";
    private const string SharedPlanName = "Culvert Particle Shared Plan";
    private const string AlternatePlanName = "Culvert Particle Alternate Plan";
    private const string GeometryName = "Culvert Particle Geometry";
    private const string AlternateGeometryName = "Culvert Particle Alternate Geometry";
    private const string BoundaryName = "Culvert Particle Boundary";
    private static readonly string[] BarrelNames = ["West-to-east barrel", "East-to-west barrel"];

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        VerifyPersistedInitialStageAndBoundaryMesh(fixture);
        byte[] projectBeforeFirstRun = File.ReadAllBytes(fixture.ProjectPath);
        byte[] planBeforeFirstRun = File.ReadAllBytes(fixture.PlanPath);

        PlanComputeExecutionResult signed = await ExecuteSourceCompute(fixture);
        Check(signed.ResultPath is { Length: > 0 } && signed.ResultRevision == Hash(signed.ResultPath),
            "The first CPU solver run retains its exact Result HDF identity.");
        Check(signed.State == "completed" && signed.Summary is { Success: true },
            "The retained CPU Plan solver completes the signed-flow fixture. " + JsonSerializer.Serialize(signed));
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBeforeFirstRun)
            && File.ReadAllBytes(fixture.PlanPath).SequenceEqual(planBeforeFirstRun),
            "Running the retained compute workflow does not save the Project XML or Plan HDF.");

        ResultCapture signedResult = ReadComputedResult(fixture.Root, signed.ResultPath!, signed.ResultRevision!, "signed-flow");
        Check(signedResult.Profiles.Any(profile => HasOppositeSignedFlows(profile.Flow)),
            "Real source timesteps preserve signed direction for the two oppositely oriented source barrels. "
                + JsonSerializer.Serialize(signedResult.Profiles.Select(profile => profile.Flow)));

        byte[] signedResultBytes = File.ReadAllBytes(signed.ResultPath!);
        SetZeroFlowBoundaryAndLaterPlanWindow(fixture);
        byte[] projectBeforeSecondRun = File.ReadAllBytes(fixture.ProjectPath);
        byte[] planBeforeSecondRun = File.ReadAllBytes(fixture.PlanPath);

        PlanComputeExecutionResult zero = await ExecuteSourceCompute(fixture);
        Check(zero.ResultPath is { Length: > 0 } && zero.ResultRevision == Hash(zero.ResultPath),
            "A second source run retains a distinct Result HDF identity.");
        Check(zero.State == "completed" && zero.Summary is { Success: true },
            "The retained CPU Plan solver completes the zero-flow fixture. " + JsonSerializer.Serialize(zero));
        Check(!SameSourceFile(signed.ResultPath!, zero.ResultPath!),
            "Rerunning the same source Plan creates a second retained Result instead of replacing its previous Result.");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBeforeSecondRun)
            && File.ReadAllBytes(fixture.PlanPath).SequenceEqual(planBeforeSecondRun),
            "The second compute operation also leaves its Project XML and Plan HDF unchanged.");
        Check(File.ReadAllBytes(signed.ResultPath!).SequenceEqual(signedResultBytes),
            "A subsequent source Plan run does not rewrite the earlier Result HDF.");

        ResultCapture zeroResult = ReadComputedResult(fixture.Root, zero.ResultPath!, zero.ResultRevision!, "zero-flow");
        Check(zeroResult.Profiles.Any(profile => profile.Flow.All(value => Math.Abs(value) <= 0.001f)),
            "The retained zero-flow run stores a real timestep below the source particle zero-flow threshold.");

        var manifest = new AcceptanceManifest(
            ProjectRelativePath: Relative(fixture.Root, fixture.ProjectPath),
            PlanRelativePath: Relative(fixture.Root, fixture.PlanPath),
            GeometryRelativePath: Relative(fixture.Root, fixture.GeometryPath),
            SharedPlanRelativePath: Relative(fixture.Root, fixture.SharedPlanPath),
            AlternatePlanRelativePath: Relative(fixture.Root, fixture.AlternatePlanPath),
            AlternateGeometryRelativePath: Relative(fixture.Root, fixture.AlternateGeometryPath),
            BoundaryConditionRelativePath: Relative(fixture.Root, fixture.BoundaryPath),
            TerrainRasterRelativePath: Relative(fixture.Root, fixture.TerrainPath),
            PlanName: PlanName,
            SharedPlanName: SharedPlanName,
            AlternatePlanName: AlternatePlanName,
            GeometryName: GeometryName,
            AlternateGeometryName: AlternateGeometryName,
            BoundaryConditionName: BoundaryName,
            BarrelNames: BarrelNames,
            Results: [signedResult, zeroResult]);
        File.WriteAllText(Path.Combine(fixture.Root, "acceptance.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions(JsonSerializerDefaults.Web)
            {
                WriteIndented = true
            }));
        ExportFixtureIfRequested(fixture.Root);

        Console.WriteLine("Retained CPU Plan solve persisted two exact Result HDFs with source-order culvert outputs, opposite signed barrel flow, a zero-flow timestep, and unchanged Project/Plan files.");
    }

    private static Fixture CreateFixture(string root)
    {
        root = CanonicalTemporaryPath(new DirectoryInfo(root));
        string projectPath = Path.Combine(root, ProjectName);
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        try
        {
            Terrain terrain = project.AddNewTerrain("Culvert Particle Terrain");
            string terrainPath = Path.Combine(terrain.SourceDirectory, "flat.tif");
            Directory.CreateDirectory(terrain.SourceDirectory);
            using (var driver = Gdal.GetDriverByName("GTiff"))
            using (var raster = driver.Create(terrainPath, 32, 32, 1, DataType.GDT_Float32,
                ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
            {
                // Pad every mesh face so retained terrain sampling never touches
                // the raster's exclusive outer edge at y=0 or x=0.
                raster.SetGeoTransform([-8, 1, 0, 24, 0, -1]);
                using var band = raster.GetRasterBand(1);
                band.Fill(42, 0);
            }
            terrain.Add(RasterTerrainInput.CreateAndScan(terrain, terrainPath));

            NValueLayer roughness = project.AddNewNValueLayer("Culvert Particle Roughness");
            roughness.SetConstant(0.03f);
            Geometry geometry = project.AddNewGeometry(GeometryName, terrain, roughness);
            geometry.FlowAreaLayer.Add(new FlowArea(CreateTwoCellMesh(), "Two cell solver mesh"));
            geometry.BarrelPropertiesLayer.Add(new BarrelProperties
            {
                Name = "Round solver barrel",
                Rise = 0.6,
                Span = 0.6,
                Shape = BarrelShape.Circle,
                Mannings = 0.025,
                ManningsSwitchDepth = 0.1,
                DepthBlocked = 0
            });
            geometry.OpeningPropertiesLayer.Add(new OpeningProperties
            {
                Name = "Solver square edge",
                KIn = 0.5,
                KOut = 0.8,
                OpeningType = BarrelOpeningType.ConcretePipeCulvert_SquareEdgeWithHeadwall
            });
            geometry.CulvertBarrelLayer.Add(new CulvertBarrel
            {
                Name = BarrelNames[0],
                Polyline = new Polyline(new Point[] { new(0.25, 0.5), new(1.75, 0.5) }),
                BarrelPropertyName = "Round solver barrel",
                UpstreamInvert = 42.1,
                DownstreamInvert = 42.1,
                UpstreamOpeningName = "Solver square edge",
                DownstreamOpeningName = ""
            });
            geometry.CulvertBarrelLayer.Add(new CulvertBarrel
            {
                Name = BarrelNames[1],
                Polyline = new Polyline(new Point[] { new(1.75, 0.25), new(0.25, 0.25) }),
                BarrelPropertyName = "Round solver barrel",
                UpstreamInvert = 42.1,
                DownstreamInvert = 42.1,
                UpstreamOpeningName = "Solver square edge",
                DownstreamOpeningName = ""
            });

            BoundaryCondition boundary = project.AddNewBoundaryCondition(BoundaryName, Start, TimeSpan.FromHours(2));
            boundary.InitialConditions.Stage.SetConstantValue(43f);
            boundary.BoundaryConditionLines.Add(BoundaryConditionLine.ConstantFlow(boundary,
                new Polyline(new Point[] { new(0, 0), new(0, 1) }), 0.025));
            boundary.BoundaryConditionLines.Add(BoundaryConditionLine.ConstantStage(boundary,
                new Polyline(new Point[] { new(2, 1), new(2, 0) }), 42.9));

            Plan plan = project.AddNewPlan(PlanName, geometry, boundary);
            ConfigurePlan(plan, Start, durationSeconds: 4);

            Plan sharedPlan = project.AddNewPlan(SharedPlanName, geometry, boundary);
            ConfigurePlan(sharedPlan, Start, durationSeconds: 4);

            Geometry alternateGeometry = project.AddNewGeometry(AlternateGeometryName, terrain, roughness);
            alternateGeometry.FlowAreaLayer.Add(new FlowArea(CreateTwoCellMesh(), "Alternate two cell source mesh"));
            Plan alternatePlan = project.AddNewPlan(AlternatePlanName, alternateGeometry, boundary);
            ConfigurePlan(alternatePlan, Start, durationSeconds: 4);

            foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                .Concat(project.Geometries).Concat(project.BoundaryConditions)
                .Concat(project.Terrains).Concat(project.NValues))
                layer.Save();
            project.Save();

            return new Fixture(root, projectPath, plan.Filename, sharedPlan.Filename,
                alternatePlan.Filename, geometry.Filename, alternateGeometry.Filename,
                boundary.Filename, terrainPath);
        }
        finally { DisposeProject(project); }
    }

    private static Mesh CreateTwoCellMesh()
    {
        Point[] points =
        [
            new(0, 0), new(1, 0), new(2, 0),
            new(0, 1), new(1, 1), new(2, 1)
        ];
        Face[] faces =
        [
            new() { fpA = 0, fpB = 1, cellA = 0, cellB = -1 },
            new() { fpA = 1, fpB = 4, cellA = 0, cellB = 1 },
            new() { fpA = 4, fpB = 3, cellA = 0, cellB = -1 },
            new() { fpA = 3, fpB = 0, cellA = 0, cellB = -1 },
            new() { fpA = 1, fpB = 2, cellA = 1, cellB = -1 },
            new() { fpA = 2, fpB = 5, cellA = 1, cellB = -1 },
            new() { fpA = 5, fpB = 4, cellA = 1, cellB = -1 }
        ];
        // Mesh perimeter traversal expects each facepoint's incident faces in
        // angular order: the outgoing CCW perimeter face first, interior faces
        // next, and the incoming CCW perimeter face last.
        FacePoint[] nodes =
        [
            new(points[0]) { Faces = [0, 3] },
            new(points[1]) { Faces = [4, 1, 0] },
            new(points[2]) { Faces = [5, 4] },
            new(points[3]) { Faces = [3, 2] },
            new(points[4]) { Faces = [2, 1, 6] },
            new(points[5]) { Faces = [6, 5] }
        ];
        Polygon perimeter = new(new Point[] { points[0], points[1], points[2], points[5], points[4], points[3] });
        return new Mesh(perimeter,
            [new Cell { Faces = new int[] { 0, 1, 2, 3 } }, new Cell { Faces = new int[] { 1, 4, 5, 6 } }],
            faces, nodes, [new Point(0.5, 0.5), new Point(1.5, 0.5)], null!);
    }

    private static void VerifyPersistedInitialStageAndBoundaryMesh(Fixture fixture)
    {
        Project project = new(fixture.ProjectPath);
        try
        {
            BoundaryCondition boundary = project.BoundaryConditions.Single(item => item.Name == BoundaryName);
            InitialStageLayer stage = boundary.InitialConditions.Stage;
            Check(stage.IsEnabled && stage.SpatialDataType == SpatialDataType.Constant
                && Math.Abs(stage.ConstantValue - 43f) <= 0.0001f,
                "The saved Boundary Condition reopens with its real enabled constant Initial Stage of 43.");
            IResample<float> initialSurface = boundary.InitialWaterSurface;
            Check(initialSurface is not null
                && Math.Abs(initialSurface.SamplePoint(new Point(0.5, 0.5)) - 43f) <= 0.0001f,
                "The reloaded Initial Stage resampler actually samples 43 rather than relying on a transient setter.");

            Geometry geometry = project.Geometries.Single(item => item.Name == GeometryName);
            Mesh mesh = geometry.FlowAreaLayer[0].Mesh;
            foreach (BoundaryConditionLine boundaryLine in boundary.BoundaryConditionLines.Features.Where(line =>
                line.Payloads.Any(payload => payload.Variable is "Flow" or "Stage")))
            {
                List<ProfileFaceRange> perimeterFaces = mesh.PerimeterFacesAlongPolyline(boundaryLine.Polyline, out _);
                Check(perimeterFaces is not null && perimeterFaces.Count > 0
                    && perimeterFaces.All(range => range.Face >= 0 && range.Face < mesh.FaceCount
                        && mesh.Faces[range.Face].cellB == -1),
                    $"The reopened source mesh traverses the ordered perimeter-face ring for boundary line '{boundaryLine.Name}'.");
            }
        }
        finally { DisposeProject(project); }
    }

    private static void ConfigurePlan(Plan plan, DateTime start, double durationSeconds)
    {
        plan.TimeWindowMode = PlanTimeWindowMode.Plan;
        plan.InternalStartTime = start;
        plan.InternalComputeDurationSeconds = durationSeconds;
        plan.ComputeTimestep = TimeSpan.FromSeconds(0.1);
        plan.BaseOutputInterval = TimeSpan.FromSeconds(1);
        plan.SolverType = SolverType.CPU;
    }

    private static async Task<PlanComputeExecutionResult> ExecuteSourceCompute(Fixture fixture)
    {
        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(
            new ModelRequest(fixture.PlanPath, "Plan", fixture.ProjectPath));
        var model = new ModelSaveRequest(fixture.PlanPath, "Plan", fixture.ProjectPath,
            snapshot.Revision, new Dictionary<string, string>(), new Dictionary<string, ImageData[]>(),
            File.ReadAllText(fixture.ProjectPath), snapshot.SourceState);
        PlanComputeInspection inspection = await ModelEditorAdapter.InspectPlanComputeAsync(new(model));
        if (!inspection.CanExecute || inspection.RequiresCUDA)
            throw new InvalidOperationException("The source CPU solver fixture is not ready: "
                + string.Join("; ", inspection.Reasons.Concat(inspection.Messages.Select(message => message.EvaluatedMessage))));
        using var cancellation = CancellationDirectory.Create();
        // Preserve the source call stack when the production execution contract
        // reports only a user-facing error message. Diagnostics never change
        // the solver result or replace its completion/physical-output checks.
        var sourceFailures = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void CaptureSourceFailure(object? sender, System.Runtime.ExceptionServices.FirstChanceExceptionEventArgs args)
        {
            if (sourceFailures.Count < 64) sourceFailures.Enqueue(args.Exception.ToString());
        }
        PlanComputeExecutionResult result;
        AppDomain.CurrentDomain.FirstChanceException += CaptureSourceFailure;
        try
        {
            result = await ModelEditorAdapter.ExecutePlanComputeAsync(
                new PlanComputeExecuteRequest(model, inspection.InspectionId, cancellation.Request));
        }
        finally { AppDomain.CurrentDomain.FirstChanceException -= CaptureSourceFailure; }
        if (result.State != "completed" || result.Summary is not { Success: true })
            throw new InvalidOperationException("The retained source CPU solver did not complete: "
                + JsonSerializer.Serialize(result) + "\nSource exception stacks:\n" + string.Join("\n", sourceFailures));
        return result;
    }

    private static ResultCapture ReadComputedResult(string projectRoot, string path, string expectedRevision, string role)
    {
        Check(File.Exists(path) && Hash(path) == expectedRevision,
            $"The {role} source Result exists at its expected SHA.");
        if (!Result.TryLoad(path, out Result? result) || result is null)
            throw new InvalidDataException($"The retained {role} Result HDF could not be reopened.");
        using (result)
        {
            Check(result.ComputeSummary.Success && result.ProfileCount > 0,
                $"The {role} result reports a successful retained compute summary and real profiles.");
            Check(result.ProfileCount > 1,
                $"The {role} result provides multiple real profiles for timeline-selection acceptance.");
            Check(ReferenceEquals(result.Geometry.Result, result),
                $"The {role} result owns the exact embedded Geometry object read from its HDF.");
            string[] actualBarrelNames = result.Geometry.CulvertBarrelLayer.Features.Select(barrel => barrel.Name).ToArray();
            Check(actualBarrelNames.SequenceEqual(BarrelNames, StringComparer.Ordinal),
                $"The {role} result embeds source-ordered culvert barrel geometry.");
            if (result.BaseOutputBlock is not OutputBlock output || !output.HasCulvertOutput
                || output.CulvertBarrelCount != BarrelNames.Length || output.ProfileNames.Count != result.ProfileCount)
                throw new InvalidDataException($"The {role} result does not contain source culvert output for each embedded barrel.");

            var profiles = new List<FixtureProfile>(output.ProfileCount);
            for (int index = 0; index < output.ProfileCount; index++)
            {
                if (!output.TryReadCulvertData(index, out CulvertTimestepData? data) || data is null)
                    throw new InvalidDataException($"The {role} result's retained output block could not read culvert profile {index}.");
                Check(data.Flow.Length == BarrelNames.Length
                    && data.OutsideDepth.Length == BarrelNames.Length * 2
                    && data.OutletVelocity.Length == BarrelNames.Length,
                    $"The {role} result's three culvert arrays align by source barrel order at profile {index}.");
                Check(data.Flow.All(float.IsFinite) && data.OutsideDepth.All(float.IsFinite)
                    && data.OutletVelocity.All(float.IsFinite),
                    $"The {role} source solver stores finite culvert flow, depth and velocity values at profile {index}.");
                profiles.Add(new FixtureProfile(index, output.ProfileNames[index],
                    output.Times[index].ToString("O", CultureInfo.InvariantCulture),
                    data.Flow.ToArray(), data.OutsideDepth.ToArray(), data.OutletVelocity.ToArray()));
            }
            return new ResultCapture(role, Relative(projectRoot, path), expectedRevision,
                result.ProfileCount, output.ProfileNames.ToArray(), profiles.ToArray());
        }
    }

    private static void SetZeroFlowBoundaryAndLaterPlanWindow(Fixture fixture)
    {
        Project project = new(fixture.ProjectPath);
        try
        {
            BoundaryCondition boundary = project.BoundaryConditions.Single(item => item.Name == BoundaryName);
            BoundaryConditionLine flowLine = boundary.BoundaryConditionLines.Features.Single(line =>
                line.Payloads.Any(payload => payload.Variable == "Flow"));
            BoundaryConditionLine stageLine = boundary.BoundaryConditionLines.Features.Single(line =>
                line.Payloads.Any(payload => payload.Variable == "Stage"));
            ((ConstantPayload)flowLine.Payloads.Single(payload => payload.Variable == "Flow")).Value = 0;
            ((ConstantPayload)stageLine.Payloads.Single(payload => payload.Variable == "Stage")).Value = 43;
            boundary.Save();

            Plan plan = project.Plans.Single(item => item.Name == PlanName);
            ConfigurePlan(plan, Start.AddMinutes(1), durationSeconds: 4);
            plan.Save();
        }
        finally { DisposeProject(project); }
    }

    private static void ExportFixtureIfRequested(string sourceRoot)
    {
        string[] keys = ["HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY", "HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY"];
        string[] targets = keys.Select(key => Environment.GetEnvironmentVariable(key))
            .Where(value => !string.IsNullOrWhiteSpace(value)).Cast<string>()
            .Select(Path.GetFullPath).ToArray();
        if (targets.Length == 0) return;
        if (targets.Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal).Count() != targets.Length)
            throw new IOException("The Plan map and culvert particle acceptance directories must be separate.");

        string source = Path.GetFullPath(sourceRoot);
        foreach (string target in targets)
        {
            if (Directory.Exists(target) || File.Exists(target))
                throw new IOException("An R20 source acceptance fixture destination already exists: " + target);
            if (target.Equals(source, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)
                || target.StartsWith(source + Path.DirectorySeparatorChar,
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                throw new IOException("An R20 source acceptance fixture cannot be exported inside its temporary source directory.");
        }

        foreach (string target in targets)
        {
            Directory.CreateDirectory(target);
            foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            {
                string copy = Path.Combine(target, Path.GetRelativePath(source, file));
                Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
                File.Copy(file, copy, overwrite: false);
            }
        }
    }

    private static bool HasOppositeSignedFlows(float[] flow) => flow.Length == 2
        && Math.Abs(flow[0]) > 0.001f && Math.Abs(flow[1]) > 0.001f && flow[0] * flow[1] < 0;

    private static string CanonicalTemporaryPath(DirectoryInfo directory)
    {
        if (directory.LinkTarget is not null)
            return CanonicalTemporaryPath((DirectoryInfo)(directory.ResolveLinkTarget(returnFinalTarget: true)
                ?? throw new IOException("The temporary directory alias could not be resolved.")));
        return directory.Parent is { } parent
            ? System.IO.Path.Combine(CanonicalTemporaryPath(parent), directory.Name)
            : directory.FullName;
    }

    private static string Relative(string root, string path)
    {
        string relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
        if (Path.IsPathFullyQualified(relative) || relative == ".." || relative.StartsWith("../", StringComparison.Ordinal))
            throw new InvalidDataException("The source output must remain within its private fixture directory.");
        return relative;
    }

    private static bool SameSourceFile(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right),
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
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

    private sealed record Fixture(string Root, string ProjectPath, string PlanPath,
        string SharedPlanPath, string AlternatePlanPath, string GeometryPath,
        string AlternateGeometryPath, string BoundaryPath, string TerrainPath);

    private sealed record FixtureProfile(int Index, string Name, string Time,
        float[] Flow, float[] OutsideDepth, float[] OutletVelocity);

    private sealed record ResultCapture(string Role, string Path, string Revision,
        int ProfileCount, string[] ProfileNames, FixtureProfile[] Profiles);

    private sealed record AcceptanceManifest(string ProjectRelativePath, string PlanRelativePath,
        string SharedPlanRelativePath, string AlternatePlanRelativePath, string GeometryRelativePath,
        string AlternateGeometryRelativePath, string BoundaryConditionRelativePath, string TerrainRasterRelativePath,
        string PlanName, string SharedPlanName, string AlternatePlanName, string GeometryName,
        string AlternateGeometryName, string BoundaryConditionName, string[] BarrelNames,
        ResultCapture[] Results);

    private sealed class CancellationDirectory : IDisposable
    {
        private const string Prefix = "hecras-plan-compute-";
        public string Path { get; }
        public string Nonce { get; }
        public PlanComputeCancellation Request => new(Path, Nonce);

        private CancellationDirectory(string path, string nonce) { Path = path; Nonce = nonce; }

        public static CancellationDirectory Create()
        {
            string nonce = Guid.NewGuid().ToString("N");
            string temporaryRoot = CanonicalTemporaryPath(new DirectoryInfo(System.IO.Path.GetTempPath()));
            string directory = System.IO.Path.Combine(temporaryRoot, Prefix + nonce);
            Directory.CreateDirectory(directory);
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                string owner = System.IO.Path.Combine(directory, "owner");
                File.WriteAllText(owner, nonce);
                File.SetUnixFileMode(owner, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            else File.WriteAllText(System.IO.Path.Combine(directory, "owner"), nonce);
            return new CancellationDirectory(directory, nonce);
        }


        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
