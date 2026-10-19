/// <summary>
/// Executes every ordered source check in the final independent phase. A
/// failure remains a failure and prevents the overall success marker, while
/// later groups still produce their own diagnostics. Required source fixture
/// production happens before entering this phase; dependent checks also fail
/// explicitly when a required fixture is unavailable.
/// </summary>
internal sealed class SourceCheckPhase
{
    private readonly List<Exception> failures = [];

    internal Task Run(string name, Action action) => Run(name, () =>
    {
        action();
        return Task.CompletedTask;
    });

    internal async Task Run(string name, Func<Task> action)
    {
        try
        {
            await action();
            Console.WriteLine("Source check group passed: " + name);
        }
        catch (Exception error)
        {
            failures.Add(new InvalidOperationException(name, error));
            Console.Error.WriteLine("Source check group failed: " + name + Environment.NewLine + error);
        }
    }

    internal void ThrowIfFailed()
    {
        if (failures.Count != 0)
            throw new AggregateException("Required source check groups failed: " + failures.Count, failures);
    }
}
