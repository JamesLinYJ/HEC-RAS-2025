using System.Security.Cryptography;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using Ras.Backend;
using Ras.Hydraulics;
using Ras.Layers;
using Ras.Layers.BoundaryConditions;
using Utility.Logging;
using Utility.Progress;
using Utility.Units;
using Visual.Observables;

internal static class PlanComputeJobMessageChecks
{
    internal static Task Run()
    {
        CheckBatchJobMessagesAreStreamedInSourceOrder();
        CheckConcurrentSolverMessagesUseSerializedSourceCollection();
        CheckDiagnosticTargetsFollowExactSelectedPlanAssociations();
        return Task.CompletedTask;
    }

    private static void CheckBatchJobMessagesAreStreamedInSourceOrder()
    {
        var reporter = new ProgressReporter();
        var job = new BatchJob(reporter, "Plan Compute", uiThreadSyncContext: Utility.SynchronizationContext.None);
        var updates = new List<PlanComputeJobMessageUpdate>();
        using var capture = new PlanComputeJobMessageCapture(job, "run-1", ProjectMessage, updates.Add);
        var sourceClass = new MessageClass("Plan_Diagnostic", MessageSeverity.Warning,
            "Boundary Condition {BoundaryConditionName} needs attention.");

        reporter.ReportMessage(sourceClass.Create("Boundary A"));
        reporter.ReportMessage(sourceClass.Create("Boundary A"));

        PlanComputeJobMessage[] projected = updates.SelectMany(update => update.Messages).ToArray();
        Check(updates.All(update => update.RunId == "run-1") && projected.Length == 2,
            "Every retained BatchJob message is emitted as an individual update for the owning run.");
        Check(projected.Select(message => message.Index).SequenceEqual([0, 1]) &&
              projected.All(message => message.Code == "Plan_Diagnostic" &&
                  message.DefaultSeverity == "Warning" &&
                  message.EvaluatedMessage == "Boundary Condition Boundary A needs attention."),
            "Source code, severity, evaluated text and collection order are preserved, including duplicates.");
        Check(projected.All(message => message.LogData.Any(item => item.Key == "BoundaryConditionName" && item.Value == "Boundary A") &&
                                       message.LogData.Any(item => item.Key == "{OriginalFormat}")),
            "Ordered structured source log data remains available to native diagnostics.");

        capture.Dispose();
        reporter.ReportMessage(sourceClass.Create("Boundary B"));
        Check(updates.SelectMany(update => update.Messages).Count() == 2,
            "Disposing the capture detaches its collection listener before later job messages.");
        job.MarkComplete(success: false);
    }

    private static void CheckConcurrentSolverMessagesUseSerializedSourceCollection()
    {
        var reporter = new ProgressReporter();
        BatchJob job = PlanComputeJobMessageCapture.CreateJob(reporter, "Concurrent Plan Compute");
        var updates = new List<PlanComputeJobMessageUpdate>();
        using var capture = new PlanComputeJobMessageCapture(job, "parallel-run", ProjectMessage, updates.Add);
        var messageClass = new MessageClass("Parallel_Diagnostic", MessageSeverity.Warning,
            "Source worker {WorkerIndex} reported a diagnostic.");
        Parallel.For(0, 400, index => reporter.ReportMessage(messageClass.Create(index)));
        job.MarkComplete(success: true);
        capture.Flush();
        PlanComputeJobMessage[] projected = updates.SelectMany(update => update.Messages).ToArray();
        Check(job.Messages.Count == 400 && projected.Length == 400
            && projected.Select(message => message.Index).SequenceEqual(Enumerable.Range(0, 400))
            && projected.Select(message => message.EvaluatedMessage).Distinct(StringComparer.Ordinal).Count() == 400,
            "Concurrent real source reporter callbacks retain every message once in contiguous source collection order.");
    }

