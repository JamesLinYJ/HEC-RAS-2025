using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Ras.Observables;
using Utility.Units;

internal static class CatalogModelContextActionChecks
{
    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "目录重复动作.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("重复地形");
        string terrainRasterPath = Path.Combine(terrain.SourceDirectory, "重复地形输入.tif");
        CreateRaster(terrainRasterPath, DataType.GDT_Float32, 4.25);
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, terrainRasterPath));
        NValueLayer nvalue = project.AddNewNValueLayer("重复糙率");
        nvalue.InterpretationTable.Set("草地", 0.035f);
        Geometry geometry = project.AddNewGeometry("源几何", terrain, nvalue);
        BoundaryCondition boundary = project.AddNewBoundaryCondition("重复边界");
        Plan plan = project.AddNewPlan("源方案", geometry, boundary);
        project.Save();

        string geometryPath = Path.GetFullPath(geometry.Filename);
        string planPath = Path.GetFullPath(plan.Filename);
        XElement editorMetadata = XElement.Load(projectPath);
        byte[] originalProject = File.ReadAllBytes(projectPath);
        var originalAssetRevisions = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [geometryPath] = Hash(geometryPath),
            [planPath] = Hash(planPath),
            [Path.GetFullPath(terrain.Filename)] = Hash(terrain.Filename),
            [Path.GetFullPath(nvalue.Filename)] = Hash(nvalue.Filename),
            [Path.GetFullPath(boundary.Filename)] = Hash(boundary.Filename)
        };
        Dispose(project);

        ExportAcceptanceFixture(temporary.FullName, projectPath,
            [("Geometry", geometryPath), ("Plan", planPath)]);
        VerifyDuplicateRedirectPrimitive(projectPath, geometryPath, originalProject,
            originalAssetRevisions, temporary.FullName);

        CatalogModelActionInspection geometryInspection = Inspect(projectPath, editorMetadata, geometryPath, "Geometry");
        Check(geometryInspection.AvailableActions.Contains("duplicate") &&
              geometryInspection.AvailableActions.Contains("clone"),
            "Geometry context duplicate is exposed without replacing inspector clone");
        CatalogModelActionReceipt geometryReceipt = Duplicate(projectPath, editorMetadata,
            geometryPath, "Geometry", geometryInspection.Revision);
        VerifyStagedReceipt(geometryReceipt, "Geometry", "Source Geometry context behavior creates one new HDF5");
        Check(geometryReceipt.MetadataMutations.Any(item => item.Section == "GeometryAssociations" &&
              item.RowName == "GeometryAssociation" && item.IdentityAttribute == "Geometry" &&
              item.IdentityValue == geometryReceipt.NewName && item.Attribute == "Terrain" &&
              item.OldValue is null && item.NewValue == "重复地形") &&
              geometryReceipt.MetadataMutations.Any(item => item.IdentityValue == geometryReceipt.NewName &&
                  item.Attribute == "N_Values" && item.NewValue == "重复糙率"),
            "Geometry duplicate receipt preserves Terrain and N-Value associations in project XML delta");
        VerifySourceFilesUnchanged(originalProject, projectPath, originalAssetRevisions);
        ReopenGeometryDuplicate(projectPath, editorMetadata, geometryReceipt);
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  geometryReceipt.StagingDirectories.Single().Path,
                  geometryReceipt.StagingDirectories.Single().Token)),
            "Geometry duplicate staging cleanup accepts only the receipt-owned token");

        CatalogModelActionInspection planInspection = Inspect(projectPath, editorMetadata, planPath, "Plan");
        CatalogModelActionReceipt planReceipt = Duplicate(projectPath, editorMetadata,
            planPath, "Plan", planInspection.Revision);
        VerifyStagedReceipt(planReceipt, "Plan", "Source Plan context behavior creates one new HDF5");
        Check(planReceipt.MetadataMutations.Any(item => item.Section == "PlanAssociations" &&
              item.RowName == "PlanAssociation" && item.IdentityAttribute == "Plan" &&
              item.IdentityValue == planReceipt.NewName && item.Attribute == "Geometry" &&
              item.OldValue is null && item.NewValue == "源几何") &&
              planReceipt.MetadataMutations.Any(item => item.IdentityValue == planReceipt.NewName &&
                  item.Attribute == "BoundaryCondition" && item.NewValue == "重复边界"),
            "Plan duplicate receipt preserves Geometry and BoundaryCondition associations");
        VerifySourceFilesUnchanged(originalProject, projectPath, originalAssetRevisions);
        ReopenPlanDuplicate(projectPath, editorMetadata, planReceipt);
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  planReceipt.StagingDirectories.Single().Path,
                  planReceipt.StagingDirectories.Single().Token)),
            "Plan duplicate staging cleanup accepts only the receipt-owned token");

        VerifyDuplicateFailureDoesNotLeak(projectPath, editorMetadata, geometryPath,
            geometryInspection.Revision, originalProject, originalAssetRevisions);
        VerifyStaleInspectionRejected(projectPath, editorMetadata, geometryPath,
            geometryInspection.Revision, originalProject);
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Geometry/Plan duplicate staging and inspection never save the source project XML");
        Console.WriteLine("Catalog model source context duplicate, associations, independent reopen, and cleanup checks passed.");
    }

    private static CatalogModelActionInspection Inspect(string projectPath, XElement editorMetadata,
        string assetPath, string kind) => CatalogModelActionService.Inspect(Request(
        projectPath, editorMetadata, assetPath, kind, Hash(assetPath), "inspect"));

    private static CatalogModelActionReceipt Duplicate(string projectPath, XElement editorMetadata,
        string assetPath, string kind, string revision) => CatalogModelActionService.Perform(Request(
        projectPath, editorMetadata, assetPath, kind, revision, "duplicate"));

    private static CatalogModelActionRequest Request(string projectPath, XElement editorMetadata,
        string assetPath, string kind, string revision, string action) => new(projectPath,
        editorMetadata.ToString(SaveOptions.DisableFormatting), assetPath, kind, revision, action);

    private static void VerifyStagedReceipt(CatalogModelActionReceipt receipt, string kind, string assertion)
    {
        CatalogModelActionStagedTarget staged = receipt.StagedTargets.Single();
        Check(receipt.Action == "duplicate" && receipt.Kind == kind && receipt.ActualClone &&
              receipt.OriginalSHA.Length == 64 && receipt.NewName == Path.GetFileNameWithoutExtension(staged.TargetPath) &&
              receipt.NewAssetPath == staged.TargetPath && staged.ExpectedTargetSHA is null &&
              File.Exists(staged.StagePath) && !File.Exists(staged.TargetPath) &&
              Hash(staged.StagePath) == staged.StageSHA &&
              Path.GetFileName(Path.GetDirectoryName(staged.StagePath)!) == receipt.StagingDirectories.Single().Token,
            assertion);
    }

    private static void ReopenGeometryDuplicate(string projectPath, XElement originalMetadata,
        CatalogModelActionReceipt receipt)
    {
        CatalogModelActionStagedTarget staged = receipt.StagedTargets.Single();
        File.Move(staged.StagePath, staged.TargetPath, overwrite: false);
        XElement changedMetadata = ApplyMutations(originalMetadata, receipt.MetadataMutations);
        Project reopened = new(projectPath);
        try
        {
            reopened.ApplyEditorMetadata(changedMetadata);
            Geometry duplicate = reopened.Geometries.Single(item => item.Name == receipt.NewName);
            GeometryAssociation association = reopened.GetGeometryAssociation(duplicate);
            Check(association.Terrain?.Name == "重复地形" && association.NValueLayer?.Name == "重复糙率",
                "Independent Geometry reload resolves both source-associated models");
        }
        finally
        {
            Dispose(reopened);
            File.Delete(staged.TargetPath);
        }
    }

    private static void ReopenPlanDuplicate(string projectPath, XElement originalMetadata,
        CatalogModelActionReceipt receipt)
    {
        CatalogModelActionStagedTarget staged = receipt.StagedTargets.Single();
        File.Move(staged.StagePath, staged.TargetPath, overwrite: false);
        XElement changedMetadata = ApplyMutations(originalMetadata, receipt.MetadataMutations);
        Project reopened = new(projectPath);
        try
        {
            reopened.ApplyEditorMetadata(changedMetadata);
            Plan duplicate = reopened.Plans.Single(item => item.Name == receipt.NewName);
            PlanAssociation association = reopened.GetPlanAssociation(duplicate);
            Check(association.Geometry?.Name == "源几何" &&
                  association.BoundaryCondition?.Name == "重复边界",
                "Independent Plan reload resolves both source-associated models");
        }
        finally
        {
            Dispose(reopened);
            File.Delete(staged.TargetPath);
        }
    }

    private static XElement ApplyMutations(XElement original,
        IEnumerable<CatalogModelActionMetadataMutation> mutations)
    {
        var result = new XElement(original);
        foreach (CatalogModelActionMetadataMutation mutation in mutations)
        {
            XElement section = result.Element(mutation.Section) ?? AddSection(result, mutation.Section);
            XElement? row = section.Elements(mutation.RowName).FirstOrDefault(candidate =>
                (string?)candidate.Attribute(mutation.IdentityAttribute) == mutation.IdentityValue);
            if (row is null)
            {
                row = new XElement(mutation.RowName);
                row.SetAttributeValue(mutation.IdentityAttribute, mutation.IdentityValue);
                section.Add(row);
            }
            if (mutation.Attribute == mutation.IdentityAttribute &&
                mutation.OldValue is null && mutation.NewValue == mutation.IdentityValue)
                continue;
            if (mutation.RemoveRow)
            {
                row.Remove();
                continue;
            }
            row.SetAttributeValue(mutation.Attribute, mutation.NewValue);
        }
        return result;
    }

    private static XElement AddSection(XElement root, string name)
    {
        var section = new XElement(name);
        root.Add(section);
        return section;
    }

    private static void VerifyDuplicateFailureDoesNotLeak(string projectPath, XElement editorMetadata,
        string geometryPath, string inspectedRevision, byte[] originalProject,
        IReadOnlyDictionary<string, string> originalAssetRevisions)
    {
        string unrelatedPath = Path.Combine(Path.GetDirectoryName(geometryPath)!, "源几何 (1).h5");
        string attemptedTarget = Path.Combine(Path.GetDirectoryName(geometryPath)!, "源几何 (2).h5");
        File.Copy(geometryPath, unrelatedPath, overwrite: false);
        string unrelatedRevision = Hash(unrelatedPath);
        XElement conflict = new(editorMetadata);
        XElement? group = conflict.Element("GeometryAssociations");
        if (group is null)
        {
            group = new XElement("GeometryAssociations");
            conflict.Add(group);
        }
        group.Add(new XElement("GeometryAssociation",
            new XAttribute("Geometry", "源几何 (2)"), new XAttribute("Terrain", "重复地形")));

        bool rejected = false;
        try
        {
            _ = Duplicate(projectPath, conflict, geometryPath, "Geometry", inspectedRevision);
        }
        catch (ArgumentException) { rejected = true; }

        string stagingRoot = Path.Combine(Path.GetDirectoryName(geometryPath)!, ".catalog-action-staging");
        Check(rejected && !File.Exists(attemptedTarget) && File.Exists(unrelatedPath) &&
              Hash(unrelatedPath) == unrelatedRevision &&
              (!Directory.Exists(stagingRoot) || !Directory.EnumerateFileSystemEntries(stagingRoot).Any()),
            "An association collision cleans only its token-owned stage and leaves an unrelated source-directory file unchanged");
        VerifySourceFilesUnchanged(originalProject, projectPath, originalAssetRevisions);
        File.Delete(unrelatedPath);
    }

    private static void VerifyDuplicateRedirectPrimitive(string projectPath, string geometryPath,
        byte[] originalProject, IReadOnlyDictionary<string, string> sourceRevisions, string temporaryPath)
    {
        string redirectDirectory = Path.Combine(temporaryPath, "redirected-source-duplicate");
        Directory.CreateDirectory(redirectDirectory);
        Project project = new(projectPath);
        string? redirectedPath = null;
        string? sourceSelectedPath = null;
        bool selectedTargetWasAbsentInCallback = false;
        try
        {
            ObservableProject observableProject = new(project, Utility.SynchronizationContext.None);
            ObservableGeometry geometry = observableProject.Geometries.Single(item => item.Name == "源几何");
            bool duplicated = geometry.DuplicateBySaveAsH5(out string selectedPath, proposedTarget =>
            {
                sourceSelectedPath = proposedTarget;
                selectedTargetWasAbsentInCallback = !File.Exists(proposedTarget) && !Directory.Exists(proposedTarget);
                string redirect = Path.Combine(redirectDirectory, Path.GetFileName(proposedTarget));
                redirectedPath = redirect;
                return redirect;
            });

            Check(duplicated && sourceSelectedPath is not null && redirectedPath is not null &&
                  selectedTargetWasAbsentInCallback &&
                  Path.GetFileName(sourceSelectedPath) == Path.GetFileName(redirectedPath) &&
                  File.Exists(redirectedPath) && !File.Exists(sourceSelectedPath),
                "DuplicateBySaveAsH5 preserves its source-selected basename while redirecting SaveAs before the final target is created");
            Check(selectedPath == sourceSelectedPath,
                "DuplicateBySaveAsH5 returns the original source-selected destination to its caller");
        }
        finally
        {
            Dispose(project);
            if (redirectedPath is not null && File.Exists(redirectedPath)) File.Delete(redirectedPath);
            if (Directory.Exists(redirectDirectory)) Directory.Delete(redirectDirectory, recursive: true);
        }

        VerifySourceFilesUnchanged(originalProject, projectPath, sourceRevisions);
        Check(!File.Exists(Path.Combine(Path.GetDirectoryName(geometryPath)!, "源几何 (1).h5")),
            "Redirected source duplicate never creates the source-selected final destination");
    }

    private static void VerifyStaleInspectionRejected(string projectPath, XElement editorMetadata,
        string geometryPath, string inspectedRevision, byte[] originalProject)
    {
        byte[] originalAsset = File.ReadAllBytes(geometryPath);
        try
        {
            File.WriteAllBytes(geometryPath, originalAsset.Concat(new byte[] { 0x5A }).ToArray());
            bool rejected = false;
            try { _ = Duplicate(projectPath, editorMetadata, geometryPath, "Geometry", inspectedRevision); }
            catch (SourceFileChangedException) { rejected = true; }
            Check(rejected && File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
                "Duplicate rejects an HDF5 whose SHA changed after inspection");
        }
        finally { File.WriteAllBytes(geometryPath, originalAsset); }
    }

    private static void VerifySourceFilesUnchanged(byte[] originalProject, string projectPath,
        IReadOnlyDictionary<string, string> revisions)
    {
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Source project XML bytes remain unchanged by duplicate preparation");
        foreach ((string path, string revision) in revisions)
            Check(File.Exists(path) && Hash(path) == revision,
                $"Source model remains unchanged: {Path.GetFileName(path)}");
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static void CreateRaster(string path, DataType type, double value)
    {
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, 16, 16, 1, type, ["TILED=YES"]);
        dataset.SetGeoTransform([0, 1, 0, 16, 0, -1]);
        using var band = dataset.GetRasterBand(1);
        band.Fill(value, 0);
    }

    private static void ExportAcceptanceFixture(string sourceDirectory, string projectPath,
        (string Kind, string Path)[] assets)
    {
        string? configuredPath = Environment.GetEnvironmentVariable(
            "HECRAS_CATALOG_MODEL_CONTEXT_ACTION_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string destination = Path.GetFullPath(configuredPath);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The catalog model context action acceptance destination already exists.");

        string[] sourceFiles = Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories);
        foreach (string source in sourceFiles)
        {
            string target = Path.Combine(destination, Path.GetRelativePath(sourceDirectory, source));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(source, target, overwrite: false);
        }
        var manifest = new CatalogModelContextActionAcceptanceManifest(
            Path.GetRelativePath(sourceDirectory, projectPath),
            assets.Select(item => new CatalogModelContextActionAcceptanceAsset(item.Kind,
                Path.GetFileNameWithoutExtension(item.Path),
                Path.GetRelativePath(sourceDirectory, item.Path))).ToArray());
        File.WriteAllText(Path.Combine(destination, "manifest.json"),
            JsonSerializer.Serialize(manifest,
                new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
    }

    private sealed record CatalogModelContextActionAcceptanceAsset(string Kind, string Name, string AssetPath);
    private sealed record CatalogModelContextActionAcceptanceManifest(string ProjectPath,
        CatalogModelContextActionAcceptanceAsset[] Models);

    private static void Dispose(Project project)
    {
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries)
                     .Concat(project.Terrains).Concat(project.BoundaryConditions).Concat(project.NValues)
                     .Concat(project.ClassificationLayers)) layer.Dispose();
        foreach (Result result in project.Results) result.Dispose();
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public string FullName { get; } = Path.Combine(Path.GetTempPath(),
            "hecras-catalog-context-" + Guid.NewGuid().ToString("N"));

        public TemporaryDirectory() => Directory.CreateDirectory(FullName);

        public void Dispose()
        {
            if (Directory.Exists(FullName)) Directory.Delete(FullName, recursive: true);
        }
    }
}
