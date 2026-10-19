using System.Xml.Linq;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class CatalogTreeChecks
{
    internal static void Run()
    {
        using var temporary = new TemporaryDirectory();
        string path = Path.Combine(temporary.FullName, "目录树验收.ras");
        var source = Project.CreateNew(path, UnitSystem.SI);
        var terrain = source.AddNewTerrain("目录地形");
        var nvalue = source.AddNewNValueLayer("目录糙率");
        source.Save();
        terrain.Dispose();
        nvalue.Dispose();
        Dispose(source);

        XElement draft = XElement.Load(path);
        byte[] originalProject = File.ReadAllBytes(path);
        CreatedModel Create(string kind, Dictionary<string, string> fields)
        {
            var request = new CreationRequest(kind, path, draft.ToString(), fields);
            var inspection = ModelCreationService.Inspect(request);
            Check(inspection.CanExecute, inspection.ValidationMessage ?? "Source model creation readiness");
            CreatedModel model = ModelCreationService.Create(request with { Revision = inspection.Revision });
            if (model.Group != null)
            {
                XElement group = draft.Element(model.Group) ?? new XElement(model.Group);
                if (group.Parent == null) draft.Add(group);
                group.Add(new XElement(model.Element!, new XAttribute(model.PrimaryKey!, model.Name),
                    model.Associations.Select(item => new XAttribute(item.Key, item.Value))));
            }
            return model;
        }

        var geometryChoices = ModelCreationService.Inspect(new CreationRequest("newGeometry", path, draft.ToString(), new() { ["NewGeometryControl/GeometryName"] = "目录几何" })).Choices;
        CreatedModel geometry = Create("newGeometry", new()
        {
            ["NewGeometryControl/GeometryName"] = "目录几何",
            ["NewGeometryControl/SelectedTerrain"] = geometryChoices["NewGeometryControl/SelectedTerrain"].Single().Id,
            ["NewGeometryControl/SelectedNValue"] = geometryChoices["NewGeometryControl/SelectedNValue"].Single().Id
        });
        CreatedModel boundary = Create("newBoundary", new()
        {
            ["NewBoundaryConditionControl/BoundaryConditionName"] = "目录边界",
            ["NewBoundaryConditionControl/StartTime"] = "2026-10-15T00:00:00Z",
            ["NewBoundaryConditionControl/EndTime"] = "2026-10-16T00:00:00Z"
        });
        CreatedModel plan = Create("newPlan", new()
        {
            ["NewPlanControl/PlanName"] = "目录方案",
            ["NewPlanControl/SelectedGeometry"] = geometry.AssetPath,
            ["NewPlanControl/SelectedBoundaryCondition"] = boundary.AssetPath,
            ["NewPlanControl/TimeWindowMode"] = "BoundaryCondition"
        });

        const string mapID = "8f6031e2-2d36-45ef-9e9f-2f659ea19c1d";
        CatalogTreeRequest request = new(path, draft.ToString(), Maps: [new(mapID, "Map 4", "Buildable")]);
        CatalogTreeSnapshot catalog = CatalogTreeService.LoadCatalog(request);
        Check(catalog.Roots.Select(root => root.Name).SequenceEqual(new[] { "Project", "External Connections", "Maps" }),
            "Catalog keeps the three native section roots");
        CatalogTreeNode modelRoot = catalog.Roots[0];
        var modelChildren = modelRoot.Children ?? throw new InvalidOperationException("The catalog model has no categories.");
        Check(modelChildren.Select(root => root.Name).SequenceEqual(new[]
            { "Terrains", "Geometries", "NValues", "Boundary Conditions", "Plans", "Results", "Classifications" }),
            "Catalog keeps the source category order");
        var rootProperties = modelRoot.Properties ?? throw new InvalidOperationException("Project summary properties are missing.");
        Check(rootProperties.Single(property => property.Id == "ProjectCount/Geometries").Value == "1" &&
              rootProperties.Single(property => property.Id == "ProjectCount/Plans").Value == "1" &&
              rootProperties.Single(property => property.Id == "Project/Units").Value == "SI" &&
              rootProperties.All(property => property.Id != "Project/ProjectionName"),
            "Project summary exposes live model counts and units without inventing a projection for local coordinates");
        CatalogTreeNode catalogGeometry = (modelChildren[1].Children ?? throw new InvalidOperationException("The geometry category has no children.")).Single(item => item.Name == "目录几何");
        Check(catalogGeometry.SourceClass == "ObservableGeometry" &&
              catalogGeometry.AssetID == Path.GetFullPath(geometry.AssetPath) &&
              catalogGeometry.Properties!.Any(property => property.Id == "Filename" && property.Value == geometry.AssetPath),
            "Catalog nodes point to the real created asset and filename");
        CatalogTreeNode catalogBoundary = (modelChildren[3].Children ?? throw new InvalidOperationException("The boundary category has no children.")).Single(item => item.Name == "目录边界");
        var boundaryProperties = catalogBoundary.Properties ?? throw new InvalidOperationException("Boundary summary properties are missing.");
        Check(boundaryProperties.Any(property => property.Id == "BoundaryCondition/StartTime" && property.Value.Length > 0) &&
              boundaryProperties.Any(property => property.Id == "BoundaryCondition/EndTime" && property.Value.Length > 0),
            "Boundary catalog node carries the actual source start and end times");
        CatalogTreeNode catalogPlan = (modelChildren[4].Children ?? throw new InvalidOperationException("The plan category has no children.")).Single(item => item.Name == "目录方案");
        var planProperties = catalogPlan.Properties ?? throw new InvalidOperationException("Plan summary properties are missing.");
        Check(planProperties.Single(property => property.Id == "PlanAssociation/Geometry").Value == "目录几何" &&
              planProperties.Any(property => property.Id == "PlanAssociation/NValueMode") &&
              planProperties.Any(property => property.Id == "PlanAssociation/Classification"),
            "Plan catalog node carries its actual geometry, N-value mode, and classification associations");
        Check(catalog.Roots[2].Children!.Single().Id == "map:" + mapID,
            "Catalog map nodes retain the caller's real map identity");

        CatalogTreeSnapshot planTree = CatalogTreeService.LoadProject(request with
        {
            Mode = "Plan",
            FocusedPlanIds = [Path.GetFullPath(plan.AssetPath)]
        });
        CatalogTreeNode focusedPlan = planTree.Roots[0].Children!.Single(item => item.Name == "目录方案");
        var focusedChildren = focusedPlan.Children ?? throw new InvalidOperationException("The focused plan has no associations.");
        Check(focusedChildren.Any(item => item.Name == "目录几何") &&
              focusedChildren.Any(item => item.Name == "目录边界") &&
              focusedChildren.Any(item => item.Name == "目录地形") &&
              focusedChildren.Any(item => item.Name == "目录糙率"),
            "Project tree resolves current project-draft associations to actual layer nodes");
        Check(File.ReadAllBytes(path).SequenceEqual(originalProject),
            "Reading catalog and project trees does not save the project XML draft");
        Console.WriteLine("Catalog and project tree source nodes, draft associations, map identity, and read-only behavior passed.");
    }

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
