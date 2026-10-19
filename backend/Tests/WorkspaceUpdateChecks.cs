using Ras.Backend;
using Ras.Updates;

internal static class WorkspaceUpdateChecks
{
    internal static void Run()
    {
        CheckMacPackageClassificationRequiresExplicitPlatformAndArchitecture();
        CheckInstalledVersionComparisonMatchesSourceVersionFields();
    }

    private static void CheckMacPackageClassificationRequiresExplicitPlatformAndArchitecture()
    {
        MappedFile Package(string name) => new() { Filename = name, SHA256 = new string('b', 64), Length = 42 };
        WorkspaceUpdateService.Package arm64 = WorkspaceUpdateService.ClassifyMacPackage(
            Package("HEC-RAS-macOS-arm64.pkg"))!;
        Check(arm64.Platform == "macOS" && arm64.Architecture == "arm64",
            "An explicitly labeled arm64 macOS installer is classified from its release filename.");
        WorkspaceUpdateService.Package universal = WorkspaceUpdateService.ClassifyMacPackage(
            Package("HEC-RAS-darwin-universal2.dmg"))!;
        Check(universal.Platform == "macOS" && universal.Architecture == "universal",
            "An explicitly labeled universal macOS disk image is classified as compatible.");
        Check(WorkspaceUpdateService.ClassifyMacPackage(Package("HEC-RAS-windows-arm64.msix")) is null &&
              WorkspaceUpdateService.ClassifyMacPackage(Package("HEC-RAS-windows-x64.pkg")) is null &&
              WorkspaceUpdateService.ClassifyMacPackage(Package("HEC-RAS-arm64.pkg")) is null &&
              WorkspaceUpdateService.ClassifyMacPackage(Package("HEC-RAS-macos-x64.pkg")) is null &&
              WorkspaceUpdateService.ClassifyMacPackage(Package("HEC-RAS-macos-arm64.exe")) is null,
            "Windows-only, ambiguous-platform, unsupported-architecture, and executable artifacts are never offered as Mac installers.");
        Check(WorkspaceUpdateService.ClassifyMacPackage(new MappedFile
        {
            Filename = "HEC-RAS-macos-arm64.pkg", SHA256 = "bad", Length = 42
        }) is null,
            "Packages without a valid source SHA-256 are not advertised.");
    }

    private static void CheckInstalledVersionComparisonMatchesSourceVersionFields()
    {
        Check(WorkspaceUpdateService.IsUpToDate("0.1.0-localdev", "1.0.0") == true,
            "The retained local development build remains treated as current.");
        Check(WorkspaceUpdateService.IsUpToDate("7.1.0+build.3", "7.1.0+build.4") == true,
            "Build metadata does not make the installed semantic version out of date.");
        Check(WorkspaceUpdateService.IsUpToDate("7.0.9", "7.1.0") == false,
            "An older installed release is reported as out of date.");
        Check(WorkspaceUpdateService.IsUpToDate("unparseable", "7.1.0") is null &&
              WorkspaceUpdateService.IsUpToDate("7.1.0", null) is null,
            "Unknown version comparisons stay unavailable instead of inventing update status.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
