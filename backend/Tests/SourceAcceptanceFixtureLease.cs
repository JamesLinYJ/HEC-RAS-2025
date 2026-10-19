/// <summary>
/// Keeps standalone source regression runs self-contained. Source checks
/// export real Result and associated-layer fixtures before later read-only
/// checks consume them. Each generated destination is absent and independent.
/// Explicit caller-owned export destinations remain unchanged.
/// </summary>
internal sealed class SourceAcceptanceFixtureLease : IDisposable
{
    private static readonly string[] Variables =
    [
        "HECRAS_CULVERT_PARTICLE_ACCEPTANCE_DIRECTORY",
        "HECRAS_PLAN_MAP_ACCEPTANCE_DIRECTORY",
        "HECRAS_ASSOCIATED_MAP_ACCEPTANCE_DIRECTORY"
    ];
    private readonly Dictionary<string, string?> previous = [];
    private readonly TemporaryDirectory? temporary;

    internal SourceAcceptanceFixtureLease()
    {
        string[] missing = Variables.Where(variable =>
            string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(variable))).ToArray();
        if (missing.Length == 0) return;
        temporary = new TemporaryDirectory();
        foreach (string variable in missing)
        {
            previous.Add(variable, Environment.GetEnvironmentVariable(variable));
            // Export requires separate absent destinations. Producers use
            // retained source APIs and keep fixtures available to all checks.
            string destination = Path.Combine(temporary.FullName, variable);
            Environment.SetEnvironmentVariable(variable, destination);
        }
    }

    public void Dispose()
    {
        if (temporary is null) return;
        foreach ((string variable, string? value) in previous)
            Environment.SetEnvironmentVariable(variable, value);
        temporary.Dispose();
    }
}
