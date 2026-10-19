using System.Security.Cryptography;
using System.Text.Json;
using Geospatial.GDALAssist;
using OSGeo.GDAL;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Terrains;
using Utility.Units;

internal static class TerrainInputAppendChecks
{
    internal static async Task Run()
    {
        using var root = new TemporaryDirectory();
        string projectPath = Path.Combine(root.FullName, "terrain-input-append.ras");
        Project project = Project.CreateNew(projectPath, ProjectionDefinition.FromEPSG(32650));
        Terrain terrain = project.AddNewTerrain("TerrainImport");
        string baseRasterPath = Path.Combine(terrain.SourceDirectory, "existing.tif");
        WriteFloatRaster(baseRasterPath, project.Projection, 0, 0, 16, 16, 7f);
        terrain.Add(RasterTerrainInput.CreateAndScan(terrain, baseRasterPath));
        project.Save();
        terrain.Save();
        string assetPath = terrain.Filename;
        terrain.Dispose();

        byte[] originalHdf = File.ReadAllBytes(assetPath);
        byte[] originalProject = File.ReadAllBytes(projectPath);
        byte[] originalBaseRaster = File.ReadAllBytes(baseRasterPath);
        string inputDirectory = Path.Combine(root.FullName, "source-tiles");
        Directory.CreateDirectory(inputDirectory);
        string firstTile = Path.Combine(inputDirectory, "tile-west.tif");
        string secondTile = Path.Combine(inputDirectory, "tile-east.tif");
        string noDataTile = Path.Combine(inputDirectory, "nodata.tif");
        string cachedStatsTile = Path.Combine(inputDirectory, "cached-statistics.tif");
        string projectionFailureTile = Path.Combine(inputDirectory, "outside-projection-domain.tif");
        WriteFloatRaster(firstTile, project.Projection, 500_000, 1_000_000, 64, 64, 10f);
        WriteFloatRaster(secondTile, project.Projection, 501_920, 1_000_000, 64, 64, 20f);
        WriteFloatRaster(noDataTile, project.Projection, 700_000, 1_000_000, 16, 16, -9999f);
        WriteFloatRaster(cachedStatsTile, project.Projection, 750_000, 1_000_000, 16, 16, 12f);
        GDALRaster.SetStats(cachedStatsTile, 12, 12, 12, 0);
        // Keep the TIFF structurally valid and correctly tagged, while placing
        // its geographic extent outside EPSG:4326's valid latitude domain.
        // InspectRaster does not transform raster bounds; ConvertFile does.
        WriteFloatRaster(projectionFailureTile, new EPSGProjection(4326), 10, 120, 64, 64, 30f, cellSize: 0.01);
        byte[] firstTileBytes = File.ReadAllBytes(firstTile);
        byte[] secondTileBytes = File.ReadAllBytes(secondTile);
        byte[] noDataTileBytes = File.ReadAllBytes(noDataTile);
        byte[] cachedStatsTileBytes = File.ReadAllBytes(cachedStatsTile);
        byte[] projectionFailureTileBytes = File.ReadAllBytes(projectionFailureTile);
        byte[]? firstTileAuxBytes = ReadAuxiliaryMetadata(firstTile);
        byte[]? noDataTileAuxBytes = ReadAuxiliaryMetadata(noDataTile);
        byte[]? cachedStatsTileAuxBytes = ReadAuxiliaryMetadata(cachedStatsTile);

        ModelSnapshot snapshot = await ModelEditorAdapter.LoadAsync(new(assetPath, "Terrain", projectPath));
        string originalInputId = snapshot.Terrain!.Inputs.Single().Id;
        ModelSaveRequest Model(ModelSnapshot current) => new(
            assetPath, "Terrain", projectPath, current.Revision,
            current.Fields.Where(pair => pair.Key.StartsWith("TerrainInputs/", StringComparison.Ordinal)
                || pair.Key is "TerrainLayersEditor/SelectedInputWithMap" or "TerrainCatalogSummary/Context_Description")
                .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal),
            new Dictionary<string, ImageData[]>(), SourceState: current.SourceState);

