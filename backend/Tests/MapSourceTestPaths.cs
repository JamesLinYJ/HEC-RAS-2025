/// <summary>Compares fixture file identities without rebasing project XML.</summary>
internal static class MapSourceTestPaths
{
    internal static bool SameFile(string left, string right) =>
        string.Equals(Physical(left), Physical(right), OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    internal static string Physical(string path)
    {
        string full = Path.GetFullPath(path);
        string? parent = Path.GetDirectoryName(full);
        if (parent is null || parent == full) return full;
        string candidate = Path.Combine(Physical(parent), Path.GetFileName(full));
        FileSystemInfo info = Directory.Exists(candidate) ? new DirectoryInfo(candidate) : new FileInfo(candidate);
        return info.Exists && info.LinkTarget is not null
            ? info.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? candidate : candidate;
    }
}
