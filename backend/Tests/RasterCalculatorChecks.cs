using System.Security.Cryptography;
using System.Text;
using Ras.Backend;

internal static class RasterCalculatorChecks
{
    internal static void Run()
    {
        using var directory = new TemporaryDirectory();
        MapResultRenderChecks.Fixture fixture = MapResultRenderChecks.CreateFixture(directory.FullName,
            velocityVariesByProfile: true);
        byte[] projectBefore = File.ReadAllBytes(fixture.ProjectPath);
        byte[] visualizationBefore = File.ReadAllBytes(fixture.VisualizationPath);
        byte[] resultBefore = File.ReadAllBytes(fixture.ResultPath);
        byte[] terrainBefore = File.ReadAllBytes(fixture.TerrainPath);

        RasterCalculatorInspectResult inspected = RasterCalculatorService.Inspect(new(fixture.Map));
        RasterCalculatorSourceChoice terrain = inspected.Sources.Single(source => source.Kind == "terrain");
        RasterCalculatorSourceChoice result = inspected.Sources.Single(source => source.Kind == "resultMap");
        Check(terrain.IsAvailable && terrain.Files.Any(file => file.Role == "terrain-hdf"
                && file.Revision?.Length == 64),
            "The inspect route exposes the exact saved Terrain source and content revision.");
        Check(result.IsAvailable && result.ProfileCount == 3
                && result.MapTypes.SequenceEqual(["Depth", "WaterSurfaceElevation", "Velocity", "DepthTimesVelocity"])
                && result.Files.Any(file => file.Role == "result-hdf" && file.Revision?.Length == 64),
            "The inspect route exposes all actual Result map types and stored profile identities.");

        RasterMapViewExtent viewport = new(0, 0, 1, 1, 48, 32);
        var terrainRecipe = new RasterCalculatorRecipe("a + 1", "WriteNDV", null,
            [new("a", terrain.Id, terrain.Revision, terrain.Kind)], []);
        RasterCalculatorEvaluateResult staticOutput = RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken, terrainRecipe, "calculator-static", "Calc: a + 1", 0, viewport));
        Check(!staticOutput.IsDynamic && staticOutput.ProfileCount == 1
                && staticOutput.Layer.Width == viewport.PixelWidth
                && staticOutput.Layer.Height == viewport.PixelHeight
                && staticOutput.Layer.RGBA.Length == viewport.PixelWidth * viewport.PixelHeight * 4,
            "Static Terrain expressions use the retained calculator and return a viewport-sized RGBA frame.");

        var resultRecipe = new RasterCalculatorRecipe("d", "WriteNDV", "d",
            [new("d", result.Id, result.Revision, result.Kind, "Depth", IsKeyFrame: true)], []);
        RasterCalculatorEvaluateResult firstProfile = RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken, resultRecipe, "calculator-dynamic", "Calc: depth", 0, viewport));
        RasterCalculatorEvaluateResult lastProfile = RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken, resultRecipe, "calculator-dynamic", "Calc: depth", 2, viewport));
        Check(firstProfile.IsDynamic && firstProfile.ProfileCount == 3
                && firstProfile.SelectedProfileIndex == 0 && lastProfile.SelectedProfileIndex == 2
                && firstProfile.SelectedProfileTime != lastProfile.SelectedProfileTime
                && firstProfile.Profiles.Select(profile => profile.Index).SequenceEqual([0, 1, 2]),
            "Dynamic Result expressions retain the actual source profile sequence and selected timestep metadata.");
        Check(!firstProfile.Layer.RGBA.SequenceEqual(lastProfile.Layer.RGBA),
            "Dynamic preview frames render their selected profile with the original fixed profile-zero palette.");
        Check(firstProfile.Sources.Single(source => source.Id == result.Id).Files
                .SequenceEqual(lastProfile.Sources.Single(source => source.Id == result.Id).Files),
            "Profile selection keeps the same exact Result HDF and associated source capture.");

        var alignedRecipe = new RasterCalculatorRecipe("depth + velocity * factor", "WriteZero", "depth",
            [
                new("depth", result.Id, result.Revision, result.Kind, "Depth", IsKeyFrame: true),
                new("velocity", result.Id, result.Revision, result.Kind, "Velocity", ForceHorizontal: true)
            ], [new("factor", "2.5")]);
        RasterCalculatorEvaluateResult aligned = RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken, alignedRecipe, "calculator-aligned", "Calc: aligned", 1, viewport));
        Check(aligned.IsDynamic && aligned.SelectedProfileIndex == 1 && aligned.ProfileCount == 3
                && aligned.SelectedProfileTime == inspected.Sources.Single(source => source.Kind == "resultMap").ProfileTimes[1],
            "Mixed Result map types use the selected dynamic key frame and the retained time-alignment algorithm.");

        Expect<ArgumentException>(() => RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken,
            new RasterCalculatorRecipe("a", "WriteNDV", null,
                [new("a", result.Id, result.Revision, "terrain")], []),
            "calculator-type-mismatch", "Calc: mismatch", 0, viewport)));
        Expect<ArgumentException>(() => RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken,
            new RasterCalculatorRecipe("a", "WriteNDV", null,
                [new("a", terrain.Id, terrain.Revision, terrain.Kind, IsKeyFrame: true)], []),
            "calculator-static-keyframe", "Calc: static key frame", 0, viewport)));
        Expect<ArgumentException>(() => RasterCalculatorService.Evaluate(new(
            fixture.Map, inspected.ContextToken,
            new RasterCalculatorRecipe("a", "WriteNDV", null,
                [new("a", result.Id, result.Revision, result.Kind, "UnsupportedMap")], []),
            "calculator-map-type", "Calc: invalid map type", 0, viewport)));

        Expect<SourceFileChangedException>(() => RasterCalculatorService.Evaluate(new(
            fixture.Map, new string('0', 64), terrainRecipe, "calculator-stale", "Calc: stale", 0, viewport)));
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(projectBefore)
                && File.ReadAllBytes(fixture.VisualizationPath).SequenceEqual(visualizationBefore)
                && File.ReadAllBytes(fixture.ResultPath).SequenceEqual(resultBefore)
                && File.ReadAllBytes(fixture.TerrainPath).SequenceEqual(terrainBefore),
            "Calculator inspection, static/dynamic preview, and profile changes leave .ras, .vis, HDF and Terrain bytes unchanged.");

        ExportAcceptanceFixtureIfRequested(directory.FullName);

        File.AppendAllText(fixture.VisualizationPath, " ", Encoding.UTF8);
        Expect<SourceFileChangedException>(() => RasterCalculatorService.Inspect(new(fixture.Map)));
        Check(Hash(File.ReadAllBytes(fixture.VisualizationPath)) != inspected.VisualizationRevision,
            "A changed saved-map visualization cannot be silently reused by a prior calculator context.");

        Console.WriteLine("Raster Calculator retained static/dynamic expressions, profile metadata, stale map identity, and read-only source checks passed.");
    }

    private static string Hash(ReadOnlySpan<byte> data) => Convert.ToHexString(SHA256.HashData(data));

    private static void ExportAcceptanceFixtureIfRequested(string sourceRoot)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_RASTER_CALCULATOR_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string source = Path.GetFullPath(sourceRoot);
        string target = Path.GetFullPath(destination);
        if (Directory.Exists(target) || File.Exists(target)
            || target.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new IOException("The Raster Calculator acceptance directory already exists or is inside the source fixture.");
        Directory.CreateDirectory(target);
        foreach (string path in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, path));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(path, copy);
        }
        File.WriteAllText(Path.Combine(target, "ACCEPTANCE.txt"),
            "Source-backed Raster Calculator fixture produced with retained Terrain, Result, and OutputBlock APIs. "
            + "The three stored profiles are deterministic test data, not solver output.");
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
