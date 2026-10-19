using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;

internal static class GdbRasterHoverFixture
{
    private const string ResourceName = "Ras.Backend.Tests.Fixtures.GdalFileGDB.gdal_test_data.gdb.zip";
    private const string ExpectedSHA256 = "0DC49BC299FFBE9503937B9469D8F8BDA1519BE1826410FF6C50A47E524A10EE";
    private const long MaximumExpandedBytes = 256L * 1024 * 1024;
    private const int MaximumEntries = 4096;

    internal static string Extract(string destinationDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationDirectory);
        using Stream resource = typeof(GdbRasterHoverFixture).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidDataException($"The required official FileGDB test resource {ResourceName} is missing.");
        using var archiveBytes = new MemoryStream();
        resource.CopyTo(archiveBytes);
        byte[] bytes = archiveBytes.ToArray();
        string digest = Convert.ToHexString(SHA256.HashData(bytes));
        if (!string.Equals(digest, ExpectedSHA256, StringComparison.Ordinal))
            throw new InvalidDataException("The embedded official FileGDB test resource failed its pinned SHA-256 check.");

        string extractionRoot = Path.GetFullPath(destinationDirectory);
        Directory.CreateDirectory(extractionRoot);
        string root = Path.GetFullPath(Path.Combine(extractionRoot, "gdal_test_data.gdb"));
        if (Directory.Exists(root) || File.Exists(root))
            throw new IOException("The official FileGDB extraction destination already exists.");
        string rootPrefix = root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        long expandedBytes = 0;
        using var archiveStream = new MemoryStream(bytes, writable: false);
        using var archive = new ZipArchive(archiveStream, ZipArchiveMode.Read, leaveOpen: false);
        if (archive.Entries.Count is < 1 or > MaximumEntries)
            throw new InvalidDataException("The official FileGDB archive has an invalid entry count.");

        foreach (ZipArchiveEntry entry in archive.Entries)
        {
            string entryName = entry.FullName.Replace('\\', '/');
            string[] segments = entryName.Split('/', StringSplitOptions.RemoveEmptyEntries);
            bool isDirectory = entryName.EndsWith("/", StringComparison.Ordinal);
            if (segments.Length == 0 || segments[0] != "gdal_test_data.gdb" ||
                entryName.StartsWith("/", StringComparison.Ordinal) ||
                entryName.Contains(':') || entryName.Contains('\0') ||
                segments.Any(segment => segment is "." or "..") ||
                ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                throw new InvalidDataException("The official FileGDB archive contains an unsafe path or link.");

            string target = Path.GetFullPath(Path.Combine(extractionRoot, Path.Combine(segments)));
            if (target != root && !target.StartsWith(rootPrefix, PathComparison))
                throw new InvalidDataException("A FileGDB archive entry escapes its extraction directory.");
            if (isDirectory)
            {
                Directory.CreateDirectory(target);
                continue;
            }

            if (entry.Length < 0 || entry.Length > MaximumExpandedBytes ||
                expandedBytes > MaximumExpandedBytes - entry.Length)
                throw new InvalidDataException("The FileGDB archive exceeds the bounded extraction size.");
            expandedBytes += entry.Length;
            string? parent = Path.GetDirectoryName(target);
            if (parent is null || parent != root && !parent.StartsWith(rootPrefix, PathComparison))
                throw new InvalidDataException("A FileGDB archive file has no safe extraction parent.");
            Directory.CreateDirectory(parent);
            using Stream input = entry.Open();
            using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            byte[] buffer = new byte[64 * 1024];
            long copied = 0;
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
            {
                if (copied > entry.Length - read)
                    throw new InvalidDataException("A FileGDB archive member exceeds its declared uncompressed length.");
                output.Write(buffer, 0, read);
                copied += read;
            }
            if (copied != entry.Length)
                throw new InvalidDataException("A FileGDB archive member did not match its declared uncompressed length.");
        }

        if (!Directory.Exists(root) || !File.Exists(Path.Combine(root, "a00000001.gdbtable")) &&
            Directory.GetFiles(root, "*.gdbtable", SearchOption.TopDirectoryOnly).Length == 0)
            throw new InvalidDataException("The pinned archive did not extract an actual FileGDB dataset.");
        return root;
    }

    private static StringComparison PathComparison => OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
}
