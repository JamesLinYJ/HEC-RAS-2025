using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class ModelEditorChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "模型读写.ras");
        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var plan = project.AddNewPlan("原计划");
        plan.TimeWindowMode = PlanTimeWindowMode.BoundaryCondition;
        var geometry = project.AddNewGeometry("原几何");
        var boundary = project.AddNewBoundaryCondition("原边界", new DateTime(2026, 10, 15, 8, 0, 0), TimeSpan.FromHours(2));
        var terrain = project.AddNewTerrain("原地形");
        var nvalues = project.AddNewNValueLayer("原糙率");
        var classification = project.AddNewClassification("原分类");
        CoreLayerBase[] layers = [plan, geometry, boundary, terrain, nvalues, classification];
        var specifications = new[]
        {
            ("Plan", "PlanSettingsPage/ViewModel_SelectedPlan_Description", "/Plan Data"),
            ("Geometry", "GeometrySummaryPage/ViewModel_SelectedGeometryVisualContext_Context_Description", Geometry.HDF5Group),
            ("Boundary Conditions", "BoundaryConditionsSummary/BoundaryCondition_Description", BoundaryCondition.HDFGroupName),
            ("Terrain", "TerrainCatalogSummary/Context_Description", Terrain.HDF5Group),
            ("Surface Layers", "NValueCatalogSummary/Context_Description", NValueLayer.HDF5Group),
            ("Surface Layers", "ClassificationCatalogSummary/Context_Description", ClassificationLayer.HDF5Group)
        };
        project.Save();
        foreach (var layer in layers)
        {
            layer.Save();
            layer.Dispose();
        }
        for (int i = 0; i < layers.Length; i++)
        {
            string filename = layers[i].Filename;
            var (kind, field, group) = specifications[i];
            using (var writer = new H5Assist.H5Writer(filename)) writer.WriteAttribute(group, "Unknown Editor Metadata", "仍然保留");
            var request = new ModelRequest(filename, kind, projectPath);
            var loaded = await ModelEditorAdapter.LoadAsync(request);
            Check(loaded.CanEdit && loaded.Fields.ContainsKey(field), kind + " exposes its actual source property");
            if (kind == "Plan")
            {
                const string solverField = "PlanSettingsPage/ViewModel_SelectedPlan_SolverType";
                SourceEditorChoice[] solverChoices = loaded.FieldChoices?.GetValueOrDefault(solverField) ?? [];
                Check(solverChoices.Length == 2 && solverChoices.Select(choice => choice.Id).SequenceEqual(["CPU", "GPU"]),
                    "Plan solver choices retain the source enum order and IDs");
                Check(solverChoices[0].SourceIcon == "CPUColored1" &&
                    solverChoices[0].Description == "Use the explicit CPU solver" &&
                    solverChoices[1].SourceIcon == "GPUColored" &&
                    (solverChoices[1].Description == "No NVIDIA GPU detected. You can try running the GPU solver to check for driver errors" ||
                     solverChoices[1].Description?.StartsWith("Use the explicit GPU solver with device: ", StringComparison.Ordinal) == true),
                    "Plan solver presentation carries source icon and live GPU-probe description metadata");
                var unitTitles = loaded.FieldTitles ?? [];
                string[] expectedUnitFields =
                [
                    "ViewModel_SelectedPlan_PartialGridElevationTolerance",
                    "ViewModel_SelectedPlan_VolumeTolerance",
                    "ViewModel_SelectedPlan_VolumeMaxTolerance",
                    "ViewModel_SelectedPlan_VolumeRMSTolerance",
                    "ViewModel_SelectedPlan_WaterSurfaceTolerance",
                    "ViewModel_SelectedPlan_WaterSurfaceMaxTolerance",
                    "ViewModel_SelectedPlan_WaterSurfaceRMSTolerance"
                ];
                Check(expectedUnitFields.All(id => unitTitles.GetValueOrDefault("PlanComputeSettingsPage/" + id)?.EndsWith(" (m)", StringComparison.Ordinal) == true),
                    "Plan tolerance titles use the owning source project unit system");
            }
            string text = "从 SwiftUI 服务编辑的" + layers[i].Name + " 🌊";
            var saved = await ModelEditorAdapter.SaveAsync(new(filename, kind, projectPath, loaded.Revision, new() { [field] = text }, []));
            Check(saved.Fields[field] == text, kind + " independently reloads its real HDF edit");
            using var reader = new H5Assist.H5Reader(filename);
            Check(reader.TryReadStringAttributeScalar(group, "Unknown Editor Metadata") == "仍然保留", kind + " preserves unknown HDF metadata");
        }
        byte[] original = File.ReadAllBytes(projectPath);
        XElement metadata = XElement.Load(projectPath);
        metadata.Elements("PlanAssociations").Remove();
        metadata.Add(new XElement("PlanAssociations", new XElement("PlanAssociation", new XAttribute("Plan", plan.Name),
            new XAttribute("Geometry", geometry.Name), new XAttribute("BoundaryCondition", boundary.Name))));
        var draftRequest = new ModelRequest(plan.Filename, "Plan", projectPath, metadata.ToString());
        var withDraft = await ModelEditorAdapter.LoadAsync(draftRequest);
        DateTime actualStart = DateTimeOffset.Parse(withDraft.Fields["PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"]).LocalDateTime;
        Check(actualStart == boundary.StartTime, "Unsaved project associations feed the actual source plan time window");
        await ModelEditorAdapter.SaveAsync(new(plan.Filename, "Plan", projectPath, withDraft.Revision,
            new() { ["PlanSettingsPage/ViewModel_SelectedPlan_Description"] = "使用未保存关联的计划" }, [], metadata.ToString()));
        Check(File.ReadAllBytes(projectPath).SequenceEqual(original), "Model reads and saves never auto-save the project draft");
        Check(!Directory.EnumerateFiles(directory.FullName, ".model-edit-*.pending", SearchOption.AllDirectories).Any(), "All model edits clean their working copies");
        Console.WriteLine("Real plan, geometry, boundary, terrain, Manning and classification HDF editor roundtrips and unsaved source associations passed.");
    }
    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
}
