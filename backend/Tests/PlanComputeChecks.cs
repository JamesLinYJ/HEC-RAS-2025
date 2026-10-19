using BoundaryCondition = Ras.Layers.BoundaryCondition;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Channels;
using System.Xml.Linq;
using Geospatial.Rasters;
using Geospatial.Rasters.Classifications;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Engine;
using Ras.Layers;
using Ras.Hydraulics;
using Ras.Layers.Terrains;
using Utility.Units;
using H5Assist;

internal static class PlanComputeChecks
{
    private const string TimestepField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep";
    private const string SolverField = "PlanSettingsPage/ViewModel_SelectedPlan_SolverType";
    private static readonly DateTime Start = new(2026, 10, 16, 0, 0, 0, DateTimeKind.Local);

    internal static async Task Run()
    {
        LiveMapTargetCapacityChecks();
        using var temporary = new TemporaryDirectory();
        Fixture fixture = CreateFixture(temporary.FullName);
        LiveMapFixture liveMap = CreateLiveMapFixture(fixture);
        ExportFixtureIfRequested(temporary.FullName);
        byte[] originalProject = File.ReadAllBytes(fixture.ProjectPath);
        byte[] originalPlan = File.ReadAllBytes(fixture.PlanPath);

        ModelSnapshot loaded = await ModelEditorAdapter.LoadAsync(new ModelRequest(fixture.PlanPath, "Plan", fixture.ProjectPath));
        ModelSaveRequest model = Request(loaded, fixture.PlanPath, fixture.ProjectPath, File.ReadAllText(fixture.ProjectPath));
        PlanComputeInspection inspection = await ModelEditorAdapter.InspectPlanComputeAsync(new(model));
        Check(inspection.CanExecute && !inspection.RequiresCUDA && inspection.Revision == loaded.Revision,
            "Inspection applies the source Plan draft and reports real CanCompute readiness without writing the model.");
        Check(inspection.SourceDependencies.Any(item => item.Role == "Geometry" && item.WillWrite)
            && inspection.SourceDependencies.Any(item => item.Role == "BoundaryCondition" && item.WillWrite)
            && inspection.SourceDependencies.Any(item => item.Role == "Terrain" && !item.WillWrite)
            && inspection.SourceDependencies.Any(item => item.Role == "ResultOutput" && item.WillWrite),
            "Inspection names the source HDF dependencies and their implicit write side effects.");

        byte[] boundaryBefore = File.ReadAllBytes(fixture.BoundaryPath);
        try
        {
            MutateHdf(fixture.BoundaryPath, BoundaryCondition.HDFGroupName);
            using CancellationDirectory staleBoundary = CancellationDirectory.Create();
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.ExecutePlanComputeAsync(
                ExecuteRequest(model, inspection, staleBoundary)));
        }
        finally { File.WriteAllBytes(fixture.BoundaryPath, boundaryBefore); }

