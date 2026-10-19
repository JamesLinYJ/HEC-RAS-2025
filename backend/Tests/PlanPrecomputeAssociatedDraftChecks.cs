using System.Globalization;
using Ras.Backend;
using Ras.Layers;
using Utility.Units;

internal static class PlanPrecomputeAssociatedDraftChecks
{
    internal static async Task Run()
    {
        using var directory = new TemporaryDirectory();
        string projectPath = Path.Combine(directory.FullName, "Associated precompute drafts.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        DateTime start = new(2026, 10, 1, 0, 0, 0, DateTimeKind.Local);
        Terrain terrain = project.AddNewTerrain("Precompute terrain");
        NValueLayer nValues = project.AddNewNValueLayer("Precompute N values");
        Geometry geometry = project.AddNewGeometry("Precompute geometry", terrain, nValues);
        Geometry unassociatedGeometry = project.AddNewGeometry("Other geometry", terrain, nValues);
        BoundaryCondition boundary = project.AddNewBoundaryCondition("Precompute boundary", start, TimeSpan.FromDays(1));
        Plan plan = project.AddNewPlan("Precompute plan");
        plan.TimeWindowMode = PlanTimeWindowMode.Plan;
        plan.InternalStartTime = start.AddHours(12);
        plan.InternalComputeDurationSeconds = TimeSpan.FromHours(2).TotalSeconds;
        plan.SolverType = SolverType.GPU;
        project.GetPlanAssociation(plan).Geometry = geometry;
        project.GetPlanAssociation(plan).BoundaryCondition = boundary;
        string geometryPath = geometry.Filename;
        string unassociatedGeometryPath = unassociatedGeometry.Filename;
        string boundaryPath = boundary.Filename;
        string planPath = plan.Filename;
        string terrainPath = terrain.Filename;
        string nValuePath = nValues.Filename;
        terrain.Save(); nValues.Save(); geometry.Save(); unassociatedGeometry.Save();
        boundary.Save(); plan.Save(); project.Save();
        terrain.Dispose(); nValues.Dispose(); geometry.Dispose(); unassociatedGeometry.Dispose();
        boundary.Dispose(); plan.Dispose();

        byte[] projectBytes = File.ReadAllBytes(projectPath);
        byte[] planBytes = File.ReadAllBytes(planPath);
        byte[] geometryBytes = File.ReadAllBytes(geometryPath);
        byte[] unassociatedGeometryBytes = File.ReadAllBytes(unassociatedGeometryPath);
        byte[] boundaryBytes = File.ReadAllBytes(boundaryPath);
        byte[] terrainBytes = File.ReadAllBytes(terrainPath);
        byte[] nValueBytes = File.ReadAllBytes(nValuePath);
        string projectXml = System.Xml.Linq.XElement.Load(projectPath)
            .ToString(System.Xml.Linq.SaveOptions.DisableFormatting);
        ModelSnapshot planSnapshot = await ModelEditorAdapter.LoadAsync(
            new ModelRequest(planPath, "Plan", projectPath, projectXml));
        ModelSnapshot boundarySnapshot = await ModelEditorAdapter.LoadAsync(
            new ModelRequest(boundaryPath, "Boundary Conditions", projectPath, projectXml));
        ModelSaveRequest planRequest = new(planPath, "Plan", projectPath, planSnapshot.Revision,
            [], [], projectXml, planSnapshot.SourceState);

        var geometryModel = new GeometryCulvertModelRequest(geometryPath, "Geometry", projectPath, projectXml);
        GeometryCulvertSnapshot culvertBase = await ModelEditorAdapter.LoadGeometryCulvertsAsync(new(geometryModel));
        GeometryCulvertSnapshot culvertDraft = await ModelEditorAdapter.EditGeometryCulvertsAsync(new(
            geometryModel, culvertBase.Revision, culvertBase.DraftState,
            new GeometryCulvertMutation("addBarrel", "barrel", [], DraftID: "4a96f4c269e3471f9cf070c6e3075102",
                Polyline: [new GeometryCulvertCoordinate(1, 1), new GeometryCulvertCoordinate(12, 1)])));

        var geometryMeshModel = new GeometryMeshModelRequest(geometryPath, "Geometry", projectPath, projectXml);
        GeometryMeshSnapshot meshBase = await ModelEditorAdapter.LoadGeometryMeshAsync(new(geometryMeshModel));
        GeometryMeshSnapshot meshPrepareDraft = await ModelEditorAdapter.EditGeometryMeshAsync(new(
            geometryMeshModel, meshBase.Revision, meshBase.DraftState, null, [],
            new GeometryMeshMutation("prepare")));
        ModelSaveRequest geometryRequest = new(geometryPath, "Geometry", projectPath,
            culvertBase.Revision, [], [], projectXml,
            GeometryMeshState: meshPrepareDraft.DraftState,
            GeometryCulvertState: culvertDraft.DraftState);

        PlanPrecomputeDraftResponse clean = await ModelEditorAdapter.PrecomputePlanDraftsAsync(
            new PlanPrecomputeDraftRequest(planRequest, null, null, "capture-clean"));
        Check(clean.CaptureID == "capture-clean"
            && !clean.Result.Messages.Any(message => message.EvaluatedMessage.Contains(
                "GPU solver does not currently support culvert hydraulics", StringComparison.Ordinal)),
            "A clean associated Geometry has no GPU/culvert readiness diagnostic and the capture identity is echoed");

        PlanPrecomputeDraftResponse geometryResult = await ModelEditorAdapter.PrecomputePlanDraftsAsync(
            new PlanPrecomputeDraftRequest(planRequest, geometryRequest, null, "capture-geometry"));
        Check(geometryResult.CaptureID == "capture-geometry"
            && geometryResult.Result.Messages.Any(message => message.EvaluatedMessage.Contains(
                "GPU solver does not currently support culvert hydraulics", StringComparison.Ordinal)),
            "A dirty associated Geometry culvert draft participates in the real source Plan.CanCompute check");
        Check(geometryResult.Result.Messages.Any(message => message.Code == "Geometry_PrepareDraftPending")
            && !geometryResult.Result.Result,
            "A pending Geometry Prepare request is reported instead of running the source operation that saves the Geometry HDF");

        string endField = "BoundaryConditionTimeWindow/BoundaryCondition_EndTime";
        ModelSaveRequest boundaryRequest = new(boundaryPath, "Boundary Conditions", projectPath,
            boundarySnapshot.Revision,
            new Dictionary<string, string>
            {
                [endField] = start.AddHours(13).ToString("O", CultureInfo.InvariantCulture)
            }, [], projectXml, boundarySnapshot.SourceState,
            Rows: new Dictionary<string, ModelRow[]>(),
            Samples: new Dictionary<string, ModelSample[]>());
        PlanPrecomputeDraftResponse boundaryResult = await ModelEditorAdapter.PrecomputePlanDraftsAsync(
            new PlanPrecomputeDraftRequest(planRequest, null, boundaryRequest, "capture-boundary"));
        Check(boundaryResult.CaptureID == "capture-boundary"
            && boundaryResult.Result.Messages.Any(message => message.Code == "BC_DoesntCoverTimeWindow"),
            "A dirty associated Boundary Condition time-window draft participates in the real source Plan.CanCompute check");

        ModelSaveRequest wrongGeometry = geometryRequest with { AssetPath = unassociatedGeometryPath };
        await Expect<ArgumentException>(() => ModelEditorAdapter.PrecomputePlanDraftsAsync(
            new PlanPrecomputeDraftRequest(planRequest, wrongGeometry, null, "capture-wrong-association")));
        ModelSaveRequest staleGeometry = geometryRequest with { Revision = geometryRequest.Revision + "stale" };
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.PrecomputePlanDraftsAsync(
            new PlanPrecomputeDraftRequest(planRequest, staleGeometry, null, "capture-stale-child")));

        Check(File.ReadAllBytes(projectPath).SequenceEqual(projectBytes)
            && File.ReadAllBytes(planPath).SequenceEqual(planBytes)
            && File.ReadAllBytes(geometryPath).SequenceEqual(geometryBytes)
            && File.ReadAllBytes(unassociatedGeometryPath).SequenceEqual(unassociatedGeometryBytes)
            && File.ReadAllBytes(boundaryPath).SequenceEqual(boundaryBytes)
            && File.ReadAllBytes(terrainPath).SequenceEqual(terrainBytes)
            && File.ReadAllBytes(nValuePath).SequenceEqual(nValueBytes),
            "Associated draft precompute never publishes Plan, Geometry, Boundary Condition, terrain, N-value or project files");

        Console.WriteLine("Plan precompute applies exact unsaved associated child drafts, rejects stale or mismatched child identity, reports source Prepare limits and leaves files unchanged.");
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
