using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Geospatial.GDALAssist;
using Geospatial.Rasters.Classifications;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class CatalogModelActionChecks
{
    internal static void Run()
    {
        GDALSetup.InitializeMultiplatform();
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "目录动作验收.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        Terrain terrain = project.AddNewTerrain("动作地形");
        string terrainRasterPath = Path.Combine(terrain.SourceDirectory, "地形来源.tif");
        CreateRaster(terrainRasterPath, DataType.GDT_Float32, 42);
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, terrainRasterPath));
        NValueLayer nvalue = project.AddNewNValueLayer("动作糙率");
        ClassificationLayer classification = project.AddNewClassification("动作分类");
        string classificationRasterPath = Path.Combine(classification.SourceDirectory, "分类来源.tif");
        CreateRaster(classificationRasterPath, DataType.GDT_Int32, 7);
        var classDefinition = new Classification();
        classDefinition.Set(7, "草地");
        classification.AddNewRasterLayer(classificationRasterPath, classDefinition);
        nvalue.SetTrackClassificationLayer(classification);
        nvalue.InterpretationTable.Set("草地", 0.035f);
        Geometry geometry = project.AddNewGeometry("动作几何", terrain, nvalue);
        Geometry secondaryGeometry = project.AddNewGeometry("非默认几何", terrain, nvalue);
        BoundaryCondition boundary = project.AddNewBoundaryCondition("动作边界");
        Plan plan = project.AddNewPlan("动作方案", geometry, boundary);
        Plan secondaryPlan = project.AddNewPlan("非默认方案", secondaryGeometry, boundary);
        project.Save();

        string terrainPath = Path.GetFullPath(terrain.Filename);
        string nvaluePath = Path.GetFullPath(nvalue.Filename);
        string classificationPath = Path.GetFullPath(classification.Filename);
        string geometryPath = Path.GetFullPath(secondaryGeometry.Filename);
        string boundaryPath = Path.GetFullPath(boundary.Filename);
        string planPath = Path.GetFullPath(secondaryPlan.Filename);
        XElement editorMetadata = XElement.Load(projectPath);
        Check(editorMetadata.Element("DefaultTerrain") is null,
            "The source project may omit its DefaultTerrain element when the default is implicit");
        byte[] originalProject = File.ReadAllBytes(projectPath);
        Dispose(project);

        var assets = new[]
        {
            ("Terrain", terrainPath),
            ("NValue", nvaluePath),
            ("Classification", classificationPath),
            ("Geometry", geometryPath),
            ("BoundaryCondition", boundaryPath),
            ("Plan", planPath)
        };
        ExportAcceptanceFixture(temporary.FullName, projectPath, assets);
        var inspections = new Dictionary<string, CatalogModelActionInspection>(StringComparer.Ordinal);
        foreach ((string kind, string path) in assets)
        {
            CatalogModelActionInspection inspection = CatalogModelActionService.Inspect(Request(
                projectPath, editorMetadata, path, kind, Hash(path), "inspect"));
            Check(inspection.Kind == kind && inspection.Name == Path.GetFileNameWithoutExtension(path) &&
                  SameExistingFileIdentity(inspection.CanonicalAssetPath, path),
                $"{kind} inspection resolves exactly the selected source model");
            Check(inspection.AvailableActions.Contains("clone") && inspection.AvailableActions.Contains("delete"),
                $"{kind} exposes the retained clone and delete capabilities");
            inspections.Add(kind, inspection);
        }

        CatalogModelActionInspection terrainInspection = inspections["Terrain"];
        CatalogModelActionReceipt rename = CatalogModelActionService.Perform(Request(projectPath,
            editorMetadata, terrainPath, "Terrain", terrainInspection.Revision, "rename", "改名地形"));
        Check(rename.OriginalName == "动作地形" && rename.OriginalSHA == terrainInspection.Revision,
            "Rename receipt keeps the source layer name and the inspected content revision");
        Check(rename.StagedTargets.Length == 1 && File.Exists(rename.StagedTargets[0].StagePath) &&
              !File.Exists(rename.StagedTargets[0].TargetPath) && rename.StagedTargets[0].ExpectedTargetSHA is null,
            "Rename stages a new HDF5 without publishing over an existing target");
        Check(rename.TrashPaths is [{ OriginalAsset: true } trash] &&
              trash.Path == terrainPath && trash.Revision == terrainInspection.Revision,
            "Rename receipt identifies the original entry and its inspected SHA for reversible Trash");
        Check(rename.MetadataMutations.Any(item => item.Section == "GeometryAssociations" &&
              item.RowName == "GeometryAssociation" && item.IdentityAttribute == "Geometry" &&
              item.IdentityValue == "动作几何" && item.Attribute == "Terrain" &&
              item.OldValue == "动作地形" && item.NewValue == "改名地形"),
            "Rename prepares the exact geometry association delta for the current project XML");
        Check(rename.MetadataMutations.All(item => item.RowName != "DefaultTerrain"),
            "Terrain rename does not synthesize an omitted DefaultTerrain XML element");
        CatalogModelActionStagingDirectory renameStage = rename.StagingDirectories.Single();
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  renameStage.Path, renameStage.Token)),
            "Owned rename staging can be cleaned by its receipt token");

        CatalogModelActionReceipt clone = CatalogModelActionService.Perform(Request(projectPath,
            editorMetadata, terrainPath, "Terrain", terrainInspection.Revision, "clone"));
        Check(clone.ActualClone && clone.MetadataMutations.Length == 0 &&
              clone.TrashPaths is { Length: 0 } && clone.StagedTargets.Length == 1 &&
              File.Exists(clone.StagedTargets[0].StagePath) && !File.Exists(clone.StagedTargets[0].TargetPath),
            "Clone produces a source-backed staged copy without changing associations or deleting the original");
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  clone.StagingDirectories.Single().Path, clone.StagingDirectories.Single().Token)),
            "Owned clone staging can be cleaned by its receipt token");

        XElement geometryRenameMetadata = new(editorMetadata);
        XElement geometryAssociation = geometryRenameMetadata.Element("GeometryAssociations")!
            .Elements("GeometryAssociation").Single(item => (string?)item.Attribute("Geometry") == "非默认几何");
        string? retainedTerrain = (string?)geometryAssociation.Attribute("Terrain");
        string? retainedNValue = (string?)geometryAssociation.Attribute("N_Values");
        geometryAssociation.SetAttributeValue("ExtensionData", "retain-me");
        CatalogModelActionInspection geometryInspection = inspections["Geometry"];
        CatalogModelActionReceipt geometryRename = CatalogModelActionService.Perform(Request(projectPath,
            geometryRenameMetadata, geometryPath, "Geometry", geometryInspection.Revision,
            "rename", "改名几何"));
        CatalogModelActionMetadataMutation geometryIdentity = geometryRename.MetadataMutations.Single(item =>
            item.Section == "GeometryAssociations" && item.RowName == "GeometryAssociation" &&
            item.IdentityAttribute == "Geometry" && item.IdentityValue == "非默认几何" &&
            item.Attribute == "Geometry");
        Check(geometryIdentity.OldValue == "非默认几何" && geometryIdentity.NewValue == "改名几何",
            "Geometry rename changes its own non-default association-row identity");
        Check(geometryRename.MetadataMutations.Any(item => item.Section == "PlanAssociations" &&
              item.RowName == "PlanAssociation" && item.IdentityAttribute == "Plan" &&
              item.IdentityValue == "非默认方案" && item.Attribute == "Geometry" &&
              item.OldValue == "非默认几何" && item.NewValue == "改名几何"),
            "Geometry rename updates the non-default plan row that references it");
        Check(!geometryRename.MetadataMutations.Any(item => item.IdentityValue == "非默认几何" &&
              item.Section == "GeometryAssociations" && item.Attribute is "Terrain" or "N_Values") &&
              (string?)geometryAssociation.Attribute("Terrain") == retainedTerrain &&
              (string?)geometryAssociation.Attribute("N_Values") == retainedNValue &&
              (string?)geometryAssociation.Attribute("ExtensionData") == "retain-me",
            "Geometry identity patch leaves its terrain, N-value, and unknown association attributes intact");
        Check(!geometryRename.MetadataMutations.Any(item => item.IdentityValue == "动作几何" ||
              item.IdentityValue == "动作方案"),
            "Geometry rename does not rewrite the sibling default geometry/plan associations");
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  geometryRename.StagingDirectories.Single().Path, geometryRename.StagingDirectories.Single().Token)),
            "Owned geometry rename staging can be cleaned by its receipt token");

        XElement planRenameMetadata = new(editorMetadata);
        XElement planAssociation = planRenameMetadata.Element("PlanAssociations")!
            .Elements("PlanAssociation").Single(item => (string?)item.Attribute("Plan") == "非默认方案");
        string? retainedPlanGeometry = (string?)planAssociation.Attribute("Geometry");
        string? retainedBoundary = (string?)planAssociation.Attribute("BoundaryCondition");
        planAssociation.SetAttributeValue("ExtensionData", "retain-me");
        CatalogModelActionInspection planInspection = inspections["Plan"];
        CatalogModelActionReceipt planRename = CatalogModelActionService.Perform(Request(projectPath,
            planRenameMetadata, planPath, "Plan", planInspection.Revision, "rename", "改名方案"));
        CatalogModelActionMetadataMutation planIdentity = planRename.MetadataMutations.Single(item =>
            item.Section == "PlanAssociations" && item.RowName == "PlanAssociation" &&
            item.IdentityAttribute == "Plan" && item.IdentityValue == "非默认方案" &&
            item.Attribute == "Plan");
        Check(planIdentity.OldValue == "非默认方案" && planIdentity.NewValue == "改名方案",
            "Plan rename changes its own non-default association-row identity");
        Check(!planRename.MetadataMutations.Any(item => item.IdentityValue == "非默认方案" &&
              item.Section == "PlanAssociations" && item.Attribute is "Geometry" or "BoundaryCondition") &&
              (string?)planAssociation.Attribute("Geometry") == retainedPlanGeometry &&
              (string?)planAssociation.Attribute("BoundaryCondition") == retainedBoundary &&
              (string?)planAssociation.Attribute("ExtensionData") == "retain-me",
            "Plan identity patch preserves both associated models and unknown association attributes");
        Check(!planRename.MetadataMutations.Any(item => item.IdentityValue == "动作方案"),
            "Plan rename leaves the sibling plan association untouched");
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  planRename.StagingDirectories.Single().Path, planRename.StagingDirectories.Single().Token)),
            "Owned plan rename staging can be cleaned by its receipt token");

        CatalogModelActionReceipt deletion = CatalogModelActionService.Perform(Request(projectPath,
            editorMetadata, terrainPath, "Terrain", terrainInspection.Revision, "delete"));
        Check(File.Exists(terrainPath) && File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Delete preparation leaves the HDF5 and project file untouched for the workspace Trash transaction");
        Check(deletion.TrashPaths is { Length: 2 } && deletion.TrashPaths.Count(item => item.OriginalAsset) == 1 &&
              deletion.TrashPaths.Any(item => SameExistingFileIdentity(item.Path, terrainRasterPath) &&
                  item.Revision == Hash(terrainRasterPath)) &&
              deletion.DeleteDependencies.Any(item => item.Kind == "Geometry" && item.Name == "动作几何"),
            "Delete receipt names the exact HDF5 and terrain backing raster to Trash and exposes the dependent geometry");
        Check(deletion.MetadataMutations.Any(item => item.Section == "GeometryAssociations" &&
              item.IdentityValue == "动作几何" && item.Attribute == "Terrain" && item.OldValue == "动作地形"),
            "Terrain delete prepares a precise geometry association delta");

        CatalogModelActionInspection classificationInspection = inspections["Classification"];
        CatalogModelActionReceipt classificationRename = CatalogModelActionService.Perform(Request(projectPath,
            editorMetadata, classificationPath, "Classification", classificationInspection.Revision,
            "rename", "改名分类"));
        string renamedClassificationPath = classificationRename.NewAssetPath!;
        CatalogModelActionStagedTarget classificationHdf = classificationRename.StagedTargets.Single(item =>
            SameDestinationIdentity(item.TargetPath, renamedClassificationPath));
        CatalogModelActionStagedTarget linkedNValueHdf = classificationRename.StagedTargets.Single(item =>
            SameExistingFileIdentity(item.TargetPath, nvaluePath));
        Check(classificationRename.StagedTargets.Length == 2 && linkedNValueHdf.ExpectedTargetSHA == Hash(nvaluePath),
            "Classification rename stages the associated N-value HDF against its inspected target revision");
        using (var linkedNValue = new NValueLayer(linkedNValueHdf.StagePath))
            Check(linkedNValue.Mode == NValueSource.ClassificationLayer &&
                  linkedNValue.ClassificationLayerName == "改名分类",
                "The staged N-value HDF persists its renamed Classification relationship");
        Check(classificationRename.TrashPaths is [{ OriginalAsset: true }] &&
              !classificationRename.TrashPaths.Any(item =>
                  SameExistingFileIdentity(item.Path, classificationRasterPath)),
            "Classification rename trashes only the old HDF and retains its external raster input");

        CatalogModelActionReceipt classificationDeletion = CatalogModelActionService.Perform(Request(projectPath,
            editorMetadata, classificationPath, "Classification", classificationInspection.Revision, "delete"));
        Check(classificationDeletion.TrashPaths is { Length: 2 } &&
              classificationDeletion.TrashPaths.Any(item =>
                  SameExistingFileIdentity(item.Path, classificationRasterPath)) &&
              classificationDeletion.DeleteDependencies.Any(item => item.Kind == "NValue" && item.Name == "动作糙率"),
            "Classification delete exposes its raster backing file and linked N-value dependency");

        File.Copy(classificationHdf.StagePath, renamedClassificationPath, overwrite: false);
        File.Copy(linkedNValueHdf.StagePath, nvaluePath, overwrite: true);
        var reopenedProject = new Project(projectPath);
        try
        {
            NValueLayer reopenedNValue = reopenedProject.NValues.Single(item => item.Name == "动作糙率");
            Check(reopenedNValue.ClassificationLayerName == "改名分类" &&
                  reopenedNValue.AssociatedClassificationLayer?.Name == "改名分类" &&
                  SameExistingFileIdentity(
                      reopenedNValue.AssociatedClassificationLayer.AllRasterInputs().Single().Filename,
                      classificationRasterPath),
                "Independent project reload resolves the renamed classification and preserves the real raster input");
        }
        finally { Dispose(reopenedProject); }
        CatalogModelActionStagingDirectory classificationStage = classificationRename.StagingDirectories.Single();
        Check(CatalogModelActionService.Cleanup(new CatalogModelActionCleanupRequest(
                  classificationStage.Path, classificationStage.Token)),
            "Owned classification/N-value staging can be cleaned after independent source reload");

        byte[] oldClassification = File.ReadAllBytes(classificationPath);
        File.WriteAllBytes(classificationPath, oldClassification.Concat(new byte[] { 0x5A }).ToArray());
        bool staleRejected = false;
        try
        {
            _ = CatalogModelActionService.Perform(Request(projectPath, editorMetadata, classificationPath,
                "Classification", inspections["Classification"].Revision, "delete"));
        }
        catch (SourceFileChangedException) { staleRejected = true; }
        Check(staleRejected && File.Exists(classificationPath) && File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "An old inspection revision cannot adopt a replaced model or mutate project metadata");
        File.WriteAllBytes(classificationPath, oldClassification);

        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Inspect, rename staging, clone staging, and delete preparation never save the project XML");
        Console.WriteLine("Catalog model action source inspection, staging, dependency, stale-SHA, and read-only checks passed.");
    }

    private static CatalogModelActionRequest Request(string projectPath, XElement editorMetadata,
        string assetPath, string kind, string revision, string action, string? name = null) =>
        new(projectPath, editorMetadata.ToString(SaveOptions.DisableFormatting), assetPath, kind, revision, action, name);

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static bool SameExistingFileIdentity(string actualPath, string expectedPath)
    {
        if (!Path.IsPathFullyQualified(actualPath) || !Path.IsPathFullyQualified(expectedPath) ||
            !File.Exists(actualPath) || !File.Exists(expectedPath)) return false;
        return string.Equals(Path.GetFileName(actualPath), Path.GetFileName(expectedPath), StringComparison.Ordinal) &&
               string.Equals(Hash(actualPath), Hash(expectedPath), StringComparison.Ordinal);
    }

    private static bool SameDestinationIdentity(string actualPath, string expectedPath)
    {
        if (!Path.IsPathFullyQualified(actualPath) || !Path.IsPathFullyQualified(expectedPath)) return false;
        string actualParent = Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(actualPath))!);
        string expectedParent = Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(expectedPath))!);
        return string.Equals(Path.GetFileName(actualPath), Path.GetFileName(expectedPath), StringComparison.Ordinal) &&
               string.Equals(actualParent, expectedParent, StringComparison.Ordinal);
    }

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
        string? configuredPath = Environment.GetEnvironmentVariable("HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string destination = Path.GetFullPath(configuredPath);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The catalog model action acceptance destination already exists.");

        string[] files = Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories);
        Directory.CreateDirectory(destination);
        foreach (string source in files)
        {
            string relative = Path.GetRelativePath(sourceDirectory, source);
            string target = Path.Combine(destination, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(source, target, overwrite: false);
        }

        var manifest = new CatalogModelActionAcceptanceManifest(
            Path.GetRelativePath(sourceDirectory, projectPath),
            assets.Select(item => new CatalogModelActionAcceptanceAsset(item.Kind,
                Path.GetFileNameWithoutExtension(item.Path),
                Path.GetRelativePath(sourceDirectory, item.Path))).ToArray());
        File.WriteAllText(Path.Combine(destination, "manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
    }

    private sealed record CatalogModelActionAcceptanceAsset(string Kind, string Name, string AssetPath);
    private sealed record CatalogModelActionAcceptanceManifest(string ProjectPath,
        CatalogModelActionAcceptanceAsset[] Models);

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
}