        TerrainInputImportInspectData inspection = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [firstTile, secondTile]));
        Check(inspection.Sources.Length == 2 && inspection.Sources.All(source => source.IsValid),
            "Inspection opens both actual one-band float32 GeoTIFFs");
        TerrainInputImportInspectData overlappingSelections = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [assetPath, baseRasterPath]));
        Check(overlappingSelections.Sources.Length == 1 && overlappingSelections.Sources[0].IsValid
            && Path.GetFullPath(overlappingSelections.Sources[0].Path) == Path.GetFullPath(baseRasterPath),
            "A Terrain container and its directly selected raster share one inspected path and settings row");
        Check(inspection.Sources.Select(source => source.Id).Distinct(StringComparer.Ordinal).Count() == 2
            && inspection.Sources.All(source => source.Revision.Length == 64),
            "Inspection assigns distinct source identities and content revisions");
        Check(inspection.Sources.All(source => source.CellSize is { } cell && double.IsFinite(cell)
            && source.DefaultScaleFactor is { } scale && double.IsFinite(scale)),
            "Inspection only returns finite cell sizes and default conversions");
        TerrainInputImportSource uncachedStatistics = inspection.Sources.Single(source =>
            Path.GetFullPath(source.Path) == Path.GetFullPath(firstTile));
        Check(uncachedStatistics is { IsValid: true, Minimum: null, Maximum: null },
            "An uncached constant-value raster does not report GDAL's zero-filled statistics warning outputs as real values");
        TerrainInputImportSource cachedStatistics = (await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [cachedStatsTile]))).Sources.Single();
        Check(cachedStatistics is { IsValid: true, Minimum: 12, Maximum: 12 },
            "Inspection returns actual finite minimum and maximum metadata when the source already has cached statistics");
        Check(inspection.RoundingOptions.Contains("None", StringComparer.Ordinal)
            && inspection.UnitConversionOptions.SequenceEqual(["Default", "None", "FeetToMeters", "MetersToFeet", "Custom"])
            && inspection.StitchTilesDefault,
            "Inspection preserves the original rounding, unit conversion and stitch defaults");
        TerrainInputImportInspectData noDataInspection = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [noDataTile]));
        string noDataJson = JsonSerializer.Serialize(noDataInspection, BackendJson.Options);
        Check(noDataInspection.Sources.Single() is { IsValid: true }
            && IsFiniteOrNull(noDataInspection.Sources[0].Minimum)
            && IsFiniteOrNull(noDataInspection.Sources[0].Maximum)
            && noDataInspection.Sources[0].Minimum is null
            && noDataInspection.Sources[0].Maximum is null
            && !noDataJson.Contains("NaN", StringComparison.OrdinalIgnoreCase)
            && !noDataJson.Contains("Infinity", StringComparison.OrdinalIgnoreCase),
            "A valid NoData-only raster without cached statistics remains valid and reports no fabricated numeric range");
        Check(File.ReadAllBytes(firstTile).SequenceEqual(firstTileBytes)
            && File.ReadAllBytes(noDataTile).SequenceEqual(noDataTileBytes)
            && File.ReadAllBytes(cachedStatsTile).SequenceEqual(cachedStatsTileBytes)
            && AuxBytesUnchanged(firstTile, firstTileAuxBytes)
            && AuxBytesUnchanged(noDataTile, noDataTileAuxBytes)
            && AuxBytesUnchanged(cachedStatsTile, cachedStatsTileAuxBytes),
            "Statistics inspection leaves source TIFFs and existing or absent PAM sidecars byte-identical");

        string draftToken = Guid.NewGuid().ToString("N");
        string firstBatchToken = Guid.NewGuid().ToString("N");
        TerrainInputImportSelection[] selections = inspection.Sources.Select(source =>
            new TerrainInputImportSelection(source.Path, source.Revision, "None", "Default", SourceId: source.Id)).ToArray();
        TerrainInputImportInspectData projectionFailureInspection = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [projectionFailureTile]));
        TerrainInputImportSource projectionFailureSource = projectionFailureInspection.Sources.Single();
        Check(projectionFailureSource is { IsValid: true, Width: 64, Height: 64, BandCount: 1 }
            && projectionFailureSource.Projection != null
            && projectionFailureSource.CellSize is { } geographicCellSize && Math.Abs(geographicCellSize - 0.01) < 1e-9,
            "Inspection accepts the structurally valid float32 EPSG:4326 TIFF without preemptively projecting its out-of-domain extent");
        TerrainInputImportSelection projectionFailureSelection = new(
            projectionFailureSource.Path, projectionFailureSource.Revision, "None", "Default", SourceId: projectionFailureSource.Id);

        string preCancelledBatchToken = Guid.NewGuid().ToString("N");
        TerrainInputAppendRequest preCancelledRequest = new(Model(snapshot), [selections[0]],
            StitchTiles: false, DraftToken: draftToken, BatchToken: preCancelledBatchToken);
        TerrainInputImportStatusData missingStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(preCancelledRequest));
        Check(missingStatus.State == "NotFound" && missingStatus.Result == null && missingStatus.Operations.Length == 0,
            "Status reports an unregistered request as NotFound with no fabricated operation results");
        TerrainInputImportCancelResult preRegistrationCancel = ModelEditorAdapter.CancelTerrainInputImport(
            new(new ModelRequest(assetPath, "Terrain", projectPath), draftToken, preCancelledBatchToken));
        TerrainInputImportStatusData cancelMarkerStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(preCancelledRequest));
        Check(preRegistrationCancel is { Accepted: true, State: "Running" }
            && cancelMarkerStatus.State == "Running" && cancelMarkerStatus.Operations.Length == 0,
            "An accepted whole-batch cancellation marker remains visible during append registration");
        TerrainInputAppendResult preCancelled = await ModelEditorAdapter.AppendTerrainInputsAsync(preCancelledRequest);
        snapshot = preCancelled.Snapshot;
        Check(preCancelled.BatchStatus == "Cancelled" && preCancelled.Operations.Single().Status == "Cancelled"
            && snapshot.Terrain?.Inputs.Length == 1,
            "Replaying the exact request after pre-registration cancellation returns a terminal cancelled envelope without conversion");

        TerrainInputAppendRequest stitchedRequest = new(
            Model(snapshot), selections, StitchTiles: true, DraftToken: draftToken, BatchToken: firstBatchToken);
        TerrainInputAppendResult stitched = await ModelEditorAdapter.AppendTerrainInputsAsync(stitchedRequest);
        snapshot = stitched.Snapshot;
        TerrainEditorData appended = snapshot.Terrain ?? throw new InvalidOperationException("Terrain append did not return a terrain snapshot.");
        Check(appended.ImportDraftToken == draftToken && appended.Inputs.Length == 2
            && stitched.BatchStatus == "Completed" && stitched.Operations is [{ Status: "Staged", SourceIDs.Length: 2 }],
            "One real SmartMerge output is appended to the existing terrain in draft state");
        TerrainInputData stagedInput = appended.Inputs.Single(input => input.Id != originalInputId);
        string stagedPath = stagedInput.Filename ?? throw new InvalidOperationException("Imported terrain input has no staged TIFF path.");
        string draftDirectory = new FileInfo(stagedPath).Directory!.Parent!.Parent!.FullName;
        Check(File.Exists(stagedPath) && Hash(stagedPath).Length == 64 && Directory.Exists(draftDirectory),
            "Stitched raster exists only in its controlled pending draft directory");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(originalProject)
            && File.ReadAllBytes(baseRasterPath).SequenceEqual(originalBaseRaster)
            && File.ReadAllBytes(firstTile).SequenceEqual(firstTileBytes)
            && File.ReadAllBytes(secondTile).SequenceEqual(secondTileBytes)
            && File.ReadAllBytes(noDataTile).SequenceEqual(noDataTileBytes)
            && File.ReadAllBytes(cachedStatsTile).SequenceEqual(cachedStatsTileBytes)
            && File.ReadAllBytes(projectionFailureTile).SequenceEqual(projectionFailureTileBytes),
            "Inspect and append leave HDF, project XML and all original raster sources byte-identical");

        string partialBatchToken = Guid.NewGuid().ToString("N");
        TerrainInputAppendRequest partialRequest = new(
            Model(snapshot), [selections[0], projectionFailureSelection],
            StitchTiles: false, DraftToken: draftToken, BatchToken: partialBatchToken);
        Check(partialRequest.Files.All(selection => selection.Rounding == "None"
            && selection.UnitConversion == "Default" && selection.CustomScaleFactor == null),
            "Both sources use valid, explicit no-rounding/default-unit import settings");
        TerrainInputAppendResult partial = await ModelEditorAdapter.AppendTerrainInputsAsync(partialRequest);
        snapshot = partial.Snapshot;
        Check(partial.BatchStatus == "Partial" && partial.Operations.Length == 2
            && partial.Operations[0].Status == "Staged" && partial.Operations[1].Status == "Failed"
            && partial.Operations[0].SourceIDs.SequenceEqual([inspection.Sources[0].Id])
            && partial.Operations[1].SourceIDs.SequenceEqual([projectionFailureSource.Id])
            && partial.Operations[1].Diagnostic?.Contains("Reprojection error.", StringComparison.Ordinal) == true
            && snapshot.Terrain?.Inputs.Length == 3,
            "The real converter stages one valid sibling and reports the projection-domain failure for a second inspection-valid raster");
        Check(File.ReadAllBytes(projectionFailureTile).SequenceEqual(projectionFailureTileBytes),
            "A failed reprojection leaves its source TIFF byte-identical");
        TerrainInputImportStatusData recovered = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(partialRequest));
        Check(recovered.State == "Partial" && recovered.Result != null
            && OperationsMatch(recovered.Result.Operations, partial.Operations)
            && recovered.Result.Snapshot.Terrain?.Inputs.Length == 3,
            "Status recovery returns the exact terminal partial-success envelope");

        File.WriteAllBytes(assetPath, originalHdf.Concat(new byte[] { 0x7f }).ToArray());
        TerrainInputImportStatusData changedHdfStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(partialRequest));
        File.WriteAllBytes(assetPath, originalHdf);
        Check(StatusUnavailableForChangedSource(changedHdfStatus, partial),
            "A changed HDF blocks cached snapshot installation while status preserves the terminal operation results");
        MutateRaster(baseRasterPath, 98f);
        TerrainInputImportStatusData changedSourceStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(partialRequest));
        File.WriteAllBytes(baseRasterPath, originalBaseRaster);
        Check(StatusUnavailableForChangedSource(changedSourceStatus, partial),
            "A changed original terrain dependency blocks the cached snapshot but retains per-file status");
        string partialOutputPath = partial.Snapshot.Terrain!.Inputs
            .Single(input => input.Id != originalInputId && input.Id != stagedInput.Id).Filename!;
        byte[] partialOutputBytes = File.ReadAllBytes(partialOutputPath);
        MutateRaster(partialOutputPath, 97f);
        TerrainInputImportStatusData changedStagedStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(partialRequest));
        await RejectChangedSource(() => ModelEditorAdapter.AppendTerrainInputsAsync(partialRequest));
        File.WriteAllBytes(partialOutputPath, partialOutputBytes);
        Check(StatusUnavailableForChangedSource(changedStagedStatus, partial)
            && File.Exists(stagedPath) && File.Exists(partialOutputPath),
            "A changed accepted TIFF blocks status and same-token append replay without deleting successful outputs");
        TerrainInputImportStatusData restoredStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(partialRequest));
        Check(restoredStatus.Result != null && OperationsMatch(restoredStatus.Operations, partial.Operations),
            "Restoring the captured HDF dependencies and staged TIFF makes the same terminal result recoverable again");

        Dictionary<string, string> reversedFields = partialRequest.Model.Fields
            .OrderByDescending(pair => pair.Key, StringComparer.Ordinal)
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        TerrainInputAppendRequest reorderedRequest = partialRequest with
        { Model = partialRequest.Model with { Fields = reversedFields } };
        TerrainInputImportStatusData reorderedStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(reorderedRequest));
        Check(reorderedStatus.Result?.BatchStatus == "Partial",
            "The request digest canonicalizes dictionary order while preserving all values");
        TerrainInputAppendRequest changedImagesRequest = partialRequest with
        {
            Model = partialRequest.Model with { Images = new Dictionary<string, ImageData[]> {
                ["terrain-test-images"] = [new ImageData("image-1", "changed", [1, 2, 3])] } }
        };
        await RejectArgument(() => ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(changedImagesRequest)));
        TerrainInputAppendRequest changedProjectXmlRequest = partialRequest with
        { Model = partialRequest.Model with { ProjectXml = "<Project/>" } };
        await RejectArgument(() => ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(changedProjectXmlRequest)));
        TerrainInputAppendResult sameTokenRetry = await ModelEditorAdapter.AppendTerrainInputsAsync(partialRequest);
        Check(sameTokenRetry.Snapshot.Terrain?.Inputs.Length == 3
            && sameTokenRetry.Operations.Select(item => item.Status).SequenceEqual(["Staged", "Failed"]),
            "Replaying an identical request with the same tokens returns the cached envelope without duplicating staged input");

        // Correct the same failed source with fresh projected coordinates.
        // The retry must use the new inspection identity and content revision,
        // never the stale SHA from the failed conversion attempt.
        WriteFloatRaster(projectionFailureTile, project.Projection, 800_000, 1_000_000, 64, 64, 17f);
        byte[] correctedProjectionTileBytes = File.ReadAllBytes(projectionFailureTile);
        TerrainInputImportInspectData correctedProjectionInspection = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [projectionFailureTile]));
        TerrainInputImportSource correctedProjectionSource = correctedProjectionInspection.Sources.Single();
        Check(correctedProjectionSource.IsValid && correctedProjectionSource.Revision != projectionFailureSource.Revision,
            "Correcting the failed source produces a newly inspected source revision");
        string retryBatchToken = Guid.NewGuid().ToString("N");
        TerrainInputAppendRequest retryRequest = new(Model(snapshot),
            [new(correctedProjectionSource.Path, correctedProjectionSource.Revision, "None", "Default", SourceId: correctedProjectionSource.Id)],
            StitchTiles: false, DraftToken: draftToken, BatchToken: retryBatchToken);
        TerrainInputAppendResult retryResult = await ModelEditorAdapter.AppendTerrainInputsAsync(retryRequest);
        snapshot = retryResult.Snapshot;
        Check(retryResult.BatchStatus == "Completed" && retryResult.Operations.Single().Status == "Staged"
            && retryResult.Operations.Single().SourceIDs.SequenceEqual([correctedProjectionSource.Id])
            && snapshot.Terrain?.Inputs.Length == 4 && File.Exists(stagedPath),
            "A corrected failed source retries under a new token and revision without losing previously staged batches");

        string slowTile = Path.Combine(inputDirectory, "cancel-during-conversion.tif");
        WriteFloatRaster(slowTile, project.Projection, 900_000, 1_000_000, 4096, 4096, 15f);
        byte[] slowTileBytes = File.ReadAllBytes(slowTile);
        TerrainInputImportInspectData cancelInspection = await ModelEditorAdapter.InspectTerrainInputImportAsync(
            new(Model(snapshot), [firstTile, slowTile]));
        TerrainInputImportSelection[] cancelSelections = cancelInspection.Sources.Select(source =>
            new TerrainInputImportSelection(source.Path, source.Revision, "None", "Default", SourceId: source.Id)).ToArray();
        string cancelBatchToken = Guid.NewGuid().ToString("N");
        TerrainInputAppendRequest cancelRequest = new(Model(snapshot), cancelSelections,
            StitchTiles: false, DraftToken: draftToken, BatchToken: cancelBatchToken);
        Task<TerrainInputAppendResult> cancelAppend = ModelEditorAdapter.AppendTerrainInputsAsync(cancelRequest);
        TerrainInputImportStatusData runningStatus = new("NotFound", null, []);
        TerrainInputOperationResult? slowOperation = null;
        DateTime cancelDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (DateTime.UtcNow < cancelDeadline)
        {
            runningStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
                new TerrainInputImportStatusRequest(cancelRequest));
            slowOperation = runningStatus.Operations.SingleOrDefault(operation =>
                operation.SourceIDs.Contains(cancelInspection.Sources[1].Id, StringComparer.Ordinal));
            if (runningStatus.State == "Running" && slowOperation is { Status: "Running", Progress: > 0 and < 0.99 }) break;
            await Task.Delay(20);
        }
        Check(slowOperation is { Status: "Running", Progress: > 0 and < 0.99 },
            "The actual converter publishes in-flight tile progress through its ProgressReporter");
        TerrainInputImportCancelResult cancellation = ModelEditorAdapter.CancelTerrainInputImport(
            new(new ModelRequest(assetPath, "Terrain", projectPath), draftToken, cancelBatchToken, slowOperation!.OperationID));
        Check(cancellation.Accepted && cancellation.OperationID == slowOperation.OperationID,
            "A running conversion accepts an operation-scoped cancellation request");
        TerrainInputAppendResult cancelled = await cancelAppend.WaitAsync(TimeSpan.FromSeconds(60));
        snapshot = cancelled.Snapshot;
        Check(cancelled.BatchStatus == "CancelledPartial"
            && cancelled.Operations.Single(operation => operation.OperationID == slowOperation.OperationID).Status == "Cancelled"
            && cancelled.Operations.Any(operation => operation.SourceIDs.Contains(cancelInspection.Sources[0].Id, StringComparer.Ordinal)
                && operation.Status == "Staged")
            && snapshot.Terrain?.Inputs.Length == 5,
            "BatchJob cancellation reaches the real TiffExportEngine while preserving its successful sibling output");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(originalProject)
            && File.ReadAllBytes(slowTile).SequenceEqual(slowTileBytes),
            "Partial cancellation leaves the original HDF, project XML and source raster bytes unchanged before Save");
        TerrainInputImportStatusData cancelledStatus = await ModelEditorAdapter.GetTerrainInputImportStatusAsync(
            new TerrainInputImportStatusRequest(cancelRequest));
        Check(cancelledStatus.State == "CancelledPartial"
            && cancelledStatus.Result?.Operations.Select(operation => operation.Status)
                .SequenceEqual(cancelled.Operations.Select(operation => operation.Status)) == true,
            "Status recovery retains the terminal cancellation outcome and successful staged sibling");

        MutateRaster(baseRasterPath, 99f);
        await RejectChangedSource(() => ModelEditorAdapter.SaveAsync(Model(snapshot)));
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(originalProject)
            && File.Exists(stagedPath),
            "An original terrain dependency changed during the draft is rejected without publishing HDF or deleting pending input");
        File.WriteAllBytes(baseRasterPath, originalBaseRaster);

        // FileHelpers.UniqueFilename only checks File.Exists. A directory at
        // the exact destination therefore deterministically makes the
        // subsequent FileMode.CreateNew publish fail without a timing race.
        string expectedDestination = Path.Combine(
            Path.GetDirectoryName(assetPath)!, "TerrainImport." + stagedInput.Name + ".tif");
        Check(!File.Exists(expectedDestination) && !Directory.Exists(expectedDestination),
            "The expected first raster destination is unused before the publish failure fixture");
        Directory.CreateDirectory(expectedDestination);
        bool publishFailed = false;
        try
        {
            await ModelEditorAdapter.SaveAsync(Model(snapshot));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            publishFailed = true;
        }
        Check(publishFailed && Directory.Exists(expectedDestination),
            "A deterministic destination collision rejects raster publication before creating an output file");
        Check(File.ReadAllBytes(assetPath).SequenceEqual(originalHdf)
            && File.Exists(stagedPath) && Hash(stagedPath).Length == 64,
            "A raster destination I/O failure leaves the original HDF and pending batch available for retry");

        Directory.Delete(expectedDestination);
        snapshot = await ModelEditorAdapter.SaveAsync(Model(snapshot));
        Check(snapshot.Terrain is { ImportDraftToken: null, ImportCleanupWarning: null }
            && !Directory.Exists(draftDirectory),
            "Successful HDF publication clears the import token and cleans its pending batch");
        using (var saved = new Terrain(assetPath))
        {
            RasterTerrainInput[] rasters = saved.Layers.OfType<RasterTerrainInput>().ToArray();
            Check(rasters.Length == 5 && rasters.Any(input => Path.GetFullPath(input.Filename) != Path.GetFullPath(baseRasterPath)
                && File.Exists(input.Filename) && Path.GetDirectoryName(input.Filename) == Path.GetDirectoryName(assetPath)),
                "Normal Terrain save publishes all successful import outputs beside the HDF and serializes each source input exactly once");
        }
        Check(File.ReadAllBytes(projectPath).SequenceEqual(originalProject)
            && File.ReadAllBytes(baseRasterPath).SequenceEqual(originalBaseRaster)
            && File.ReadAllBytes(firstTile).SequenceEqual(firstTileBytes)
            && File.ReadAllBytes(secondTile).SequenceEqual(secondTileBytes)
            && File.ReadAllBytes(slowTile).SequenceEqual(slowTileBytes)
            && File.ReadAllBytes(projectionFailureTile).SequenceEqual(correctedProjectionTileBytes)
            && File.Exists(noDataTile),
            "Successful import preserves project metadata and every selected/existing source raster");

        Console.WriteLine("Terrain AddTerrainInput inspection, SmartMerge, per-file partial staging, cancellation, request-digest recovery, retry, dependency protection and HDF save passed.");
    }

    private static bool IsFiniteOrNull(double? value) => value is null || double.IsFinite(value.Value);

    private static bool OperationsMatch(TerrainInputOperationResult[] left, TerrainInputOperationResult[] right) =>
        left.Length == right.Length && left.Zip(right).All(pair =>
            pair.First.OperationID == pair.Second.OperationID
            && pair.First.Order == pair.Second.Order
            && pair.First.SourceIDs.SequenceEqual(pair.Second.SourceIDs, StringComparer.Ordinal)
            && pair.First.SourcePaths.SequenceEqual(pair.Second.SourcePaths, StringComparer.Ordinal)
            && pair.First.SourceRevisions.SequenceEqual(pair.Second.SourceRevisions, StringComparer.Ordinal)
            && pair.First.Status == pair.Second.Status
            && pair.First.OutputInputID == pair.Second.OutputInputID
            && pair.First.OutputName == pair.Second.OutputName
            && pair.First.Diagnostic == pair.Second.Diagnostic
            && pair.First.Progress == pair.Second.Progress);

    private static bool StatusUnavailableForChangedSource(TerrainInputImportStatusData status,
        TerrainInputAppendResult expected) => status.State == expected.BatchStatus
            && status.Result == null
            && status.ResultUnavailableCode == "sourceChanged"
            && !string.IsNullOrWhiteSpace(status.Diagnostic)
            && OperationsMatch(status.Operations, expected.Operations);

    private static void WriteFloatRaster(string path, Projection projection, double left, double top,
        int width, int height, float value, double cellSize = 30)
    {
        if (File.Exists(path)) File.Delete(path);
        using var driver = Gdal.GetDriverByName("GTiff");
        using var dataset = driver.Create(path, width, height, 1, DataType.GDT_Float32, ["TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"]);
        dataset.SetGeoTransform([left, cellSize, 0, top, 0, -cellSize]);
        dataset.SetProjection(projection.GetWKT());
        using var band = dataset.GetRasterBand(1);
        band.SetNoDataValue(-9999);
        band.Fill(value, 0);
    }

    private static void MutateRaster(string path, float value)
    {
        using Dataset dataset = Gdal.Open(path, Access.GA_Update) ?? throw new InvalidOperationException("Could not reopen the base terrain TIFF for the dependency check.");
        using Band band = dataset.GetRasterBand(1);
        band.WriteRaster(0, 0, 1, 1, [value], 1, 1, 0, 0);
    }

    private static byte[]? ReadAuxiliaryMetadata(string path)
    {
        string sidecar = path + ".aux.xml";
        return File.Exists(sidecar) ? File.ReadAllBytes(sidecar) : null;
    }

    private static bool AuxBytesUnchanged(string path, byte[]? expected)
    {
        byte[]? current = ReadAuxiliaryMetadata(path);
        return expected is null ? current is null : current is not null && current.SequenceEqual(expected);
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));

    private static async Task RejectArgument(Func<Task> action)
    {
        try { await action(); }
        catch (ArgumentException) { return; }
        throw new InvalidOperationException("Invalid terrain import selection was accepted.");
    }

    private static async Task RejectChangedSource(Func<Task> action)
    {
        try { await action(); }
        catch (SourceFileChangedException) { return; }
        throw new InvalidOperationException("A changed original terrain dependency was accepted.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
