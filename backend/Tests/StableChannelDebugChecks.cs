using System.Security.Cryptography;
using Ras.Backend;
using Ras.Hydraulics.HydraulicDesign;
using Ras.Layers;
using Utility.Units;

internal static class StableChannelDebugChecks
{
    internal static void Run()
    {
        StableChannelDebugOpenResponse memory = StableChannelDebugService.Open(
            new StableChannelDebugOpenRequest("open-memory", null));
        Check(memory.Source.InMemory && Guid.TryParse(memory.Source.SourceID, out _),
            "The debug action can open a source-permitted in-memory Stable Channel design.");
        Check(memory.State.LeftBank is not null && memory.State.Bed is not null && memory.State.RightBank is not null &&
              memory.State.LeftBank.Equation == nameof(BankEquation.Strickler) &&
              memory.State.Bed.D == 0 && memory.State.RightBank.SpecificGravity == 0,
            "Missing in-memory source parts receive only declared CLR zero defaults and the source enum default.");
        Expect<InvalidOperationException>(() => StableChannelDebugService.Save(
            new StableChannelDebugSaveRequest("save-memory", memory.Source, memory.State)));

        StableChannelDebugState inputs = ValidInputs();
        StableChannelDebugComputeResponse rejected = StableChannelDebugService.Compute(
            new StableChannelDebugComputeRequest("compute-invalid", memory.Source, inputs, ["Depth"]));
        Check(!rejected.Computed && rejected.ErrorCode == "selectExactlyTwoTargets",
            "The source solve-for controller requires exactly two distinct targets.");

        StableChannelDebugComputeResponse computed = StableChannelDebugService.Compute(
            new StableChannelDebugComputeRequest("compute", memory.Source, inputs, ["Depth", "Width"]));
        TractiveForceMethod sourceMethod = ToSourceMethod(inputs);
        sourceMethod.SolveForDepthAndWidth(out double expectedDepth, out double expectedWidth);
        Check(computed.Computed && computed.State.Depth == expectedDepth && computed.State.Width == expectedWidth,
            "The debug service invokes the retained TractiveForceMethod solver and returns its values.");

        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Stable Channel debug.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.USCustomary);
        project.Save();
        // MakeFilename takes the project root and adds the source's Hydraulic
        // Design directory itself. Passing HydraulicDesignDirectory here
        // would create a nested folder the project loader does not scan.
        string designPath = StableChannelDesign.MakeFilename(project.ProjectDirectory, "Stable Channel debug");
        StableChannelDesign design = StableChannelDesign.CreateNew(designPath);
        design.Project = project;
        design.TractiveForce = ToSourceMethod(inputs);
        design.SaveAs(designPath);
        project.HydraulicDesign.AddStableChannelDesign(design);
        project.Save();
        design.Dispose();
        Dispose(project);

        // Reopen independently to identify the first design exactly as the
        // persisted-project route will, rather than assuming the creation
        // path is the loader's selected entry.
        Project persistedProject = new(projectPath);
        string firstPersistedDesignPath;
        StableChannelDesign? firstPersistedDesign = null;
        try
        {
            firstPersistedDesign = persistedProject.HydraulicDesign.StableChannelDesigns
                .FirstOrDefault() ?? throw new InvalidOperationException(
                    "The test project did not persist its Stable Channel design.");
            firstPersistedDesignPath = Path.GetFullPath(firstPersistedDesign.Filename);
        }
        finally
        {
            firstPersistedDesign?.Dispose();
            Dispose(persistedProject);
        }

        string expectedProjectRevision = FileRevision(projectPath);
        string expectedDesignRevision = FileRevision(firstPersistedDesignPath);

