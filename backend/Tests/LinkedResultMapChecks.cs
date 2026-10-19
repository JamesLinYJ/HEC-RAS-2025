using System.Security.Cryptography;
using System.Text.Json;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Output;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

internal static class LinkedResultMapChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName);
        string candidatePath;
        Project project = new(fixture.ProjectPath);
        try
        {
            Geometry geometry = project.Geometries.Single();
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Shifted boundary",
                new DateTime(2026, 10, 16, 0, 30, 0), TimeSpan.FromHours(2));
            Plan plan = project.AddNewPlan("Shifted plan", geometry, boundary);
            boundary.Save(); plan.Save(); project.Save();
            candidatePath = Path.Combine(project.ResultsDirectory, "Shifted result.h5");
            using (Result prepared = Result.PrepareResult(candidatePath, plan, geometry, boundary, null!)) { }
            if (!Result.TryLoad(candidatePath, out Result? loaded) || loaded is null)
                throw new InvalidDataException("The linked map candidate Result fixture could not be reopened.");
            using (loaded)
            using (var output = OutputBlock.CreateNew(loaded, "Base Output"))
            {
                output.EnableWriting();
                for (int index = 0; index < 3; index++)
                {
                    var area = loaded.Geometry.FlowAreaLayer[0];
                    var state = new MeshWaterState(area.Mesh, area.PropertyTables)
                    {
                        tMicros = index * 1_800_000_000L,
                        CellElevation = [110f + index],
                        FaceVelocity = [1f, 2f, 3f, 4f]
                    };
                    output.AddTimestep(new MeshTimestep(state, index));
                }
                output.FinishWriting();
            }
        }
        finally
        {
            foreach (Result result in project.Results) result.Dispose();
            foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                .Concat(project.BoundaryConditions).Concat(project.Terrains).Concat(project.NValues)
                .Concat(project.ClassificationLayers)) layer.Dispose();
        }

        string xml = File.ReadAllText(fixture.ProjectPath);
        ResultPlanContextSnapshot context = ResultPlanContextService.Inspect(fixture.ProjectPath,
            xml, fixture.ResultPath, Hash(fixture.ResultPath));
        ResultPlanCandidate anchor = context.Anchor;
        ResultPlanCandidateGroup group = context.CandidateGroups.Single(item => item.PlanName == "Shifted plan");
        RasterMapViewExtent viewport = new(0, 0, 1, 1, 32, 32);
        LinkedResultMapRequest request = new(fixture.ProjectPath, xml, context.ProjectRevision,
            anchor, [group], 1, "Depth", "Profile", viewport);
        var before = Directory.GetFiles(directory.FullName, "*", SearchOption.AllDirectories)
            .ToDictionary(path => path, Hash, StringComparer.Ordinal);

        LinkedResultMapSnapshot profile = LinkedResultMapService.Render(request);
        Check(profile.Sources.Length == 2 && profile.Layers.Length == 2,
            "One exact matched timeline frame renders every linked Result into one map group.");
        Check(profile.Layers.All(layer => layer.Width == viewport.PixelWidth &&
                layer.Height == viewport.PixelHeight && layer.Rgba.Length == viewport.PixelWidth * viewport.PixelHeight * 4) &&
              profile.Layers.Select(layer => (layer.MinX, layer.MinY, layer.MaxX, layer.MaxY,
                  layer.Width, layer.Height)).Distinct().Count() == 1,
            "All source-backed map layers use the exact same viewport and raster dimensions.");
        Check(profile.Layers.Select(layer => layer.ProfileIndex).Order().SequenceEqual([0, 1]) &&
              profile.Layers.Select(layer => layer.Time).Distinct(StringComparer.Ordinal).Count() == 1,
            "The linked map uses the anchor timeline and each Result's retained 10 ms match.");
        Check(!profile.Layers[0].Rgba.SequenceEqual(profile.Layers[1].Rgba),
            "Different stored Result values produce distinct retained CPU-resampled map images.");
        Check(!profile.MinimumAvailable && !profile.MaximumAvailable,
            "Modern OutputBlock sources do not advertise unsupported Min or Maximum summary frames.");

        LinkedResultMapSnapshot minimum = LinkedResultMapService.Render(request with { FrameMode = "Minimum" });
        LinkedResultMapSnapshot maximum = LinkedResultMapService.Render(request with { FrameMode = "Maximum" });
        Check(minimum.Layers.Length == 0 && minimum.UnavailableReason == "minimumUnavailable" && !minimum.MinimumAvailable,
            "The unsupported source Min sentinel is explicit and never falls back to a regular frame.");
        Check(maximum.Layers.Length == 0 && maximum.UnavailableReason == "maximumUnavailable" && !maximum.MaximumAvailable,
            "Maximum is disabled unless every selected source has the actual retained summary datasets.");
        Expect<SourceFileChangedException>(() => LinkedResultMapService.Render(request with
        {
            ProjectRevision = new string('0', 64)
        }));
        Check(before.All(pair => Hash(pair.Key) == pair.Value) &&
              before.Count == Directory.GetFiles(directory.FullName, "*", SearchOption.AllDirectories).Length,
            "Rendering every linked frame leaves project, Result, terrain and visualization source files unchanged.");

        ExportIfRequested(directory.FullName, fixture.ProjectPath, fixture.ResultPath, candidatePath);
        Console.WriteLine("Linked Result maps use real matched HDF frames, a shared retained CPU raster viewport, source-backed Max capability checks, and unchanged project sources.");
    }

    private static void ExportIfRequested(string source, string project, string anchor, string candidate)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_LINKED_RESULT_MAP_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string fullSource = Path.GetFullPath(source);
        if (Directory.Exists(target) || File.Exists(target) ||
            target.StartsWith(fullSource + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The linked-result map acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(file, copy);
        }
        File.WriteAllText(Path.Combine(target, "LINKED_RESULT_MAP_FIXTURE.json"),
            JsonSerializer.Serialize(new
            {
                project = Path.GetRelativePath(source, project),
                anchor = Path.GetRelativePath(source, anchor),
                candidate = Path.GetRelativePath(source, candidate),
                candidatePlan = "Shifted plan",
                profileIndex = 1,
                mapType = "Depth",
                provenance = "Retained Result.PrepareResult and OutputBlock writers; deterministic stored test data, not solver output."
            }));
    }

    private static string Hash(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
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
}