    private static void CheckDiagnosticTargetsFollowExactSelectedPlanAssociations()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "Plan Diagnostic Targets.ras");
        Project created = Project.CreateNew(projectPath, UnitSystem.SI);
        string planPath;
        string geometryPath;
        string boundaryPath;
        try
        {
            Geometry geometry = created.AddNewGeometry("Geometry A");
            BoundaryCondition boundary = created.AddNewBoundaryCondition("Boundary A",
                new DateTime(2026, 10, 18), TimeSpan.FromDays(1));
            geometry.FlowAreaLayer.Add(new FlowArea(CreateDiagnosticMesh(), "Flow Area A"));
            geometry.FlowAreaLayer.Add(new FlowArea(CreateDiagnosticMesh(), "Flow Area B"));
            boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(0, 0), new(0, 1) })).Name = "Line A";
            boundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(1, 0), new(1, 1) })).Name = "Line B";
            Plan plan = created.AddNewPlan("Plan A");
            created.GetPlanAssociation(plan).Geometry = geometry;
            created.GetPlanAssociation(plan).BoundaryCondition = boundary;
            geometry.Save(); boundary.Save(); plan.Save(); created.Save();
            planPath = plan.Filename;
            geometryPath = geometry.Filename;
            boundaryPath = boundary.Filename;
        }
        finally { Dispose(created); }

        Project project = new(projectPath);
        try
        {
            Plan plan = project.Plans.Single(item => item.Name == "Plan A");
            string canonicalProject = SourceFilePaths.Canonical(projectPath);
            string canonicalPlan = SourceFilePaths.Canonical(planPath);
            string projectRevision = Hash(canonicalProject);
            string planRevision = Hash(canonicalPlan);

            PlanDiagnosticTarget planTarget = ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan,
                "PlanName", "Plan A", canonicalProject, projectRevision, canonicalPlan, planRevision)
                ?? throw new InvalidOperationException("The source Plan diagnostic target was not resolved.");
            PlanDiagnosticTarget geometryTarget = ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan,
                "GeometryName", "Geometry A", canonicalProject, projectRevision, canonicalPlan, planRevision)
                ?? throw new InvalidOperationException("The associated Geometry diagnostic target was not resolved.");
            PlanDiagnosticTarget boundaryTarget = ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan,
                "BoundaryConditionName", "Boundary A", canonicalProject, projectRevision, canonicalPlan, planRevision)
                ?? throw new InvalidOperationException("The associated Boundary Condition diagnostic target was not resolved.");

            PlanDiagnosticTarget flowAreaTarget = ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan,
                "MeshName", "Flow Area A", canonicalProject, projectRevision, canonicalPlan, planRevision)
                ?? throw new InvalidOperationException("The associated Flow Area target was not resolved.");
            PlanDiagnosticTarget boundaryLineTarget = ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan,
                "BoundaryConditionLineName", "Line A", canonicalProject, projectRevision, canonicalPlan, planRevision)
                ?? throw new InvalidOperationException("The associated Boundary Condition Line target was not resolved.");

            Check(planTarget.Kind == "plan" &&
                  SourceFilePaths.SameSourceFile(planTarget.AssetPath, planPath) &&
                  planTarget.AssetRevision == planRevision,
                "PlanName targets the exact selected Plan HDF and captured revision.");
            Check(geometryTarget.Kind == "geometry" &&
                  SourceFilePaths.SameSourceFile(geometryTarget.AssetPath, geometryPath) &&
                  geometryTarget.AssetRevision == Hash(geometryPath),
                "GeometryName resolves only through the selected Plan's actual Geometry association.");
            Check(boundaryTarget.Kind == "boundaryCondition" &&
                  SourceFilePaths.SameSourceFile(boundaryTarget.AssetPath, boundaryPath) &&
                  boundaryTarget.AssetRevision == Hash(boundaryPath),
                "BoundaryConditionName resolves only through the selected Plan's actual BC association.");
            Check(flowAreaTarget.Kind == "flowArea" && flowAreaTarget.FeatureID == "flow-area-row:0" &&
                  flowAreaTarget.FeatureName == "Flow Area A" &&
                  SourceFilePaths.SameSourceFile(flowAreaTarget.AssetPath, geometryPath) &&
                  flowAreaTarget.AssetRevision == Hash(geometryPath),
                "MeshName resolves to a unique exact associated Geometry flow-area row and captures its HDF revision.");
            Check(boundaryLineTarget.Kind == "boundaryConditionLine" &&
                  boundaryLineTarget.FeatureID == "boundary-line-row:0" && boundaryLineTarget.FeatureName == "Line A" &&
                  SourceFilePaths.SameSourceFile(boundaryLineTarget.AssetPath, boundaryPath) &&
                  boundaryLineTarget.AssetRevision == Hash(boundaryPath),
                "BoundaryConditionLineName resolves to a unique exact associated boundary-line row and captures its HDF revision.");
            Geometry selectedGeometry = project.GetPlanAssociation(plan).Geometry
                ?? throw new InvalidOperationException("The selected Plan has no Geometry association.");
            BoundaryCondition selectedBoundary = project.GetPlanAssociation(plan).BoundaryCondition
                ?? throw new InvalidOperationException("The selected Plan has no Boundary Condition association.");
            selectedGeometry.FlowAreaLayer.Add(new FlowArea(CreateDiagnosticMesh(), "Flow Area A"));
            selectedBoundary.BoundaryConditionLines.Add(new Polyline(new Point[] { new(2, 0), new(2, 1) })).Name = "Line A";
            Check(ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan, "MeshName", "Flow Area A",
                    canonicalProject, projectRevision, canonicalPlan, planRevision) is null &&
                  ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan, "BoundaryConditionLineName", "Line A",
                    canonicalProject, projectRevision, canonicalPlan, planRevision) is null,
                "Ambiguous duplicate feature names never produce a navigation target that could select the wrong row.");
            Check(ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan, "GeometryName", "Unrelated Geometry",
                    canonicalProject, projectRevision, canonicalPlan, planRevision) is null,
                "A diagnostic name cannot navigate to an unrelated same-category project asset.");
            Check(ModelEditorAdapter.ResolvePlanDiagnosticTarget(project, plan, "GeometryName", "Geometry A",
                    canonicalProject, projectRevision + "stale", canonicalPlan, planRevision) is null,
                "A diagnostic target is omitted when its captured project revision is stale.");
        }
        finally { Dispose(project); }
    }

    private static PlanComputeJobMessage ProjectMessage(int index, Message message) =>
        new(index, message.MessageType.Code, message.MessageType.DefaultSeverity.ToString(),
            message.EvaluatedMessage, message.LogData.Select(pair =>
                new PlanComputeJobLogDatum(pair.Key, pair.Value?.ToString())).ToArray());

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static Mesh CreateDiagnosticMesh()
    {
        Point[] points = [new(0, 0), new(1, 0), new(1, 1), new(0, 1)];
        Face[] faces = Enumerable.Range(0, 4)
            .Select(index => new Face { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 })
            .ToArray();
        FacePoint[] facePoints = points.Select((point, index) => new FacePoint(point)
            { Faces = new int[] { (index + 3) % 4, index } }).ToArray();
        return new Mesh(new Polygon(points), new Cell[] { new() { Faces = new int[] { 0, 1, 2, 3 } } },
            faces, facePoints, [new Point(0.5, 0.5)], null!);
    }

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
            .Concat(project.Geometries).Concat(project.BoundaryConditions)
            .Concat(project.Terrains).Concat(project.NValues).Concat(project.ClassificationLayers)) layer.Dispose();
    }

    private static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }
}