        StableChannelDebugOpenResponse opened = StableChannelDebugService.Open(
            new StableChannelDebugOpenRequest("open-file", projectPath));
        Check(!opened.Source.InMemory,
            $"The persisted debug route must not report an in-memory source (actual: {opened.Source.InMemory}).");
        Check(PathEquals(opened.Source.ProjectPath ?? "", projectPath),
            $"The debug route must return the requested project path (actual: '{opened.Source.ProjectPath}', expected: '{projectPath}').");
        Check(PathEquals(opened.Source.DesignPath ?? "", firstPersistedDesignPath),
            $"The debug route must return the first persisted design path (actual: '{opened.Source.DesignPath}', expected: '{firstPersistedDesignPath}').");
        Check(IsSHA256(opened.Source.ProjectRevision),
            $"The debug route must return a project SHA-256 revision (actual: '{opened.Source.ProjectRevision ?? "<null>"}').");
        Check(IsSHA256(opened.Source.DesignRevision),
            $"The debug route must return a design SHA-256 revision (actual: '{opened.Source.DesignRevision ?? "<null>"}').");
        Check(string.Equals(opened.Source.ProjectRevision, expectedProjectRevision, StringComparison.OrdinalIgnoreCase),
            $"The debug route must capture the requested project bytes (actual revision: '{opened.Source.ProjectRevision}', expected: '{expectedProjectRevision}').");
        Check(string.Equals(opened.Source.DesignRevision, expectedDesignRevision, StringComparison.OrdinalIgnoreCase),
            $"The debug route must capture the first persisted design bytes (actual revision: '{opened.Source.DesignRevision}', expected: '{expectedDesignRevision}').");
        StableChannelDebugState draft = opened.State with { Discharge = 120 };
        StableChannelDebugSaveResponse saved = StableChannelDebugService.Save(
            new StableChannelDebugSaveRequest("save-file", opened.Source, draft));
        Check(saved.SourceID == opened.Source.SourceID && saved.DesignRevision != opened.Source.DesignRevision &&
              FileRevision(designPath) == saved.DesignRevision && saved.State.Discharge == 120,
            "A persisted draft writes the actual Stable Channel HDF through its staged save path and advances its SHA.");

        Project reopened = new(projectPath);
        StableChannelDesign persisted = reopened.HydraulicDesign.StableChannelDesigns.Single();
        try
        {
            Check(persisted.TractiveForce.Discharge == 120 && persisted.TractiveForce.LeftBank is not null &&
                  persisted.TractiveForce.Bed?.Equation == BankEquation.Manning &&
                  persisted.TractiveForce.RightBank?.Roughness == inputs.RightBank!.Roughness,
                "A fresh Project load independently reads the saved typed Tractive Force metadata.");
        }
        finally
        {
            persisted.Dispose();
            Dispose(reopened);
        }

        StableChannelDebugSaveRequest stale = new("stale-save", opened.Source, draft);
        using (var append = new FileStream(designPath, FileMode.Append, FileAccess.Write, FileShare.Read))
            append.WriteByte(0x5A);
        byte[] concurrentEdit = File.ReadAllBytes(designPath);
        Expect<InvalidOperationException>(() => StableChannelDebugService.Save(stale));
        Check(File.ReadAllBytes(designPath).SequenceEqual(concurrentEdit),
            "A stale Stable Channel revision is rejected without overwriting the external edit.");

        Console.WriteLine("Stable Channel debug open, retained compute, persisted HDF save and stale-source guards passed.");
    }

    private static StableChannelDebugState ValidInputs() => new(
        Depth: 2, Discharge: 100, Slope: .001, LeftBankSideSlope: 2, RightBankSideSlope: 2,
        Temperature: 70, Width: 60, SolutionMethod: nameof(TractiveForceSolutionMethod.Lane),
        LeftBank: Part(), Bed: Part(), RightBank: Part());

    private static StableChannelDebugPartState Part() => new(
        D: .005, AngleOfRepose: 45, Roughness: .03, SpecificGravity: 2.65,
        ShieldsParameter: .047, Equation: nameof(BankEquation.Manning));

    private static TractiveForceMethod ToSourceMethod(StableChannelDebugState state) => new()
    {
        Depth = state.Depth ?? double.NaN,
        Discharge = state.Discharge ?? double.NaN,
        Slope = state.Slope ?? double.NaN,
        LeftBankSideSlope = state.LeftBankSideSlope ?? double.NaN,
        RightBankSideSlope = state.RightBankSideSlope ?? double.NaN,
        Temperature = state.Temperature ?? double.NaN,
        Width = state.Width ?? double.NaN,
        SolutionMethod = Enum.Parse<TractiveForceSolutionMethod>(state.SolutionMethod),
        LeftBank = ToSourcePart(state.LeftBank!),
        Bed = ToSourcePart(state.Bed!),
        RightBank = ToSourcePart(state.RightBank!)
    };

    private static TractiveForceMethodPart ToSourcePart(StableChannelDebugPartState part) => new()
    {
        D = part.D ?? double.NaN,
        AngleOfRepose = part.AngleOfRepose ?? double.NaN,
        Roughness = part.Roughness ?? double.NaN,
        SpecificGravity = part.SpecificGravity ?? double.NaN,
        ShieldsParameter = part.ShieldsParameter ?? double.NaN,
        Equation = Enum.Parse<BankEquation>(part.Equation)
    };

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static string FileRevision(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    private static bool IsSHA256(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);
    private static bool PathEquals(string left, string right) =>
        string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
    private static void Expect<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }
}
