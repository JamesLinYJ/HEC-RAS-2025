using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class BugReportChecks
{
    internal static void Run()
    {
        string applicationLog = string.Concat(Enumerable.Repeat("backend log tail\n", 3_000));
        string composedLog = BugReportService.ComposeErrorLog(applicationLog, "typed crash context");
        string[] logSections = composedLog.Split('\n', 2);
        XElement moduleInventory = XElement.Parse(logSections[0]);
        Check(moduleInventory.Name == "Modules" &&
              (string?)moduleInventory.Attribute("Scope") == "backend-process" &&
              (string?)moduleInventory.Attribute("Architecture") ==
                  System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
            "The report log starts with a typed inventory for the current backend process and architecture");
        Check(composedLog.Contains("Crash context: typed crash context", StringComparison.Ordinal) &&
              composedLog.EndsWith("backend log tail\n", StringComparison.Ordinal) &&
              Encoding.UTF8.GetByteCount(composedLog) <= BugReportService.MaximumLogBytes,
            "The module inventory, crash context and UTF-8-safe application log tail share the existing report limit");
        Check(moduleInventory.Elements("Module").All(module =>
            {
                string name = (string?)module.Attribute("Name") ?? string.Empty;
                string? sha256 = (string?)module.Attribute("SHA256");
                return !name.Contains('/') && !name.Contains('\\') &&
                    (sha256 is null || (sha256.Length == 64 && sha256.All(Uri.IsHexDigit)));
            }),
            "Module entries contain basenames and full-content SHA-256 values, never absolute paths");

        var backendAssembly = typeof(BugReportService).Assembly;
        using (var backendAssemblyStream = new FileStream(backendAssembly.Location, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            string expectedAssemblyHash = Convert.ToHexString(SHA256.HashData(backendAssemblyStream));
            Check(moduleInventory.Elements("Module").Any(module =>
                    (string?)module.Attribute("Name") == Path.GetFileName(backendAssembly.Location) &&
                    (string?)module.Attribute("Kind") == "managed" &&
                    (string?)module.Attribute("SHA256") == expectedAssemblyHash),
                "The loaded backend assembly is listed with its exact on-disk content SHA-256");
            string? backendAssemblyDirectory = Path.GetDirectoryName(backendAssembly.Location);
            Check(!composedLog.Contains(backendAssembly.Location, StringComparison.Ordinal) &&
                  (string.IsNullOrEmpty(backendAssemblyDirectory) ||
                   !moduleInventory.ToString(SaveOptions.DisableFormatting).Contains(backendAssemblyDirectory,
                       StringComparison.Ordinal)),
                "The uploaded module inventory does not include the backend assembly path");
        }

        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Bug Report Project.ras");
        string geometryPath;
        const string geometryName = "Report Geometry";
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Geometry geometry = project.AddNewGeometry(geometryName);
        geometry.Save();
        project.Save();
        geometryPath = geometry.Filename;
        Dispose(project);

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] geometryBytes = File.ReadAllBytes(geometryPath);
        string projectRevision = HashFile(projectPath);
        string geometryRevision = HashFile(geometryPath);
        XElement draft = XElement.Load(projectPath);
        draft.Element("Description")?.Remove();
        draft.Add(new XElement("Description", "Unsaved report description"));
        string projectXml = draft.ToString(SaveOptions.DisableFormatting);
        string fingerprint = HashText(projectXml);
        var request = new BugReportGeometryCaptureRequest(projectPath, projectRevision, projectXml,
            fingerprint, geometryPath, geometryName, geometryPath, geometryRevision);

        BugReportGeometryCapture capture = BugReportService.CaptureGeometry(request);
        Check(capture.ProjectPath == Path.GetFullPath(projectPath) &&
              capture.ProjectRevision == projectRevision && capture.ProjectXmlFingerprint == fingerprint &&
              capture.GeometryAssetID == Path.GetFullPath(geometryPath) &&
              capture.GeometryPath == Path.GetFullPath(geometryPath) &&
              capture.GeometryName == geometryName && capture.GeometryRevision == geometryRevision,
            "Capture returns the exact draft fingerprint, saved Project SHA and selected Geometry identity");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(geometryPath).SequenceEqual(geometryBytes),
            "Capture reads the source Project and Geometry without writing either file");

        Reject(() => BugReportService.CaptureGeometry(request with { ProjectXmlFingerprint = new string('0', 64) }),
            "A mismatched draft fingerprint is rejected before source use");
        Reject(() => BugReportService.CaptureGeometry(request with { ExpectedGeometryRevision = new string('0', 64) }),
            "A stale Geometry SHA is rejected before opening the selected HDF");

        string otherDirectory = Path.Combine(temporary.FullName, "Other Owner");
        Directory.CreateDirectory(otherDirectory);
        string otherProjectPath = Path.Combine(otherDirectory, "Other.ras");
        Project otherProject = Project.CreateNew(otherProjectPath, UnitSystem.SI);
        Geometry otherGeometry = otherProject.AddNewGeometry(geometryName);
        otherGeometry.Save();
        otherProject.Save();
        string otherGeometryPath = otherGeometry.Filename;
        Dispose(otherProject);
        Reject(() => BugReportService.CaptureGeometry(request with
            {
                GeometryAssetID = otherGeometryPath,
                GeometryPath = otherGeometryPath,
                ExpectedGeometryRevision = HashFile(otherGeometryPath)
            }), "A same-named Geometry owned by another Project is rejected");
        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes) &&
              File.ReadAllBytes(geometryPath).SequenceEqual(geometryBytes) &&
              File.ReadAllBytes(otherGeometryPath).Length > 0,
            "Rejected cross-Project identity leaves every source file untouched");

        try
        {
            File.AppendAllText(projectPath, "\n", Encoding.UTF8);
            RejectSourceChanged(() => BugReportService.CaptureGeometry(request),
                "A changed Project disk SHA rejects the captured draft");
        }
        finally { File.WriteAllBytes(projectPath, projectBytes); }

        try
        {
            File.AppendAllText(geometryPath, "stale", Encoding.UTF8);
            RejectSourceChanged(() => BugReportService.CaptureGeometry(request),
                "A changed Geometry HDF SHA rejects the captured source");
        }
        finally { File.WriteAllBytes(geometryPath, geometryBytes); }

        BugReportService.ValidateSubmission(new BugReportSubmitRequest(
            "abcdefghij", Project.SoftwareVersionStripAllTags, "macOS", "8", "UTC", "", "Title", "Description",
            "", [], [], null, null));
        BugReportService.ValidateSubmission(new BugReportSubmitRequest(
            "abcdefghij", Project.SoftwareVersionStripAllTags, "macOS", "8", "UTC", "", "Title", "Description",
            "", [], [new BugReportImage("screen.png", "image/png",
                [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])], null, null));
        Reject(() => BugReportService.ValidateSubmission(new BugReportSubmitRequest(
            "abcdefghij", Project.SoftwareVersionStripAllTags, "macOS", "8", "UTC", "", "Title", "Description",
            "", [], [new BugReportImage("screen.png", "image/png", [0x00])], null, null)),
            "A screenshot with a PNG name and MIME type but invalid content is rejected");
        Reject(() => BugReportService.ValidateSubmission(new BugReportSubmitRequest(
            "abcdefghij", Project.SoftwareVersionStripAllTags, "macOS", "8", "UTC", "", "", "Description",
            "", [], [], null, null)), "An empty report title is rejected locally");

        Console.WriteLine("Bug report capture binds the current Project draft and exact source Geometry without changing source files.");
    }

    private static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string HashText(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private static void Reject(Action action, string message)
    {
        try { action(); }
        catch (ArgumentException) { return; }
        catch (IOException) { return; }
        throw new InvalidOperationException(message);
    }

    private static void RejectSourceChanged(Action action, string message)
    {
        try { action(); }
        catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException(message);
    }

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                     .Concat(project.Geometries).Concat(project.Terrains)
                     .Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers))
            layer.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
