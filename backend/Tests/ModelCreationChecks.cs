using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class ModelCreationChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string path = Path.Combine(temporary.FullName, "新建验收.ras");
        var original = Project.CreateNew(path, UnitSystem.SI);
        var terrain = original.AddNewTerrain("参考地形");
        var nvalues = original.AddNewNValueLayer("参考糙率");
        original.Save();
        terrain.Dispose(); nvalues.Dispose();
        XElement draft = XElement.Load(path);
        draft.Add(new XElement("UnknownCreationMetadata", "不能丢失"));
        byte[] projectBytes = File.ReadAllBytes(path);
        CreationRequest Request(string kind, Dictionary<string, string> fields) => new(kind, path, draft.ToString(), fields);
        CreatedModel Create(CreationRequest request)
        {
            var inspected = ModelCreationService.Inspect(request);
            Check(inspected.CanExecute, inspected.ValidationMessage ?? "Creation readiness");
            var created = ModelCreationService.Create(request with { Revision = inspected.Revision });
            if (created.Group != null)
            {
                var group = draft.Element(created.Group);
                if (group == null) { group = new XElement(created.Group); draft.Add(group); }
                group.Add(new XElement(created.Element!, new XAttribute(created.PrimaryKey!, created.Name),
                    created.Associations.Select(item => new XAttribute(item.Key, item.Value))));
            }
            return created;
        }
        var invalid = Request("newGeometry", new() { ["NewGeometryControl/GeometryName"] = "../escape" });
        Check(!ModelCreationService.Inspect(invalid).CanExecute, "Filename traversal rejected before file creation");
        var geometryRequest = Request("newGeometry", new() {
            ["NewGeometryControl/GeometryName"] = "中文几何",
            ["NewGeometryControl/SelectedTerrain"] = terrain.Filename,
            ["NewGeometryControl/SelectedNValue"] = nvalues.Filename
        });
        var geometryInspection = ModelCreationService.Inspect(geometryRequest);
        Check(geometryInspection.Choices["NewGeometryControl/SelectedTerrain"].Single().Title == "参考地形", "Choices come from actual project models");
        var geometry = Create(geometryRequest);
        Check(geometry.Associations["Terrain"] == "参考地形" && geometry.Associations["N_Values"] == "参考糙率", "Real geometry associations returned to project draft");
        byte[] geometryBytes = File.ReadAllBytes(geometry.AssetPath);
        Check(!ModelCreationService.Inspect(geometryRequest).CanExecute, "Existing model cannot be overwritten");
        var boundary = Create(Request("newBoundary", new() {
            ["NewBoundaryConditionControl/BoundaryConditionName"] = "中文边界",
            ["NewBoundaryConditionControl/StartTime"] = "2026-10-15T00:00:00Z",
            ["NewBoundaryConditionControl/EndTime"] = "2026-10-16T00:00:00Z"
        }));
        var planRequest = Request("newPlan", new() {
            ["NewPlanControl/PlanName"] = "继承方案",
            ["NewPlanControl/SelectedGeometry"] = geometry.AssetPath,
            ["NewPlanControl/SelectedBoundaryCondition"] = boundary.AssetPath,
            ["NewPlanControl/TimeWindowMode"] = "BoundaryCondition"
        });
        var plan = Create(planRequest);
        var reopened = new Project(path);
        try
        {
            reopened.ApplyEditorMetadata(draft);
            var actualGeometry = reopened.Geometries.Single();
            var actualBoundary = reopened.BoundaryConditions.Single();
            var actualPlan = reopened.Plans.Single();
            Check(actualGeometry.GeometryAssociation.Terrain.Name == "参考地形" && actualGeometry.GeometryAssociation.NValueLayer.Name == "参考糙率", "Independent project reader resolves geometry draft associations");
            Check(actualPlan.Geometry == actualGeometry && actualPlan.BoundaryCondition == actualBoundary, "Independent project reader resolves new plan associations");
            Check(actualPlan.TimeWindowMode == PlanTimeWindowMode.BoundaryCondition && actualPlan.StartTime == actualBoundary.StartTime && actualPlan.EndTime == actualBoundary.EndTime, "Actual source HDF plan inherits source boundary dates");
        }
        finally { Dispose(reopened); }
        var customFields = new Dictionary<string, string>(planRequest.Fields) {
            ["NewPlanControl/PlanName"] = "自定方案", ["NewPlanControl/TimeWindowMode"] = "Plan",
            ["NewPlanControl/StartTime"] = "2026-10-14T00:00:00Z", ["NewPlanControl/EndTime"] = "2026-10-17T00:00:00Z"
        };
        var custom = Request("newPlan", customFields);
        var warned = ModelCreationService.Inspect(custom);
        Check(warned.CanExecute && warned.Warning != null, "Source out-of-bound time-window warning does not become a blocking error");
        customFields["NewPlanControl/StartTime"] = "2026-10-18T00:00:00Z";
        Check(!ModelCreationService.Inspect(custom).CanExecute, "Negative duration rejected without files");
        customFields["NewPlanControl/StartTime"] = "2026-10-15T06:00:00Z";
        customFields["NewPlanControl/EndTime"] = "2026-10-15T18:00:00Z";
        string revision = ModelCreationService.Inspect(custom).Revision;
        using (var sourceBoundary = new BoundaryCondition(boundary.AssetPath))
        { sourceBoundary.EndTime = sourceBoundary.EndTime.AddDays(1); sourceBoundary.Save(); }
        try { ModelCreationService.Create(custom with { Revision = revision }); throw new InvalidOperationException("Stale source accepted"); }
        catch (SourceFileChangedException) { }
        Check(!File.Exists(Path.Combine(original.PlansDirectory, "自定方案.h5")), "Stale source leaves no new model");
        var customPlan = Create(custom);
        using (var actual = new Plan(customPlan.AssetPath))
        {
            Check(actual.TimeWindowMode == PlanTimeWindowMode.Plan && actual.InternalComputeDurationSeconds == 43200, "Custom source HDF duration is persisted");
            Check(actual.StartTime.ToUniversalTime() == new DateTime(2026, 10, 15, 6, 0, 0, DateTimeKind.Utc), "Wire dates preserve the selected instant");
        }
        Check(File.ReadAllBytes(path).SequenceEqual(projectBytes), "Creation never auto-saves or rewrites the project draft");
        Check(File.ReadAllBytes(geometry.AssetPath).SequenceEqual(geometryBytes), "Other source models remain byte-identical");
        Check(!Directory.EnumerateDirectories(temporary.FullName, ".model-create-*", SearchOption.AllDirectories).Any(), "Staging is cleaned after creation and rejected requests");
        if (Environment.GetEnvironmentVariable("HECRAS_CREATION_ACCEPTANCE_DIRECTORY") is string acceptance)
        {
            Directory.CreateDirectory(acceptance);
            foreach (string file in Directory.EnumerateFiles(temporary.FullName, "*", SearchOption.AllDirectories))
            {
                string destination = Path.Combine(acceptance, Path.GetRelativePath(temporary.FullName, file));
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.Copy(file, destination, overwrite: false);
            }
            draft.Save(Path.Combine(acceptance, Path.GetFileName(path)));
        }
        Console.WriteLine("Actual model creation, HDF reread, source associations, dates, stale source, no-overwrite and project-draft preservation passed.");
    }
    private static void Dispose(Project project)
    {
        foreach (var layer in project.Plans.Cast<CoreLayerBase>().Concat(project.Geometries).Concat(project.Terrains)
            .Concat(project.BoundaryConditions).Concat(project.NValues).Concat(project.ClassificationLayers)) layer.Dispose();
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
