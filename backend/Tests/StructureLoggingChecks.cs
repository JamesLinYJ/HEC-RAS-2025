using Ras.Engine.Structures;

internal static class StructureLoggingChecks
{
    public static async Task Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "HEC", "RAS", "StructureTimeSeries");
        string pattern = "struct_ts_*_" + Environment.ProcessId + "_*.log";
        var before = Directory.Exists(directory)
            ? Directory.GetFiles(directory, pattern).ToHashSet(StringComparer.Ordinal)
            : new HashSet<string>(StringComparer.Ordinal);
        string marker = Guid.NewGuid().ToString("N");
        var expected = Enumerable.Range(0, 128).Select(index => marker + ":" + index).ToHashSet();
        string[] created = [];
        try
        {
            StructureTSLogger.RotateLog();
            await Task.WhenAll(Enumerable.Range(0, 8).Select(worker => Task.Run(() =>
            {
                for (int offset = 0; offset < 16; offset++)
                {
                    if (offset % 4 == 0) StructureTSLogger.RotateLog();
                    StructureTSLogger.Log(marker + ":" + (worker * 16 + offset));
                }
            })));
            StructureTSLogger.Close();
            created = Directory.GetFiles(directory, pattern).Where(path => !before.Contains(path)).ToArray();
            string[] lines = created.SelectMany(File.ReadAllLines).ToArray();
            if (created.Length < 2 || lines.Length != expected.Count || !expected.SetEquals(lines))
                throw new InvalidOperationException("Concurrent structure logging and rapid rotation must preserve every message in portable temporary files.");
            if (created.Any(path => !Path.IsPathFullyQualified(path) || Path.GetRelativePath(directory, path).Contains(Path.DirectorySeparatorChar)))
                throw new InvalidOperationException("Structure logs must stay inside their portable temporary directory.");
            Console.WriteLine("Portable structure time-series logging preserves all messages across concurrent writes and rapid rotation.");
        }
        finally
        {
            StructureTSLogger.Close();
            if (Directory.Exists(directory))
                created = Directory.GetFiles(directory, pattern).Where(path => !before.Contains(path)).ToArray();
            foreach (string path in created) File.Delete(path);
        }
    }
}
