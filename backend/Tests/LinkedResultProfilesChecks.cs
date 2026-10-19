using System.Security.Cryptography;
using System.Globalization;
using System.Text.Json;
using Geospatial.Rendering;
using Ras.Backend;
using Ras.Engine;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Output;
using BoundaryCondition = Ras.Layers.BoundaryCondition;

internal static class LinkedResultProfilesChecks
{
    internal static void Run()
    {
        CheckSourceTolerance();
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName);
        Project project = new(fixture.ProjectPath);
        string candidatePath;
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
                throw new InvalidDataException("The shifted Result fixture could not be reopened.");
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
        var before = Directory.GetFiles(directory.FullName, "*", SearchOption.AllDirectories)
            .ToDictionary(path => path, Hash);
        ResultPlanContextSnapshot context = ResultPlanContextService.Inspect(fixture.ProjectPath, xml,
            fixture.ResultPath, Hash(fixture.ResultPath));
        var anchor = new ResultPlanCandidate(context.ResultPath, context.Revision, context.AnchorName,
            context.AnchorPlanName, context.AnchorHasPlan);
        ResultPlanCandidateGroup group = context.CandidateGroups.Single(item => item.PlanName == "Shifted plan");
        LinkedResultProfilesRequest request = new(fixture.ProjectPath, xml, context.ProjectRevision, anchor, [group]);
        LinkedResultProfilesSnapshot first = LinkedResultProfilesService.Read(request);
        LinkedResultProfilesSnapshot second = LinkedResultProfilesService.Read(request with { ProfileIndex = 1 });
        LinkedResultProfilesSnapshot third = LinkedResultProfilesService.Read(request with { ProfileIndex = 2 });
        Check(first.Steps.Length == 3 && second.ProfileIndex == 1 && third.ProfileIndex == 2,
            "Linked profiles use the first selected Result's stored output timeline.");
        Check(first.Frames[0].ProfileIndex == 0 && first.Frames[1].ProfileIndex is null
            && first.Frames[1].NearestProfileIndex == 0 && first.Frames[1].UnavailableReason is not null,
            "An unmatched child Result stays unavailable; its nearest index never substitutes for a match. " + JsonSerializer.Serialize(first));
        Check(second.Frames[1].ProfileIndex == 0 && third.Frames[1].ProfileIndex == 1
            && second.Frames[0].Time == second.Frames[1].Time,
            "Different Result profile indices are synchronized by their actual source timestamp.");
        CultureInfo previousCulture = CultureInfo.CurrentCulture;
        try
        {
            foreach (string cultureName in new[] { "zh-CN", "en-US", "fr-FR" })
            {
                CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(cultureName);
                LinkedResultProfilesSnapshot localized = LinkedResultProfilesService.Read(request with { ProfileIndex = 1 });
                Check(localized.Steps.Select(step => step.Name).SequenceEqual(second.Steps.Select(step => step.Name))
                    && localized.Frames[1].ProfileIndex == 0 && localized.Frames[1].Time == second.Frames[1].Time,
                    "The retained OutputBlock timestamp identity and linked frame are independent of the UI culture: " + cultureName);
            }
        }
        finally { CultureInfo.CurrentCulture = previousCulture; }
        Check(before.All(pair => Hash(pair.Key) == pair.Value)
            && before.Count == Directory.GetFiles(directory.FullName, "*", SearchOption.AllDirectories).Length,
            "Linking and scrubbing the actual HDF Result fixtures leaves all source files unchanged.");
        ExportIfRequested(directory.FullName, fixture.ProjectPath, fixture.ResultPath, candidatePath);
        Console.WriteLine("Real HDF linked profiles retain the anchor timeline, shifted child indices, unmatched frames, exact source tolerance, and unchanged source files.");
    }

    private static void CheckSourceTolerance()
    {
        var key = new ProfileState(new[] { "2026-10-16T00:00:00.0000000", "2026-10-16T00:00:01.0000000" });
        var inside = new ProfileState(new[] { "2026-10-16T00:00:00.0100000", "2026-10-16T00:00:01.0100000" });
        var outside = new ProfileState(new[] { "2026-10-16T00:00:00.0100001" });
        using var linked = new KeyedProfileState(key, new[] { inside, outside }, TimeSpan.FromMilliseconds(10));
        linked.ForcePushStateToChildren();
        Check(inside.CurrentProfileIndex == 0 && outside.CurrentProfileIndex == -1,
            "The retained KeyedProfileState includes exactly 10 ms and excludes a single additional tick.");
        linked.CurrentProfileIndex = 1;
        Check(inside.CurrentProfileIndex == 1 && outside.CurrentProfileIndex == -1,
            "The source keyed state updates all children without reusing a stale matched frame.");
    }
    private static void ExportIfRequested(string source, string project, string anchor, string candidate)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_LINKED_PROFILE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination) || Directory.Exists(destination)) return;
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(destination, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!); File.Copy(file, copy);
        }
        File.WriteAllText(Path.Combine(destination, "LINKED_PROFILE_FIXTURE.json"), JsonSerializer.Serialize(new
        {
            project = Path.GetRelativePath(source, project), anchor = Path.GetRelativePath(source, anchor),
            candidate = Path.GetRelativePath(source, candidate),
            provenance = "Retained Result.PrepareResult/OutputBlock writer; deterministic stored test values, not solver output."
        }));
    }
    private static string Hash(string path) { using FileStream stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)); }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
