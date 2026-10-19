using Microsoft.Extensions.Logging;
using Ras.Backend;
using Utility.Logging;

internal static class BackendApplicationLoggingChecks
{
    internal static void Run()
    {
        SourceThresholdsAndFormatsArePreserved();
        HostLoggerFactoryUsesTheSharedFiles();
        IndependentWritersAppendWholeRecords();
        Console.WriteLine("Native and Host application logs preserve source severity formats and serialize concurrent appends.");
    }

    private static void SourceThresholdsAndFormatsArePreserved()
    {
        using var directory = new TemporaryDirectory();
        var instant = new DateTimeOffset(2026, 10, 19, 13, 4, 5, 6, TimeSpan.FromHours(8));
        using var provider = new BackendApplicationLogProvider(directory.FullName, () => instant);
        ILogger logger = provider.CreateLogger("Checks.Category");
        logger.LogTrace("trace is below the retained Debug threshold");
        logger.LogDebug("debug value {Value}", 7);
        logger.LogInformation("information message");
        logger.LogWarning("warning message");
        var sourceException = new InvalidOperationException("retained exception details");
        logger.LogError(sourceException, "error for {Asset}", "Geometry A");
        logger.LogCritical("critical message");

        string main = File.ReadAllText(Path.Combine(directory.FullName, "ras.log"));
        string errors = File.ReadAllText(Path.Combine(directory.FullName, "ras-errors.log"));
        Check(main.Contains("13:04:05.006 debug value 7\n", StringComparison.Ordinal)
              && main.Contains("13:04:05.006 information message\n", StringComparison.Ordinal)
              && main.Contains("13:04:05.006 warning message\n", StringComparison.Ordinal)
              && main.Contains("13:04:05.006 error for Geometry A\n", StringComparison.Ordinal)
              && main.Contains("13:04:05.006 critical message\n", StringComparison.Ordinal)
              && !main.Contains("trace is below", StringComparison.Ordinal),
            "ras.log uses the retained local time format, includes Debug and higher, and omits Trace.");
        Check(!main.Contains("Checks.Category", StringComparison.Ordinal),
            "The source text-file template emits formatted messages without logger categories.");
        Check(errors.Contains("2026-10-19 13:04:05.006 +08:00 [WRN] warning message\n", StringComparison.Ordinal)
              && errors.Contains("2026-10-19 13:04:05.006 +08:00 [ERR] error for Geometry A\n", StringComparison.Ordinal)
              && errors.Contains("2026-10-19 13:04:05.006 +08:00 [FTL] critical message\n", StringComparison.Ordinal)
              && errors.Contains("InvalidOperationException: retained exception details", StringComparison.Ordinal)
              && !errors.Contains("information message", StringComparison.Ordinal),
            "ras-errors.log includes Warning and Error with offset timestamps and exception details only.");
        Check(File.Exists(Path.Combine(directory.FullName, ".ras-log.lock")),
            "The shared native/Host append lock is retained next to the log files.");
    }

    private static void HostLoggerFactoryUsesTheSharedFiles()
    {
        using var directory = new TemporaryDirectory();
        ILoggerFactory previous = LogHelper.LoggerFactory;
        string stdout;
        using (var capturedStdout = new StringWriter())
        {
            TextWriter originalStdout = Console.Out;
            try
            {
                Console.SetOut(capturedStdout);
                using (BackendApplicationLogging.Initialize(directory.FullName))
                    LogHelper.GetLogger("Host.Startup")!.LogInformation("host service started");
            }
            finally
            {
                Console.SetOut(originalStdout);
            }
            stdout = capturedStdout.ToString();
        }
        Check(ReferenceEquals(LogHelper.LoggerFactory, previous),
            "Disposing the Host logging registration restores the caller's LoggerFactory.");
        Check(stdout.Length == 0
              && File.ReadAllText(Path.Combine(directory.FullName, "ras.log"))
                  .Contains("host service started", StringComparison.Ordinal),
            "LogHelper writes through the Host provider without adding bytes to protocol stdout.");
    }

    private static void IndependentWritersAppendWholeRecords()
    {
        using var directory = new TemporaryDirectory();
        const int writerCount = 6;
        const int messagesPerWriter = 40;
        Parallel.For(0, writerCount, writerIndex =>
        {
            using var provider = new BackendApplicationLogProvider(directory.FullName);
            ILogger logger = provider.CreateLogger("parallel");
            for (int messageIndex = 0; messageIndex < messagesPerWriter; messageIndex++)
                logger.LogInformation("writer={Writer} record={Record}", writerIndex, messageIndex);
        });

        string[] lines = File.ReadAllLines(Path.Combine(directory.FullName, "ras.log"));
        Check(lines.Length == writerCount * messagesPerWriter,
            "Concurrent logger providers append every record exactly once.");
        for (int writerIndex = 0; writerIndex < writerCount; writerIndex++)
        {
            string prefix = $"writer={writerIndex} record=";
            string[] writerLines = lines.Where(line => line.Contains(prefix, StringComparison.Ordinal)).ToArray();
            Check(writerLines.Length == messagesPerWriter
                  && writerLines.All(line => int.TryParse(line[(line.IndexOf(prefix, StringComparison.Ordinal) + prefix.Length)..], out _)),
                "The shared flock prevents concurrent append records from interleaving or truncating.");
        }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string FullName { get; } = Path.Combine(Path.GetTempPath(), "hecras-logs-" + Guid.NewGuid().ToString("N"));

        public TemporaryDirectory() => Directory.CreateDirectory(FullName);

        public void Dispose()
        {
            if (Directory.Exists(FullName)) Directory.Delete(FullName, recursive: true);
        }
    }
}
