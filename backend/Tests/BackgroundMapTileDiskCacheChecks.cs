using System.Diagnostics;
using System.IO.Compression;
using Ras.Backend;

internal static class BackgroundMapTileDiskCacheChecks
{
    internal static async Task Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "hecras-background-map-cache-check-" + Guid.NewGuid().ToString("N"));
        BackgroundMapTileDiskCache cache = new(directory);
        BackgroundMapTileDiskCache secondInstance = new(directory);
        OsmCpuTileCoordinate tile = new(4, 5, 6);
        CancellationToken cancellationToken = CancellationToken.None;
        string marker = directory + ".process-check";
        string holderMarker = marker + ".holder";
        string waiterMarker = marker + ".waiter";
        try
        {
            (byte[]? missing, long beforeClearGeneration) = await cache.ReadAsync(tile, cancellationToken);
            Check(missing is null, "A new cache starts without a cached tile.");

            _ = secondInstance.InspectOrClear(clear: true);
            byte[] downloadedTile = Gzip("valid vector tile payload");
            await cache.WriteIfCurrentAsync(tile, downloadedTile, beforeClearGeneration, cancellationToken);
            Check(!File.Exists(cache.PathFor(tile)),
                "A fetch observed by one cache instance cannot write after another instance clears.");

            (byte[]? absentAfterClear, long currentGeneration) = await cache.ReadAsync(tile, cancellationToken);
            Check(absentAfterClear is null && currentGeneration != beforeClearGeneration,
                "A new cache instance reads the persisted post-clear epoch without stale data.");
            await secondInstance.WriteIfCurrentAsync(tile, downloadedTile, currentGeneration, cancellationToken);
            (byte[]? cached, long _) = await cache.ReadAsync(tile, cancellationToken);
            Check(cached is not null && cached.SequenceEqual(downloadedTile),
                "Independent cache instances share post-clear tile bytes.");

            (long bytes, bool canClear, bool cleared) = secondInstance.InspectOrClear(clear: false);
            Check(bytes == downloadedTile.Length && canClear && !cleared,
                "Cache inspection reports actual disk bytes without clearing them.");
            (long clearedBytes, bool stillAvailable, bool clearSucceeded) = cache.InspectOrClear(clear: true);
            Check(clearedBytes == 0 && stillAvailable && clearSucceeded &&
                  File.Exists(cache.LockFilePathForChecks) && File.Exists(cache.EpochFilePathForChecks),
                "A cache clear removes entries while retaining its sidecar lock and epoch.");

            await CheckCrossProcessEpochAsync(cache, directory, tile, downloadedTile, marker);
            await CheckCrossProcessReleaseAsync(cache, directory, marker);
            Console.WriteLine("Background OSM disk cache shares persistent epochs and releases its cross-process file lease after owner exit.");
        }
        finally
        {
            DeleteArtifacts(directory, marker, holderMarker, waiterMarker);
        }
    }

    // Invoked only by the backend test executable's early CLI dispatch. The
    // parent process starts this child while another process owns the lease.
    internal static async Task RunLockProbeAsync(string directory, string marker)
    {
        BackgroundMapTileDiskCache cache = new(directory);
        if (File.Exists(marker + ".clear"))
        {
            _ = cache.InspectOrClear(clear: true);
            await File.WriteAllTextAsync(marker + ".cleared", "cleared").ConfigureAwait(false);
            return;
        }

        if (File.Exists(marker + ".hold"))
        {
            using FileStream lease = new(cache.LockFilePathForChecks, FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None, bufferSize: 1, FileOptions.None);
            await File.WriteAllTextAsync(marker + ".acquired", "held").ConfigureAwait(false);
            await WaitForReleaseAsync(marker + ".release").ConfigureAwait(false);
            return;
        }

        // Prove the fresh process actually encounters the OS sharing lock before
        // it enters the production retry path.
        try
        {
            using FileStream unexpectedLease = new(cache.LockFilePathForChecks, FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None, bufferSize: 1, FileOptions.None);
            throw new InvalidOperationException("The child opened a cache lease while another process owned it.");
        }
        catch (IOException)
        {
            await File.WriteAllTextAsync(marker + ".blocked", "blocked").ConfigureAwait(false);
        }

        _ = cache.InspectOrClear(clear: false);
        await File.WriteAllTextAsync(marker + ".acquired", "acquired").ConfigureAwait(false);
    }

    private static async Task CheckCrossProcessEpochAsync(BackgroundMapTileDiskCache cache, string directory,
        OsmCpuTileCoordinate tile, byte[] downloadedTile, string marker)
    {
        var (_, capturedGeneration) = await cache.ReadAsync(tile, CancellationToken.None).ConfigureAwait(false);
        string clearMarker = marker + ".clear-process";
        await File.WriteAllTextAsync(clearMarker + ".clear", "clear").ConfigureAwait(false);
        using Process clearer = StartProbe(directory, clearMarker);
        await WaitForMarkerAsync(clearMarker + ".cleared", clearer, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        await clearer.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        Check(clearer.ExitCode == 0, "A separate backend process can complete a cache clear.");

        await cache.WriteIfCurrentAsync(tile, downloadedTile, capturedGeneration, CancellationToken.None)
            .ConfigureAwait(false);
        Check(!File.Exists(cache.PathFor(tile)),
            "A response captured before another process clears cannot repopulate the tile cache.");
        var (_, currentGeneration) = await cache.ReadAsync(tile, CancellationToken.None).ConfigureAwait(false);
        Check(currentGeneration != capturedGeneration,
            "A cache instance observes an epoch increment committed by a separate process.");
    }

    private static async Task CheckCrossProcessReleaseAsync(BackgroundMapTileDiskCache cache, string directory,
        string marker)
    {
        string holderMarker = marker + ".holder";
        string waiterMarker = marker + ".waiter";
        await File.WriteAllTextAsync(holderMarker + ".hold", "hold").ConfigureAwait(false);
        using Process holder = StartProbe(directory, holderMarker);
        Process? waiter = null;
        try
        {
            await WaitForMarkerAsync(holderMarker + ".acquired", holder, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            waiter = StartProbe(directory, waiterMarker);
            await WaitForMarkerAsync(waiterMarker + ".blocked", waiter, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            Check(!File.Exists(waiterMarker + ".acquired"),
                "A separate backend process cannot enter the cache while the lease owner is alive.");

            holder.Kill(entireProcessTree: true);
            await holder.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            await WaitForMarkerAsync(waiterMarker + ".acquired", waiter, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            await waiter.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            Check(waiter.ExitCode == 0,
                "A waiting backend process proceeds after the lock-owning process exits.");
            _ = cache.InspectOrClear(clear: true);
        }
        finally
        {
            if (!holder.HasExited)
            {
                holder.Kill(entireProcessTree: true);
                await holder.WaitForExitAsync().ConfigureAwait(false);
            }
            if (waiter is not null)
            {
                if (!waiter.HasExited)
                {
                    waiter.Kill(entireProcessTree: true);
                    await waiter.WaitForExitAsync().ConfigureAwait(false);
                }
                waiter.Dispose();
            }
        }
    }

    private static Process StartProbe(string directory, string marker)
    {
        string processPath = Environment.ProcessPath
            ?? throw new InvalidOperationException("The current test executable path is unavailable.");
        string[] commandLine = Environment.GetCommandLineArgs();
        ProcessStartInfo start = new(processPath)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Environment.CurrentDirectory,
        };
        if (string.Equals(Path.GetFileNameWithoutExtension(processPath), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            if (commandLine.Length == 0)
                throw new InvalidOperationException("The backend test assembly path is unavailable.");
            start.ArgumentList.Add(commandLine[0]);
        }
        start.ArgumentList.Add("--background-map-cache-lock-probe");
        start.ArgumentList.Add(directory);
        start.ArgumentList.Add(marker);
        return Process.Start(start)
            ?? throw new InvalidOperationException("Could not start the background-map cache lock probe.");
    }

    private static async Task WaitForMarkerAsync(string path, Process process, TimeSpan timeout)
    {
        using CancellationTokenSource cancellation = new(timeout);
        while (!File.Exists(path))
        {
            if (process.HasExited)
            {
                string error = await process.StandardError.ReadToEndAsync().ConfigureAwait(false);
                string output = await process.StandardOutput.ReadToEndAsync().ConfigureAwait(false);
                throw new InvalidOperationException(
                    $"Background-map cache probe exited before creating {Path.GetFileName(path)} (code {process.ExitCode}). {error} {output}");
            }
            await Task.Delay(TimeSpan.FromMilliseconds(20), cancellation.Token).ConfigureAwait(false);
        }
    }

    private static async Task WaitForReleaseAsync(string path)
    {
        using CancellationTokenSource timeout = new(TimeSpan.FromMinutes(2));
        while (!File.Exists(path))
            await Task.Delay(TimeSpan.FromMilliseconds(20), timeout.Token).ConfigureAwait(false);
    }

    private static void DeleteArtifacts(string directory, params string[] markerRoots)
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        foreach (string suffix in new[] { ".cache-lock", ".cache-epoch" })
        {
            string path = directory + suffix;
            if (File.Exists(path)) File.Delete(path);
        }
        foreach (string marker in markerRoots)
        {
            string? parent = Path.GetDirectoryName(marker);
            if (parent is null || !Directory.Exists(parent)) continue;
            foreach (string path in Directory.EnumerateFiles(parent, Path.GetFileName(marker) + "*"))
                File.Delete(path);
        }
    }

    private static byte[] Gzip(string value)
    {
        using MemoryStream output = new();
        using (GZipStream gzip = new(output, CompressionLevel.SmallestSize, leaveOpen: true))
            gzip.Write(System.Text.Encoding.UTF8.GetBytes(value));
        return output.ToArray();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