        using (CancellationDirectory beforePreparation = CancellationDirectory.Create())
        {
            string preCancelMarker = Path.Combine(beforePreparation.Path, "cancel");
            File.WriteAllText(preCancelMarker, beforePreparation.Nonce);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(preCancelMarker, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            PlanComputeExecutionResult preCancelled = await ModelEditorAdapter.ExecutePlanComputeAsync(
                ExecuteRequest(model, inspection, beforePreparation));
            Check(preCancelled.State == "cancelled" && preCancelled.ResultPath is null
                && preCancelled.ResultCompute is { State: "cancelled", ResultPath: null, ResultRevision: null }
                && preCancelled.Messages.Any(message => message.Code == "Generic_TaskCancelled"),
                "Cancellation during retained source preparation returns its actual cancellation message without creating a Result.");
        }

        byte[] geometryBefore = File.ReadAllBytes(fixture.GeometryPath);
        byte[] boundaryBeforeCompute = File.ReadAllBytes(fixture.BoundaryPath);
        using CancellationDirectory successCancellation = CancellationDirectory.Create();
        var correlatedUpdates = new List<ResultComputeEnvelope>();
        var sourceProfileUpdates = new List<(ResultComputeEnvelope Identity, ResultComputeProfilesUpdate Update)>();
        var liveMapFrames = new List<PlanComputeLiveMapRenderFrame>();
        var liveVelocityFrames = new List<PlanComputeLiveVelocityFrame>();
        object correlatedUpdatesGate = new();
        string duplexRequestID = Guid.NewGuid().ToString("D");
        string operationOwnerToken = Guid.NewGuid().ToString("D");
        string operationContextID = Guid.NewGuid().ToString("D");
        var duplexInput = new PlanComputeControlInput(duplexRequestID);
        await using var duplexControls = new BackendDuplexControlReader(duplexRequestID, duplexInput);
        PlanComputeLiveMapRenderTarget? firstLiveTarget = null;
        PlanComputeLiveMapRenderTarget? secondLiveTarget = null;
        PlanComputeLiveMapRenderTarget? firstVelocityTarget = null;
        PlanComputeLiveMapRenderTarget? secondVelocityTarget = null;
        bool sentSecondViewport = false;
        bool sentOversizedTargets = false;
        int liveFrameCountWhenRejected = -1;
        int liveVelocityFrameCountWhenRejected = -1;
        var cachedViewportRedrawn = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var liveTargetRejected = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var result = await ModelEditorAdapter.ExecutePlanComputeDuplexAsync(
            ExecuteRequest(model, inspection, successCancellation), update =>
            {
                bool markCachedViewportRedrawn = false;
                bool waitForCachedViewportRedraw = false;
                lock (correlatedUpdatesGate)
                {
                    if (update.ResultCompute is { } identity)
                    {
                        correlatedUpdates.Add(identity);
                        if (update.ResultProfiles is { } profiles)
                            sourceProfileUpdates.Add((identity, profiles));
                        if (firstLiveTarget is null && identity.State == "running" &&
                            update.ResultProfiles is { ErrorMessage: null } profileUpdate &&
                            profileUpdate.Profiles.FirstOrDefault(profile => profile.Index == 0) is { } firstProfile)
                        {
                            PlanComputeLiveMapRenderTarget target = CreateLiveMapTarget(identity, liveMap, firstProfile,
                                profileUpdate.OutputBlockName,
                                operationOwnerToken, operationContextID, "first-viewport",
                                new RasterMapViewExtent(0, 0, 32, 32, 32, 32));
                            firstLiveTarget = target;
                            firstVelocityTarget = CreateLiveVelocityTarget(identity, liveMap, firstProfile,
                                profileUpdate.OutputBlockName,
                                operationOwnerToken, operationContextID, "first-velocity-viewport",
                                new RasterMapViewExtent(0, 0, 32, 32, 32, 32));
                            duplexInput.ReplaceTargets([target, firstVelocityTarget]);
                            waitForCachedViewportRedraw = true;
                        }
                    }
                    if (update.LiveMapFrame is { } frame)
                    {
                        liveMapFrames.Add(frame);
                        if (!sentSecondViewport && firstLiveTarget is { } firstTarget &&
                            frame.TargetID == firstTarget.TargetID)
                        {
                            PlanComputeLiveMapRenderTarget target = firstTarget with
                            {
                                TargetID = "second-viewport",
                                Viewport = new RasterMapViewExtent(0, 0, 32, 32, 48, 24)
                            };
                            secondLiveTarget = target;
                            secondVelocityTarget = firstVelocityTarget is { } velocityTarget
                                ? velocityTarget with
                                {
                                    TargetID = "second-velocity-viewport",
                                    Viewport = new RasterMapViewExtent(0, 0, 32, 32, 48, 24)
                                }
                                : null;
                            sentSecondViewport = true;
                            duplexInput.ReplaceTargets(secondVelocityTarget is { } nextVelocity
                                ? [target, nextVelocity] : [target]);
                        }
                        else if (secondLiveTarget is { } resizedTarget &&
                            frame.TargetID == resizedTarget.TargetID)
                        {
                            markCachedViewportRedrawn = true;
                            if (!sentOversizedTargets && secondLiveTarget is { } activeTarget &&
                            frame.TargetID == activeTarget.TargetID)
                            {
                                PlanComputeLiveMapRenderTarget[] oversized = Enumerable.Range(0,
                                    PlanComputeLiveMapTargetRegistry.MaximumTargets + 1)
                                    .Select(index => activeTarget with
                                    { TargetID = "overflow-" + index.ToString(System.Globalization.CultureInfo.InvariantCulture) })
                                    .ToArray();
                                sentOversizedTargets = true;
                                duplexInput.ReplaceTargets(oversized);
                            }
                        }
                    }
                    if (update.LiveVelocityFrame is { } velocityFrame)
                        liveVelocityFrames.Add(velocityFrame);
                    if (update.Message == PlanComputeLiveMapTargetRegistry.RejectedTargetUpdateMessage)
                    {
                        liveFrameCountWhenRejected = liveMapFrames.Count;
                        liveVelocityFrameCountWhenRejected = liveVelocityFrames.Count;
                        liveTargetRejected.TrySetResult(true);
                    }
                }
                if (markCachedViewportRedrawn) cachedViewportRedrawn.TrySetResult(true);
                if (waitForCachedViewportRedraw)
                {
                    if (!cachedViewportRedrawn.Task.Wait(TimeSpan.FromSeconds(10)))
                        throw new TimeoutException("A viewport replacement did not redraw the just-produced profile before the solver advanced.");
                }
            }, duplexControls);
        Check(result.State == "completed" && result.Summary is { Success: true, Solver: not null },
            "Execution reaches the retained ObservablePlan.ComputeAsync and Result.Compute CPU solver completion. " + System.Text.Json.JsonSerializer.Serialize(result));
        ResultComputeEnvelope terminalIdentity = result.ResultCompute
            ?? throw new InvalidDataException("A completed source compute omitted its result correlation envelope.");
        ResultComputeEnvelope? startedIdentity;
        ResultComputeEnvelope[] correlatedSnapshot;
        int correlatedUpdateCount;
        lock (correlatedUpdatesGate)
        {
            startedIdentity = correlatedUpdates.FirstOrDefault(identity =>
                identity.State == "running" && identity.ResultPath is not null);
            correlatedUpdateCount = correlatedUpdates.Count;
            correlatedSnapshot = correlatedUpdates.ToArray();
        }
        string projectXmlFingerprint = Convert.ToHexString(SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(File.ReadAllText(fixture.ProjectPath))));
        Check(startedIdentity is not null && terminalIdentity.State == "completed" &&
              Guid.TryParseExact(terminalIdentity.RunId, "D", out _) &&
              startedIdentity.RunId == terminalIdentity.RunId &&
              !string.IsNullOrWhiteSpace(startedIdentity.ResultName) &&
              terminalIdentity.ResultName == startedIdentity.ResultName &&
              startedIdentity.ResultPath == result.ResultPath && terminalIdentity.ResultPath == result.ResultPath &&
              terminalIdentity.ResultRevision == result.ResultRevision &&
              terminalIdentity.ProjectPath == Path.GetFullPath(fixture.ProjectPath) &&
              terminalIdentity.PlanPath == Path.GetFullPath(fixture.PlanPath) &&
              terminalIdentity.ProjectRevision == Hash(fixture.ProjectPath) &&
              terminalIdentity.PlanRevision == loaded.Revision &&
              terminalIdentity.ProjectXmlFingerprint == projectXmlFingerprint,
            "The actual computeStarted Result path is correlated by one run ID through terminal source revisions and exact Project/Plan identities.");
        Check(correlatedUpdateCount > 0 && correlatedSnapshot.All(identity => identity.RunId == terminalIdentity.RunId),
            "Every live telemetry/progress update carries the same compute run identity.");
        PlanComputeLiveMapRenderFrame[] liveFrameSnapshot;
        int rejectedFrameCountSnapshot;
        int rejectedVelocityFrameCountSnapshot;
        lock (correlatedUpdatesGate)
        {
            liveFrameSnapshot = liveMapFrames.ToArray();
            rejectedFrameCountSnapshot = liveFrameCountWhenRejected;
            rejectedVelocityFrameCountSnapshot = liveVelocityFrameCountWhenRejected;
        }
        PlanComputeLiveMapRenderFrame? resizedLiveFrame = liveFrameSnapshot.LastOrDefault(frame =>
            frame.TargetID == "second-viewport");
        PlanComputeLiveMapRenderFrame? initialLiveFrame = liveFrameSnapshot.FirstOrDefault(frame =>
            frame.TargetID == "first-viewport");
        PlanComputeLiveVelocityFrame? resizedVelocityFrame;
        PlanComputeLiveVelocityFrame? initialVelocityFrame;
        PlanComputeLiveVelocityFrame[] liveVelocityFrameSnapshot;
        lock (correlatedUpdatesGate)
        {
            liveVelocityFrameSnapshot = liveVelocityFrames.ToArray();
            resizedVelocityFrame = liveVelocityFrameSnapshot.LastOrDefault(frame =>
                frame.TargetID == "second-velocity-viewport");
            initialVelocityFrame = liveVelocityFrameSnapshot.FirstOrDefault(frame =>
                frame.TargetID == "first-velocity-viewport");
        }
        Check(sentSecondViewport && sentOversizedTargets && liveTargetRejected.Task.IsCompletedSuccessfully
            && cachedViewportRedrawn.Task.IsCompletedSuccessfully
            && rejectedFrameCountSnapshot == liveFrameSnapshot.Length
            && rejectedVelocityFrameCountSnapshot == liveVelocityFrameSnapshot.Length
            && liveFrameSnapshot.Any(frame => frame.TargetID == "first-viewport"
                && frame.Width == 32 && frame.Height == 32)
            && resizedLiveFrame is { Width: 48, Height: 24, ProfileIndex: 0 }
            && initialLiveFrame is not null && resizedLiveFrame.ProfileName == initialLiveFrame.ProfileName
            && resizedLiveFrame.Time == initialLiveFrame.Time
            && resizedVelocityFrame is { SelectionIndex: 0, ProfileIndex: 0, Width: 48, Height: 24 }
            && initialVelocityFrame is not null
            && resizedVelocityFrame.ProfileName == initialVelocityFrame.ProfileName
            && resizedVelocityFrame.Time == initialVelocityFrame.Time,
            "The retained writer immediately rerenders the immutable just-produced profile for a changed viewport before the solver advances, then an oversized replacement clears the old target.");
        PlanComputeLiveVelocityFrame acceptedVelocityFrame = resizedVelocityFrame
            ?? throw new InvalidDataException("The resized writer-owned velocity frame was not captured.");
        MapResultSourcesResult stableLiveSources = MapResultChartService.Sources(new(liveMap.Map, []));
        MapResultActiveNode stableLiveNode = stableLiveSources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SamePath(node.Node.AssetID, fixture.PlanPath));
        MapResultRenderResult stableLiveRender = MapResultRenderService.Render(new(liveMap.Map, [],
            stableLiveSources.ContextToken, stableLiveNode.Node, 0,
            new RasterMapViewExtent(0, 0, 32, 32, 48, 24)));
        Check(resizedLiveFrame is not null && resizedLiveFrame.Rgba
            .Where((_, index) => index % 4 == 3).Any(alpha => alpha != 0),
            "The persisted wet initial stage produces actual visible live depth pixels, not an all-transparent transport payload.");
        Check(resizedLiveFrame is not null && stableLiveRender.Layers.Single().ProfileIndex == 0
            && resizedLiveFrame.Rgba.SequenceEqual(stableLiveRender.Layers.Single().Rgba)
            && resizedLiveFrame.TerrainRevision == stableLiveRender.Layers.Single().TerrainRevision,
            "A live same-process write-mode raster matches the stable retained ResultMapRenderLayer output for the same profile, viewport, and terrain revision.");
        MapResultSourcesResult stableVelocitySources = MapResultChartService.Sources(new(liveMap.VelocityMap, []));
        MapResultActiveNode stableVelocityNode = stableVelocitySources.ActiveNodes.Single(node =>
            node.NodeKind == "MultiResult" && SamePath(node.Node.AssetID, fixture.PlanPath));
        Check(stableVelocityNode.SelectedMapType == "Velocity",
            "The companion velocity map selects the actual retained Velocity mapper in its source map context.");
        MapResultVelocityFieldResult stableVelocityField = MapResultVelocityFieldService.Sample(
            new MapResultVelocityFieldRequest(liveMap.VelocityMap, [], stableVelocitySources.ContextToken,
                stableVelocityNode.Node, "live-velocity-stable-comparison", result.ResultPath!,
                result.ResultRevision!, 0, secondVelocityTarget!.Viewport));
        Check(acceptedVelocityFrame is
                { SelectionIndex: 0, ProfileIndex: 0, MapType: "Velocity", Width: 48, Height: 24 }
            && acceptedVelocityFrame.TargetID == "second-velocity-viewport"
            && acceptedVelocityFrame.RunID == terminalIdentity.RunId
            && SamePath(acceptedVelocityFrame.ResultPath, result.ResultPath)
            && acceptedVelocityFrame.OutputBlockName == firstVelocityTarget?.OutputBlockName
            && acceptedVelocityFrame.ProfileName == stableVelocityField.ProfileName
            && acceptedVelocityFrame.NodeID == firstVelocityTarget?.NodeID
            && acceptedVelocityFrame.ContextToken == firstVelocityTarget?.ContextToken
            && acceptedVelocityFrame.MapID == liveMap.VelocityMap.MapID
            && acceptedVelocityFrame.TargetSequence > 0,
            "A writer-owned velocity frame carries the exact compute, slot-zero, profile, and resized viewport identity.");
        Check(acceptedVelocityFrame.InterleavedVelocity.SequenceEqual(stableVelocityField.InterleavedVelocity)
            && stableVelocityField.Width == acceptedVelocityFrame.Width
            && stableVelocityField.Height == acceptedVelocityFrame.Height
            && acceptedVelocityFrame.InterleavedVelocity.Length == 48 * 24 * 3 * sizeof(float)
            && Enumerable.Range(0, 48 * 24).Any(index =>
            {
                int offset = index * 3 * sizeof(float);
                float vx = BinaryPrimitives.ReadSingleLittleEndian(
                    acceptedVelocityFrame.InterleavedVelocity.AsSpan(offset, sizeof(float)));
                float vy = BinaryPrimitives.ReadSingleLittleEndian(
                    acceptedVelocityFrame.InterleavedVelocity.AsSpan(offset + sizeof(float), sizeof(float)));
                float magnitude = BinaryPrimitives.ReadSingleLittleEndian(
                    acceptedVelocityFrame.InterleavedVelocity.AsSpan(offset + 2 * sizeof(float), sizeof(float)));
                return float.IsFinite(vx) && float.IsFinite(vy) && float.IsFinite(magnitude)
                    && magnitude != stableVelocityField.NoDataValue && magnitude >= 0;
            }),
            "The live writer-owned VelocityMapper field matches the stable retained Result Velocity sample for the same Result profile and viewport.");
        Check(result.ResultPath is { Length: > 0 } && File.Exists(result.ResultPath)
            && result.ResultRevision == Hash(result.ResultPath),
            "A completed source result is retained with its exact HDF path and SHA-256.");
        Check(result.FinalDependencies.Any(item => item.Role == "Result" && item.Revision == "sha256:" + result.ResultRevision),
            "The terminal response includes the retained Result file identity.");
        Check(result.SourceValues.TryGetValue("Steps", out string? steps) && !string.IsNullOrWhiteSpace(steps)
            && result.SourceValues.TryGetValue("TotalCellCount", out string? cells) && cells == "1"
            && result.SourceValues.ContainsKey("LastIterations")
            && result.SourceValues.ContainsKey("RetryElevationCount")
            && result.SourceValues.ContainsKey("AdvectionLimitCount")
            && result.SourceValues.ContainsKey("ElapsedTime")
            && result.SourceValues.ContainsKey("SimulationTime"),
            "Live values originate from Result.TimeStepCompleted and MeshTimestepStats, including real mesh counts and solver counters.");
        Check(File.ReadAllBytes(fixture.ProjectPath).SequenceEqual(originalProject)
            && File.ReadAllBytes(fixture.PlanPath).SequenceEqual(originalPlan),
            "The source solver does not save the owning project XML or Plan HDF.");
        Check(!File.ReadAllBytes(fixture.GeometryPath).SequenceEqual(geometryBefore)
            || !File.ReadAllBytes(fixture.BoundaryPath).SequenceEqual(boundaryBeforeCompute),
            "The retained source build-ready-to-run sequence performs its documented Geometry/Boundary Conditions HDF saves.");
        if (!Result.TryLoad(result.ResultPath!, out Result? readback) || readback is null)
            throw new InvalidDataException("The completed source result HDF could not be reopened.");
        using (readback)
        {
            Check(readback.ComputeSummary.Success && readback.ProfileCount > 0,
                "A completed result has source summary metadata and stored output profiles.");
            (ResultComputeEnvelope Identity, ResultComputeProfilesUpdate Update)[] updates;
            lock (correlatedUpdatesGate) updates = sourceProfileUpdates.ToArray();
            Check(updates.Length > 0 && updates.All(item => item.Identity.RunId == terminalIdentity.RunId
                && item.Identity.ResultPath == result.ResultPath && item.Identity.State == "running"
                && item.Identity.ResultRevision is null && item.Update.ErrorMessage is null
                && item.Update.Profiles.Length is > 0 and <= 512),
                "Actual OutputBlock.TimestepAdded profile packets are bounded and correlated while the source writer runs, without a fabricated stable HDF revision.");
            ResultComputeProfile[] published = updates.SelectMany(item => item.Update.Profiles).ToArray();
            Check(published.Length == readback.ProfileCount
                && published.Select(item => item.Index).SequenceEqual(Enumerable.Range(0, readback.ProfileCount))
                && published.Select(item => item.Name).SequenceEqual(readback.BaseOutputBlock.ProfileNames)
                && published.Select(item => item.Time).SequenceEqual(readback.BaseOutputBlock.Times.Select(time =>
                    time.ToString("O", System.Globalization.CultureInfo.InvariantCulture))),
                "Every source profile name/index/time streamed from writer memory matches the actual finished Result HDF, with no gaps or invented timestep labels.");
            Check(published.Any(profile =>
                profile.Index == acceptedVelocityFrame.ProfileIndex
                && profile.Name == acceptedVelocityFrame.ProfileName
                && profile.Time == acceptedVelocityFrame.Time),
                "The live velocity field carries the exact source writer profile identity and wall-clock representation.");
            Check(updates.Zip(updates.Skip(1)).All(pair =>
                pair.First.Update.StartIndex + pair.First.Update.Profiles.Length == pair.Second.Update.StartIndex),
                "Profile update packets cover contiguous actual source indices without replaying the whole timeline.");
        }

        using (CancellationDirectory staleAfterResult = CancellationDirectory.Create())
            await Expect<SourceFileChangedException>(() => ModelEditorAdapter.ExecutePlanComputeAsync(
                ExecuteRequest(model, inspection, staleAfterResult)));

        var zeroInterval = model with { Fields = new Dictionary<string, string> { [TimestepField] = "0" } };
        await Expect<ArgumentException>(() => ModelEditorAdapter.InspectPlanComputeAsync(new(zeroInterval)));
        var invalidModel = model with { Fields = new Dictionary<string, string> { [TimestepField] = "0.3" } };
        PlanComputeInspection invalid = await ModelEditorAdapter.InspectPlanComputeAsync(new(invalidModel));
        Check(!invalid.CanExecute && invalid.Messages.Any(message => message.Code == "Plan_MappingIntervalMismatchingComputeInterval"),
            "An invalid source timestep remains a source CanCompute failure, not a fake available solver result.");
        using CancellationDirectory invalidCancellation = CancellationDirectory.Create();
        PlanComputeExecutionResult invalidExecution = await ModelEditorAdapter.ExecutePlanComputeAsync(
            new(invalidModel, invalid.InspectionId, invalidCancellation.Request));
        Check(invalidExecution.State == "failed" && invalidExecution.ResultPath is null && invalidExecution.Summary is null &&
              invalidExecution.ResultCompute is { State: "failed", ResultPath: null, ResultRevision: null },
            "A source readiness failure does not create a solver Result HDF.");

        var cudaModel = model with { Fields = new Dictionary<string, string> { [SolverField] = "GPU" } };
        PlanComputeInspection cuda = await ModelEditorAdapter.InspectPlanComputeAsync(new(cudaModel));
        Check(cuda.RequiresCUDA && !cuda.CanExecute && cuda.Reasons.Any(reason => reason.Contains("CUDA", StringComparison.Ordinal)),
            "The source GPU selection is explicitly unavailable on this CPU-only host.");

        ModelSnapshot cancelLoaded = await ModelEditorAdapter.LoadAsync(new ModelRequest(fixture.CancelPlanPath, "Plan", fixture.ProjectPath));
        ModelSaveRequest cancelModel = Request(cancelLoaded, fixture.CancelPlanPath, fixture.ProjectPath, File.ReadAllText(fixture.ProjectPath));
        PlanComputeInspection cancelInspection = await ModelEditorAdapter.InspectPlanComputeAsync(new(cancelModel));
        Check(cancelInspection.CanExecute, "The long-running CPU cancellation fixture is a valid source compute input.");
        using CancellationDirectory cancellation = CancellationDirectory.Create();
        string markerPath = Path.Combine(cancellation.Path, "cancel");
        int markerSent = 0;
        var cancellationUpdates = new List<ResultComputeEnvelope>();
        object cancellationUpdatesGate = new();
        PlanComputeExecutionResult cancelled = await ModelEditorAdapter.ExecutePlanComputeAsync(
            ExecuteRequest(cancelModel, cancelInspection, cancellation), update =>
            {
                if (update.ResultCompute is { } identity)
                {
                    lock (cancellationUpdatesGate) cancellationUpdates.Add(identity);
                }
                if (update.Values?.ContainsKey("Steps") != true || Interlocked.Exchange(ref markerSent, 1) != 0) return;
                File.WriteAllText(markerPath, cancellation.Nonce);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(markerPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            });
        Check(markerSent == 1 && cancelled.State == "cancelled"
            && cancelled.Summary is { Success: false, FailureReason: "User Cancelled" },
            "A nonce marker written from real timestep telemetry reaches BatchJob.RequestCancel and returns source cancellation.");
        ResultComputeEnvelope cancelledIdentity = cancelled.ResultCompute
            ?? throw new InvalidDataException("A cancelled source compute omitted its result correlation envelope.");
        ResultComputeEnvelope? cancelledStartedIdentity;
        ResultComputeEnvelope[] cancellationSnapshot;
        lock (cancellationUpdatesGate)
        {
            cancelledStartedIdentity = cancellationUpdates.FirstOrDefault(identity =>
                identity.State == "running" && identity.ResultPath is not null);
            cancellationSnapshot = cancellationUpdates.ToArray();
        }
        Check(cancelledIdentity.State == "cancelled" && cancelledStartedIdentity is not null &&
              cancelledStartedIdentity.RunId == cancelledIdentity.RunId &&
              cancelledIdentity.RunId != terminalIdentity.RunId &&
              cancelledIdentity.ResultPath == cancelled.ResultPath &&
              cancelledIdentity.ResultRevision == cancelled.ResultRevision &&
              cancellationSnapshot.All(identity => identity.RunId == cancelledIdentity.RunId),
            "An acknowledged source cancellation retains its exact started Result and terminal revision under the same run ID.");
        Check(cancelled.ResultPath is { Length: > 0 } && File.Exists(cancelled.ResultPath)
            && cancelled.ResultRevision == Hash(cancelled.ResultPath),
            "The source Result HDF and its SHA remain available after cooperative cancellation.");
        Check(!string.IsNullOrWhiteSpace(cancelled.Summary?.ComputeLog),
            "The source solver log is returned for a cancelled computation.");

        await ClassificationRasterDependencyCheck();

        Console.WriteLine("Plan compute inspection, real CPU Result.Compute, source telemetry, stale dependency checks, failure, cooperative cancellation, retained HDF identities and unchanged project/Plan bytes passed.");
    }

    private static void LiveMapTargetCapacityChecks()
    {
        var registry = new PlanComputeLiveMapTargetRegistry();
        PlanComputeLiveMapRenderTarget oldViewport = LiveMapTarget("old-viewport");
        PlanComputeLiveMapTargetUpdateResult installed = registry.Replace(1, [oldViewport]);
        Check(installed.Status == PlanComputeLiveMapTargetUpdateStatus.Applied
            && registry.Snapshot().Targets.SequenceEqual([oldViewport]),
            "A valid initial live map viewport target is installed for the retained writer.");

        PlanComputeLiveMapRenderTarget[] oversized = Enumerable.Range(0,
            PlanComputeLiveMapTargetRegistry.MaximumTargets + 1)
            .Select(index => LiveMapTarget("overflow-" + index.ToString(System.Globalization.CultureInfo.InvariantCulture)))
            .ToArray();
        PlanComputeLiveMapTargetUpdateResult rejected = registry.Replace(2, oversized);
        (ulong sequence, PlanComputeLiveMapRenderTarget[] targets) = registry.Snapshot();
        Check(rejected.Status == PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared
            && !string.IsNullOrWhiteSpace(rejected.Message)
            && sequence == 2 && targets.Length == 0,
            "An oversized newer viewport replacement reports rejection and clears every old target before the next writer timestep.");

        PlanComputeLiveMapTargetUpdateResult stale = registry.Replace(1, [oldViewport]);
        Check(stale.Status == PlanComputeLiveMapTargetUpdateStatus.Stale
            && registry.Snapshot().Targets.Length == 0,
            "A delayed old viewport control cannot restore the target cleared by the newer rejected request.");

        PlanComputeLiveMapTargetUpdateResult invalid = registry.Replace(3,
            [oldViewport with { ProfileIndex = -1 }]);
        Check(invalid.Status == PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared
            && registry.Snapshot().Targets.Length == 0,
            "A structurally invalid profile target is rejected and cannot leave an earlier viewport active.");

        PlanComputeLiveMapRenderTarget validVelocity = oldViewport with
        {
            TargetID = "valid-slot-zero-velocity",
            SelectedMapType = "Velocity",
            CaptureVelocityParticles = true,
            ProfileName = "Profile 0"
        };
        PlanComputeLiveMapTargetUpdateResult velocityInstalled = registry.Replace(4, [validVelocity]);
        Check(velocityInstalled.Status == PlanComputeLiveMapTargetUpdateStatus.Applied,
            "A live velocity capture is accepted only with a selected slot-zero Velocity profile.");
        PlanComputeLiveMapTargetUpdateResult nonKeyframeVelocity = registry.Replace(5,
            [validVelocity with { TargetID = "non-keyframe-velocity", SelectionIndex = 1 }]);
        Check(nonKeyframeVelocity.Status == PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared
            && registry.Snapshot().Targets.Length == 0,
            "A live velocity request cannot bind a non-keyframe MultiResult slot or retain the previous target.");
        PlanComputeLiveMapTargetUpdateResult wrongMapTypeVelocity = registry.Replace(6,
            [validVelocity with { TargetID = "wrong-map-type-velocity", SelectedMapType = "Depth" }]);
        Check(wrongMapTypeVelocity.Status == PlanComputeLiveMapTargetUpdateStatus.RejectedAndCleared
            && registry.Snapshot().Targets.Length == 0,
            "A live velocity request cannot be registered for a non-Velocity map type.");
    }

    private static PlanComputeLiveMapRenderTarget LiveMapTarget(string targetID)
    {
        string projectSessionID = Guid.NewGuid().ToString("D");
        string mapID = Guid.NewGuid().ToString("D");
        string projectPath = Path.Combine(Path.GetTempPath(), "live-map-project.ras");
        string planPath = Path.Combine(Path.GetTempPath(), "live-map-plan.p02");
        string digest = new string('A', 64);
        var map = new MapTreeRequest(projectPath, "<Project />", digest, mapID, 0,
            "Live map", "Project", digest);
        var node = new CatalogTreeNodeLocator("Results", "MultiResult", "Live plan",
            [0, 0], planPath);
        return new PlanComputeLiveMapRenderTarget(targetID, projectSessionID, "owner", "context",
            Guid.NewGuid().ToString("D"), projectPath, digest, digest, planPath, digest,
            map, "source-context", "node-id", node, 0, "Latest", null, 0,
            "2026-10-16T00:00:00.0000000Z", "Base Output", "Depth",
            new RasterMapViewExtent(0, 0, 1, 1, 32, 32));
    }

    private static LiveMapFixture CreateLiveMapFixture(Fixture fixture)
    {
        string projectXml = File.ReadAllText(fixture.ProjectPath);
        string projectXmlSHA = Convert.ToHexString(SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(projectXml)));
        MapDocumentMutationReceipt created = MapTreeService.CreateMap(new MapDocumentRequest(
            fixture.ProjectPath, projectXml, projectXmlSHA, null, "Project", Name: "Live compute map"));
        MapDocumentMutationReceipt velocityCreated = MapTreeService.CreateMap(new MapDocumentRequest(
            fixture.ProjectPath, projectXml, projectXmlSHA, created.VisualizationRevision, "Project", Name: "Live velocity map"));
        string visualizationPath = Path.ChangeExtension(fixture.ProjectPath, ".vis");
        XDocument visualization = XDocument.Load(visualizationPath, LoadOptions.PreserveWhitespace);
        XElement[] mapElements = visualization.Root!.Element("Maps")!.Elements("Map").ToArray();
        mapElements[created.MapIndex].Add(CreateTree("Depth"));
        mapElements[velocityCreated.MapIndex].Add(CreateTree("Velocity"));
        visualization.Save(visualizationPath, SaveOptions.DisableFormatting);

        string visualizationRevision = Hash(visualizationPath);
        var mapRequest = new MapTreeRequest(fixture.ProjectPath, projectXml, projectXmlSHA,
            Guid.NewGuid().ToString("D"), created.MapIndex, created.MapName,
            created.MapType, visualizationRevision);
        var velocityMapRequest = new MapTreeRequest(fixture.ProjectPath, projectXml, projectXmlSHA,
            Guid.NewGuid().ToString("D"), velocityCreated.MapIndex, velocityCreated.MapName,
            velocityCreated.MapType, visualizationRevision);
        MapResultSourcesResult sources = MapResultChartService.Sources(new(mapRequest, []));
        MapResultActiveNode node = sources.ActiveNodes.Single(active =>
            active.NodeKind == "MultiResult" && SamePath(active.Node.AssetID, fixture.PlanPath));
        MapResultSourcesResult velocitySources = MapResultChartService.Sources(new(velocityMapRequest, []));
        MapResultActiveNode velocityNode = velocitySources.ActiveNodes.Single(active =>
            active.NodeKind == "MultiResult" && SamePath(active.Node.AssetID, fixture.PlanPath));
        Check(!string.IsNullOrWhiteSpace(sources.ContextToken),
            "The live map fixture obtains its current source context through the real map Result service.");
        Check(node.Selections.Length == 1 && node.Selections[0].SelectedResult is null
            && node.Selections[0].Choices.Length == 0,
            "A saved MultiResult binds its unique real Plan before the first output without fabricating a stored Result.");
        Check(velocityNode.SelectedMapType == "Velocity" && velocityNode.Selections.Length == 1,
            "The companion map source captures the exact Velocity map selection for the same real Plan.");
        return new(mapRequest, node, sources.ContextToken, Guid.NewGuid().ToString("D"),
            velocityMapRequest, velocityNode, velocitySources.ContextToken);

        XElement CreateTree(string selectedMapType) => new("Tree", new XElement("Nodes",
            new XElement("Node", new XAttribute("Type", "Root"), new XAttribute("Name", "Results"),
                new XElement("Node", new XAttribute("Type", "MultiResult"),
                    new XAttribute("Name", Path.GetFileNameWithoutExtension(fixture.PlanPath)),
                    new XAttribute("IsChecked", true), new XAttribute("SelectedMapType", selectedMapType),
                    new XAttribute("ProfileIndex", 0)))));
    }

    private static PlanComputeLiveMapRenderTarget CreateLiveMapTarget(ResultComputeEnvelope identity,
        LiveMapFixture fixture, ResultComputeProfile profile, string outputBlockName,
        string operationOwnerToken, string operationContextID, string targetID,
        RasterMapViewExtent viewport) => new(targetID, fixture.ProjectSessionID,
            operationOwnerToken, operationContextID, identity.RunId, identity.ProjectPath,
            identity.ProjectRevision, identity.ProjectXmlFingerprint, identity.PlanPath,
            identity.PlanRevision, fixture.Map, fixture.SourcesContextToken,
            "live-map-fixture-node", fixture.Node.Node, 0, "Latest", null, profile.Index,
            profile.Time, outputBlockName, "Depth", viewport);

    private static PlanComputeLiveMapRenderTarget CreateLiveVelocityTarget(ResultComputeEnvelope identity,
        LiveMapFixture fixture, ResultComputeProfile profile, string outputBlockName,
        string operationOwnerToken, string operationContextID, string targetID,
        RasterMapViewExtent viewport) => new(targetID, fixture.ProjectSessionID,
            operationOwnerToken, operationContextID, identity.RunId, identity.ProjectPath,
            identity.ProjectRevision, identity.ProjectXmlFingerprint, identity.PlanPath,
            identity.PlanRevision, fixture.VelocityMap, fixture.VelocitySourcesContextToken,
            "live-velocity-fixture-node", fixture.VelocityNode.Node, 0, "Latest", null,
            profile.Index, profile.Time, outputBlockName, "Velocity", viewport,
            CaptureVelocityParticles: true, ProfileName: profile.Name);

    private static bool SamePath(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        StringComparison comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), comparison);
    }

    private static async Task ClassificationRasterDependencyCheck()
    {
        using var directory = new TemporaryDirectory();
        Fixture fixture = CreateFixture(directory.FullName);
        Project project = new(fixture.ProjectPath);
        string rasterPath;
        try
        {
            ClassificationLayer classification = project.AddNewClassification("Compute land cover");
            rasterPath = Path.Combine(classification.SourceDirectory, "cover.tif");
            using (var driver = Gdal.GetDriverByName("GTiff"))
            using (var raster = driver.Create(rasterPath, 16, 16, 1, DataType.GDT_Int32, ["TILED=YES"]))
            {
                raster.SetGeoTransform([0, 1, 0, 16, 0, -1]);
                using var band = raster.GetRasterBand(1);
                band.Fill(7, 0);
            }
            var classes = new Classification();
            classes.Set(7, "Grass");
            classification.AddNewRasterLayer(rasterPath, classes);
            NValueLayer values = project.NValues.Single();
            values.SetTrackClassificationLayer(classification);
            values.InterpretationTable.Set("Grass", 0.035f);
            classification.Save(); values.Save(); project.Save();
        }
        finally { Dispose(project); }
        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new ModelRequest(fixture.PlanPath, "Plan", fixture.ProjectPath));
        ModelSaveRequest model = Request(snapshot, fixture.PlanPath, fixture.ProjectPath, File.ReadAllText(fixture.ProjectPath));
        PlanComputeInspection inspection = await ModelEditorAdapter.InspectPlanComputeAsync(new(model));
        string originalSHA = Hash(rasterPath);
        Check(inspection.SourceDependencies.Any(item => item.Role == "NValueClassification"
            && item.Path.EndsWith("cover.tif", StringComparison.Ordinal) && item.Revision == "sha256:" + originalSHA),
            "Compute inspection captures the actual classification backing raster, not only its HDF definition.");
        using (var raster = Gdal.Open(rasterPath, Access.GA_Update))
        using (var band = raster.GetRasterBand(1)) band.Fill(8, 0);
        Check(Hash(rasterPath) != originalSHA, "The external classification raster really changed.");
        using CancellationDirectory cancellation = CancellationDirectory.Create();
        await Expect<SourceFileChangedException>(() => ModelEditorAdapter.ExecutePlanComputeAsync(
            ExecuteRequest(model, inspection, cancellation)));
    }

    private static Fixture CreateFixture(string directory)
    {
        string projectPath = Path.Combine(directory, "Plan Compute Acceptance.ras");
        Project project = Project.CreateNew(projectPath, UnitSystem.SI);
        Fixture saved;
        try
        {
            Terrain terrain = project.AddNewTerrain("Solver Terrain");
            string terrainPath = Path.Combine(terrain.SourceDirectory, "flat.tif");
            Directory.CreateDirectory(terrain.SourceDirectory);
            using (var driver = Gdal.GetDriverByName("GTiff"))
            using (var raster = driver.Create(terrainPath, 32, 32, 1, DataType.GDT_Float32,
                ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]))
            {
                raster.SetGeoTransform([0, 1, 0, 32, 0, -1]);
                using var band = raster.GetRasterBand(1);
                band.Fill(42, 0);
            }
            terrain.Add(RasterTerrainInput.CreateAndScan(terrain, terrainPath));
            NValueLayer nValues = project.AddNewNValueLayer("Solver Roughness");
            nValues.SetConstant(0.035f);
            Geometry geometry = project.AddNewGeometry("Solver Geometry", terrain, nValues);
            geometry.FlowAreaLayer.Add(new FlowArea(CreateMesh(), "Solver Mesh"));
            BoundaryCondition boundary = project.AddNewBoundaryCondition("Solver Boundary", Start, TimeSpan.FromHours(2));
            // The runtime InitialWaterSurface setter is not serialized. Use
            // the retained source Initial Stage metadata so reopened fixtures
            // really start wet rather than only the constructor's live object.
            boundary.InitialConditions.Stage.IsEnabled = true;
            boundary.InitialConditions.Stage.SpatialDataType = SpatialDataType.Constant;
            boundary.InitialConditions.Stage.ConstantValue = 43f;
            boundary.Precipitation.IsEnabled = true;
            boundary.Precipitation.SpatialDataType = SpatialDataType.Constant;
            boundary.Precipitation.ConstantValue = 0.000001f;
            Plan shortPlan = project.AddNewPlan("Plan CPU", geometry, boundary);
            Configure(shortPlan, durationSeconds: 4, timestepSeconds: 0.1);
            Plan cancelPlan = project.AddNewPlan("Plan Cancel", geometry, boundary);
            Configure(cancelPlan, durationSeconds: 3600, timestepSeconds: 0.1);

            foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
                .Concat(project.Geometries).Concat(project.BoundaryConditions)
                .Concat(project.Terrains).Concat(project.NValues)) layer.Save();
            project.Save();
            saved = new Fixture(projectPath, shortPlan.Filename, cancelPlan.Filename,
                geometry.Filename, boundary.Filename);
        }
        finally { Dispose(project); }
        Project reopened = new(projectPath);
        try
        {
            var stage = reopened.BoundaryConditions.Single().InitialConditions.Stage;
            Check(stage.IsEnabled && stage.SpatialDataType == SpatialDataType.Constant
                && stage.ConstantValue == 43f,
                "An independent source Project reload retains the enabled constant initial stage of 43 above terrain elevation 42.");
        }
        finally { Dispose(reopened); }
        return saved;
    }

    private static void Configure(Plan plan, double durationSeconds, double timestepSeconds)
    {
        plan.TimeWindowMode = PlanTimeWindowMode.Plan;
        plan.InternalStartTime = Start;
        plan.InternalComputeDurationSeconds = durationSeconds;
        plan.ComputeTimestep = TimeSpan.FromSeconds(timestepSeconds);
        plan.BaseOutputInterval = TimeSpan.FromSeconds(1);
        plan.SolverType = SolverType.CPU;
    }

    private static Mesh CreateMesh()
    {
        Point[] points = [new(4, 4), new(6, 4), new(6, 6), new(4, 6)];
        Face[] faces = Enumerable.Range(0, 4).Select(index => new Face
            { fpA = index, fpB = (index + 1) % 4, cellA = 0, cellB = -1 }).ToArray();
        FacePoint[] nodes = points.Select((point, index) => new FacePoint(point)
            { Faces = [(index + 3) % 4, index] }).ToArray();
        return new Mesh(new Polygon(points), [new Cell { Faces = new int[] { 0, 1, 2, 3 } }],
            faces, nodes, [new Point(5, 5)], null!);
    }

    private static ModelSaveRequest Request(ModelSnapshot snapshot, string assetPath,
        string projectPath, string projectXml) => new(assetPath, "Plan", projectPath,
            snapshot.Revision, [], [], projectXml, snapshot.SourceState);

    private static PlanComputeExecuteRequest ExecuteRequest(ModelSaveRequest model,
        PlanComputeInspection inspection, CancellationDirectory cancellation) =>
        new(model, inspection.InspectionId, cancellation.Request);

    private static void ExportFixtureIfRequested(string sourceDirectory)
    {
        string? destination = Environment.GetEnvironmentVariable("HECRAS_PLAN_COMPUTE_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(destination)) return;
        string target = Path.GetFullPath(destination);
        string source = Path.GetFullPath(sourceDirectory);
        if (Directory.Exists(target) || File.Exists(target) || target.StartsWith(source + Path.DirectorySeparatorChar,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new IOException("The Plan compute acceptance destination already exists or is inside the fixture source.");
        Directory.CreateDirectory(target);
        foreach (string file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            string copy = Path.Combine(target, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            File.Copy(file, copy, overwrite: false);
        }
    }

    private static void MutateHdf(string path, string group)
    {
        using var writer = new H5Writer(path);
        writer.WriteAttribute(group, "Plan compute dependency mutation", Guid.NewGuid().ToString("N"));
    }

    private static void Dispose(Project project)
    {
        foreach (Result result in project.Results) result.Dispose();
        foreach (CoreLayerBase layer in project.Plans.Cast<CoreLayerBase>()
            .Concat(project.Geometries).Concat(project.BoundaryConditions)
            .Concat(project.Terrains).Concat(project.NValues).Concat(project.ClassificationLayers)) layer.Dispose();
    }

    private static string Hash(string path)
    {
        using Stream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static async Task Expect<T>(Func<Task> action) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException("Expected " + typeof(T).Name);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed record LiveMapFixture(MapTreeRequest Map, MapResultActiveNode Node,
        string SourcesContextToken, string ProjectSessionID, MapTreeRequest VelocityMap,
        MapResultActiveNode VelocityNode, string VelocitySourcesContextToken);

    private sealed record Fixture(string ProjectPath, string PlanPath, string CancelPlanPath,
        string GeometryPath, string BoundaryPath);

    private sealed class PlanComputeControlInput(string requestID) : TextReader
    {
        private readonly Channel<string> lines = Channel.CreateUnbounded<string>();
        private readonly object gate = new();
        private ulong sequence;

        public void ReplaceTargets(PlanComputeLiveMapRenderTarget[] targets)
        {
            lock (gate)
            {
                sequence++;
                string json = JsonSerializer.Serialize(new
                {
                    id = requestID,
                    controlSequence = sequence,
                    control = new { type = "targets", targets }
                }, BackendJson.Options);
                if (!lines.Writer.TryWrite(json))
                    throw new InvalidOperationException("The live map control input is closed.");
            }
        }

        public override async ValueTask<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            try { return await lines.Reader.ReadAsync(cancellationToken).ConfigureAwait(false); }
            catch (ChannelClosedException) { return null; }
        }
    }

    private sealed class CancellationDirectory : IDisposable
    {
        public string Path { get; }
        public string Nonce { get; }
        public PlanComputeCancellation Request => new(Path, Nonce);
        private CancellationDirectory(string path, string nonce) { Path = path; Nonce = nonce; }

        public static CancellationDirectory Create()
        {
            string nonce = Guid.NewGuid().ToString("N");
            string directory = System.IO.Path.Combine(CanonicalTemporaryPath(new DirectoryInfo(System.IO.Path.GetTempPath())), "hecras-plan-compute-" + nonce);
            Directory.CreateDirectory(directory);
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                string owner = System.IO.Path.Combine(directory, "owner");
                File.WriteAllText(owner, nonce);
                File.SetUnixFileMode(owner, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            else File.WriteAllText(System.IO.Path.Combine(directory, "owner"), nonce);
            return new(directory, nonce);
        }

        private static string CanonicalTemporaryPath(DirectoryInfo directory)
        {
            if (directory.LinkTarget is not null)
                return CanonicalTemporaryPath((DirectoryInfo)(directory.ResolveLinkTarget(returnFinalTarget: true)
                    ?? throw new IOException("The temporary-directory link could not be resolved.")));
            return directory.Parent is { } parent
                ? System.IO.Path.Combine(CanonicalTemporaryPath(parent), directory.Name)
                : directory.FullName;
        }

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
