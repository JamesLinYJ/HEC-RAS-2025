using System.Buffers;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Geospatial.Rasters;
using Geospatial.Vectors;
using Geospatial.Vectors.Meshes;
using Ras.Layers;
using Ras.Layers.Results;
using Ras.Mapping;
using Ras.Output;
using Ras.Rendering;
using Utility.Files;
using Utility.Memory;

namespace Ras.Backend;

/// <summary>
/// Renders from the retained compute Result on its TimestepAdded callback.
/// It uses ResultMapRenderLayer and the writer's supported write-mode reads;
/// it never creates a second Result/HDF reader or a stable Result revision.
/// </summary>
internal sealed class PlanComputeLiveMapRenderer : IDisposable
{
    private const int MaximumRasterSide = 384;
    private const float NoDataValue = -9999f;
    private static readonly long MinimumFrameInterval = Stopwatch.Frequency / 2;
    private readonly Project project;
    private readonly Result result;
    private readonly string resultPath;
    private readonly Func<ResultComputeEnvelope> computeIdentity;
    private readonly PlanComputeLiveMapTargetRegistry targets;
    private readonly Action<BackendOperationProgress> report;
    private readonly object gate = new();
    private readonly Dictionary<string, long> lastFrameTicks = new(StringComparer.Ordinal);
    private readonly List<CapturedProfile> capturedProfiles = [];
    private readonly IHorizontalOutputBlock? block;
    private bool disposed;

    private sealed record CapturedProfile(int Index, string Name, DateTime Time, string WireTime);

    public PlanComputeLiveMapRenderer(Project project, Result result, string resultPath,
        Func<ResultComputeEnvelope> computeIdentity, PlanComputeLiveMapTargetRegistry targets,
        Action<BackendOperationProgress> report)
    {
        this.project = project;
        this.result = result;
        this.resultPath = SourceFilePaths.Canonical(resultPath);
        this.computeIdentity = computeIdentity;
        this.targets = targets;
        this.report = report;
        block = result.BaseOutputBlock;
        if (block is not null)
        {
            block.TimestepAdded += OnTimestepAdded;
            // Match the profile publisher's initial snapshot. The source may
            // already own rows before this compute-start callback subscribes.
            CaptureProducedProfiles();
        }
    }

    private void OnTimestepAdded()
    {
        lock (gate)
        {
            if (disposed || block is null) return;
            if (!CaptureProducedProfiles()) return;
            RenderTargetsLocked();
        }
    }

    /// <summary>
    /// The source appends profile rows and metadata before raising TimestepAdded.
    /// Capture those immutable identities on that source callback; target changes
    /// can then redraw an already-produced row without reading mutable Lists.
    /// </summary>
    private bool CaptureProducedProfiles()
    {
        if (block is null) return false;
        try { MapResultRenderService.ValidateProfiles(block); }
        catch { return false; }

        string[] names = block.ProfileNames.ToArray();
        DateTime[] times = block.Times.ToArray();
        if (names.Length != times.Length || names.Length < capturedProfiles.Count) return false;
        for (int index = 0; index < capturedProfiles.Count; index++)
        {
            CapturedProfile existing = capturedProfiles[index];
            if (!string.Equals(existing.Name, names[index], StringComparison.Ordinal) ||
                existing.Time != times[index]) return false;
        }
        for (int index = capturedProfiles.Count; index < names.Length; index++)
        {
            DateTime time = times[index];
            capturedProfiles.Add(new(index, names[index], time,
                time.ToString("O", CultureInfo.InvariantCulture)));
        }
        return true;
    }

    /// <summary>Redraws accepted target changes from cached source profiles.</summary>
    public void TargetsChanged()
    {
        lock (gate)
        {
            if (disposed || block is null) return;
            lastFrameTicks.Clear();
            RenderTargetsLocked();
        }
    }

    private void RenderTargetsLocked()
    {
        if (block is null || capturedProfiles.Count == 0) return;
        var snapshot = targets.Snapshot();
        ResultComputeEnvelope identity = computeIdentity();
        if (identity.State != "running" || identity.ResultPath is null ||
            SourceFilePaths.Canonical(identity.ResultPath) != resultPath) return;

        foreach (PlanComputeLiveMapRenderTarget target in snapshot.Targets)
        {
            if (!TryReserve(target.TargetID)) continue;
            try
            {
                PlanComputeLiveMapRenderFrame? frame = null;
                try
                {
                    frame = Render(target, identity, snapshot.Sequence);
                }
                catch (Exception error) when (error is NotImplementedException or ArgumentException or
                                              InvalidDataException or FileNotFoundException or
                                              NotSupportedException or SourceFileChangedException)
                {
                    // Velocity has its own real payload and unsupported state;
                    // an RGBA render failure must not suppress that event.
                }
                PlanComputeLiveVelocityFrame? velocityFrame = null;
                PlanComputeLiveVelocityUnavailable? velocityUnavailable = null;
                if (target.CaptureVelocityParticles)
                {
                    try
                    {
                        velocityFrame = RenderVelocity(target, identity, snapshot.Sequence);
                    }
                    catch (NotImplementedException error)
                    {
                        velocityUnavailable = VelocityUnavailable(target, identity, snapshot.Sequence,
                            error.Message);
                    }
                    catch (Exception error) when (error is ArgumentException or InvalidDataException or
                                                  FileNotFoundException or NotSupportedException)
                    {
                        velocityUnavailable = VelocityUnavailable(target, identity, snapshot.Sequence,
                            error.Message);
                    }
                }
                if (frame is not null || velocityFrame is not null || velocityUnavailable is not null)
                    report(new(LiveMapFrame: frame, LiveVelocityFrame: velocityFrame,
                        LiveVelocityUnavailable: velocityUnavailable));
            }
            catch (Exception error) when (error is ArgumentException or InvalidDataException or
                                          FileNotFoundException or NotSupportedException or SourceFileChangedException)
            {
                // A stale viewport/source target must not produce a raster.
            }
        }
    }

    private PlanComputeLiveVelocityFrame? RenderVelocity(PlanComputeLiveMapRenderTarget target,
        ResultComputeEnvelope identity, ulong targetSequence)
    {
        if (block is null || !target.CaptureVelocityParticles ||
            target.SelectionIndex != 0 ||
            !string.Equals(target.SelectedMapType, nameof(MapTypes.Velocity), StringComparison.Ordinal) ||
            !string.Equals(target.RunID, identity.RunId, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(target.OperationOwnerToken) ||
            !string.Equals(target.ProjectPath, identity.ProjectPath, PathComparison) ||
            !string.Equals(target.ProjectRevision, identity.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(target.ProjectXmlFingerprint, identity.ProjectXmlFingerprint, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(SourceFilePaths.Canonical(target.PlanPath), identity.PlanPath, PathComparison) ||
            !string.Equals(target.PlanRevision, identity.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(SourceFilePaths.Canonical(target.Map.ProjectPath), identity.ProjectPath, PathComparison) ||
            !string.Equals(target.Map.ProjectXmlSHA, target.ProjectXmlFingerprint, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(target.Node.NodeType, "MultiResult", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(target.Node.AssetID) ||
            !string.Equals(SourceFilePaths.Canonical(target.Node.AssetID), identity.PlanPath, PathComparison) ||
            string.IsNullOrWhiteSpace(target.ContextToken) || string.IsNullOrWhiteSpace(target.TargetID) ||
            !string.Equals(target.OutputBlockName, block.Name, StringComparison.Ordinal) ||
            !IsSelectedRun(target, identity.ResultPath!)) return null;

        string projectPath = SourceFilePaths.Canonical(target.Map.ProjectPath);
        string planPath = SourceFilePaths.Canonical(target.PlanPath);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        if (!File.Exists(visualizationPath) ||
            !string.Equals(ComputeRevision(projectPath), target.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(planPath), target.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(visualizationPath), target.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeDigest(target.Map.ProjectXml ?? string.Empty), target.Map.ProjectXmlSHA,
                StringComparison.OrdinalIgnoreCase)) return null;

        if (result.AssociatedTerrain is not { } terrain || result.Geometry?.FlowAreaLayer is not { Count: > 0 } flowArea)
            return null;
        if (flowArea.Count > 1) throw new NotImplementedException("The retained writer-mode Result reader supports one FlowAreaLayer.");
        if (block.ProfileCount <= 0 || block.ProfileCount != capturedProfiles.Count) return null;
        int profileIndex = ResolveProfileIndex(target);
        if (profileIndex < 0 || profileIndex >= capturedProfiles.Count) return null;
        CapturedProfile profile = capturedProfiles[profileIndex];
        if (target.ProfileTime is { Length: > 0 } expectedTime &&
            !string.Equals(profile.WireTime, expectedTime, StringComparison.Ordinal)) return null;
        if (target.ProfileName is { Length: > 0 } expectedName &&
            !string.Equals(profile.Name, expectedName, StringComparison.Ordinal)) return null;

        RasterMapViewExtent viewport = BoundViewport(target.Viewport);
        MapResultRenderService.ValidateViewport(viewport);
        var terrainSnapshot = MapResultRenderService.CaptureTerrainSources(terrain);
        var definition = new RasterDefinition(new Extent(viewport.MinX, viewport.MaxX,
            viewport.MinY, viewport.MaxY), viewport.PixelHeight, viewport.PixelWidth);
        if (!definition.IsValid() || definition.CellCount <= 0 ||
            !double.IsFinite(definition.CellSize) || definition.CellSize <= 0) return null;

        var layer = new ResultMapRenderLayer(block, MapTypes.Velocity, terrain, flowArea.AllPropertyTables());
        if (layer.Mapper is not VelocityMapper mapper) return null;
        var mapPoints = new GeometryMapPoints(result.Geometry!, definition);
        using IMemoryOwner<float> terrainOwner = SharedMemoryPool<float>.Rent(definition.CellCount);
        Memory<float> terrainValues = terrainOwner.Memory.Slice(0, definition.CellCount);
        terrain.Resample(new ResampleArgs(definition), terrainValues);
        float[] velocityX = new float[definition.CellCount];
        float[] velocityY = new float[definition.CellCount];
        float[] magnitude = new float[definition.CellCount];
        mapper.Compute(profileIndex, mapPoints, terrainValues, velocityX, velocityY, magnitude);

        MapResultRenderService.VerifyTerrainSources(terrainSnapshot);
        if (!string.Equals(ComputeRevision(projectPath), target.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(planPath), target.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(visualizationPath), target.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(SourceFilePaths.Canonical(result.Filename ?? string.Empty), resultPath, PathComparison))
            return null;

        byte[] interleaved = PackVelocity(velocityX, velocityY, magnitude);
        return new PlanComputeLiveVelocityFrame(target.TargetID, target.ProjectSessionID,
            target.OperationOwnerToken, target.OperationContextID, identity.RunId, resultPath,
            block.Name, target.ContextToken, target.Map.MapID, target.NodeID, target.SelectionIndex,
            targetSequence, profile.Index, profile.Name, profile.WireTime,
            MapTypes.Velocity.ToString(), definition.Cols, definition.Rows, definition.CellSize,
            definition.MinX, definition.MinY, definition.MaxX, definition.MaxY, NoDataValue, interleaved);
    }

    private PlanComputeLiveVelocityUnavailable VelocityUnavailable(
        PlanComputeLiveMapRenderTarget target, ResultComputeEnvelope identity,
        ulong targetSequence, string message) => new(target.TargetID, target.ProjectSessionID,
            target.OperationOwnerToken, target.OperationContextID, identity.RunId,
            resultPath, block?.Name ?? target.OutputBlockName, target.ContextToken,
            target.Map.MapID, target.NodeID, target.SelectionIndex, targetSequence,
            string.IsNullOrWhiteSpace(message)
                ? "The active Result did not provide a readable live velocity field."
                : message);

    private static byte[] PackVelocity(float[] velocityX, float[] velocityY, float[] magnitude)
    {
        if (velocityX.Length != velocityY.Length || velocityX.Length != magnitude.Length)
            throw new InvalidDataException("The writer-owned velocity mapper returned arrays with different dimensions.");
        byte[] bytes = new byte[checked(velocityX.Length * 3 * sizeof(float))];
        for (int index = 0; index < velocityX.Length; index++)
        {
            int offset = checked(index * 3 * sizeof(float));
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(offset, sizeof(float)), velocityX[index]);
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(offset + sizeof(float), sizeof(float)), velocityY[index]);
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(offset + 2 * sizeof(float), sizeof(float)), magnitude[index]);
        }
        return bytes;
    }

    private bool TryReserve(string targetID)
    {
        long now = Stopwatch.GetTimestamp();
        lock (gate)
        {
            if (disposed) return false;
            if (lastFrameTicks.TryGetValue(targetID, out long previous) && now - previous < MinimumFrameInterval)
                return false;
            lastFrameTicks[targetID] = now;
            return true;
        }
    }

    private PlanComputeLiveMapRenderFrame? Render(PlanComputeLiveMapRenderTarget target,
        ResultComputeEnvelope identity, ulong targetSequence)
    {
        if (block is null || capturedProfiles.Count <= 0 ||
            !string.Equals(target.RunID, identity.RunId, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(target.OperationOwnerToken) ||
            !string.Equals(target.ProjectPath, identity.ProjectPath, PathComparison) ||
            !string.Equals(target.ProjectRevision, identity.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(target.ProjectXmlFingerprint, identity.ProjectXmlFingerprint, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(SourceFilePaths.Canonical(target.PlanPath), identity.PlanPath, PathComparison) ||
            !string.Equals(target.PlanRevision, identity.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(SourceFilePaths.Canonical(target.Map.ProjectPath), identity.ProjectPath, PathComparison) ||
            !string.Equals(target.Map.ProjectXmlSHA, target.ProjectXmlFingerprint, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(target.Node.NodeType, "MultiResult", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(target.Node.AssetID) ||
            !string.Equals(SourceFilePaths.Canonical(target.Node.AssetID), identity.PlanPath, PathComparison) ||
            !string.Equals(target.OutputBlockName, block.Name, StringComparison.Ordinal) ||
            target.SelectionIndex < 0 || target.SelectionIndex >= 32 ||
            string.IsNullOrWhiteSpace(target.ContextToken) || string.IsNullOrWhiteSpace(target.TargetID) ||
            !IsSelectedRun(target, identity.ResultPath!)) return null;

        string projectPath = SourceFilePaths.Canonical(target.Map.ProjectPath);
        string planPath = SourceFilePaths.Canonical(target.PlanPath);
        string visualizationPath = Path.ChangeExtension(projectPath, ".vis");
        if (!File.Exists(visualizationPath) ||
            !string.Equals(ComputeRevision(projectPath), target.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(planPath), target.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(visualizationPath), target.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeDigest(target.Map.ProjectXml ?? string.Empty), target.Map.ProjectXmlSHA,
                StringComparison.OrdinalIgnoreCase)) return null;

        MapTypes? mapType = MapResultRenderService.ParseSupportedMapType(target.SelectedMapType);
        if (mapType is null) return null;
        int profileIndex = ResolveProfileIndex(target);
        if (profileIndex < 0 || profileIndex >= capturedProfiles.Count) return null;
        CapturedProfile profile = capturedProfiles[profileIndex];
        string sourceTime = profile.WireTime;
        if (target.ProfileTime is { Length: > 0 } expectedTime &&
            !string.Equals(sourceTime, expectedTime,
                StringComparison.Ordinal)) return null;

        if (result.AssociatedTerrain is not { } terrain ||
            result.Geometry?.FlowAreaLayer?.AllPropertyTables() is not { Length: > 0 } tables) return null;
        var terrainSnapshot = MapResultRenderService.CaptureTerrainSources(terrain);
        RasterMapViewExtent viewport = BoundViewport(target.Viewport);
        MapResultRenderService.ValidateViewport(viewport);
        var layer = new ResultMapRenderLayer(block, mapType.Value, terrain, tables);
        layer.ProfileState.CurrentProfileIndex = profileIndex;
        layer.SetDefaultSymbology(project.Units);
        var definition = new RasterDefinition(new Extent(viewport.MinX, viewport.MaxX, viewport.MinY, viewport.MaxY),
            viewport.PixelHeight, viewport.PixelWidth);
        if (!definition.IsValid() || definition.CellCount <= 0) return null;
        if (!layer.Resample(definition, out float[] values) || values is null) return null;
        MapResultRenderService.VerifyTerrainSources(terrainSnapshot);
        if (!string.Equals(ComputeRevision(projectPath), target.ProjectRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(planPath), target.PlanRevision, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(ComputeRevision(visualizationPath), target.Map.ExpectedVisualizationRevision,
                StringComparison.OrdinalIgnoreCase)) return null;

        var argb = new int[values.Length];
        var symbology = layer.RasterSymbology;
        if (symbology is null || symbology.SurfaceFill is null || symbology.SurfaceFill.Colors.Count == 0 ||
            symbology.SurfaceFill.ColorValues.Length != symbology.SurfaceFill.Colors.Count) return null;
        if (symbology.IsSurfaceFillEnabled) symbology.PaintSurface(values, argb, NoDataValue);
        byte[] rgba = new byte[checked(argb.Length * 4)];
        for (int i = 0; i < argb.Length; i++)
        {
            uint pixel = unchecked((uint)argb[i]);
            rgba[i * 4] = (byte)(pixel >> 16);
            rgba[i * 4 + 1] = (byte)(pixel >> 8);
            rgba[i * 4 + 2] = (byte)pixel;
            rgba[i * 4 + 3] = (byte)(pixel >> 24);
        }
        string frameResultPath = SourceFilePaths.Canonical(result.Filename ?? string.Empty);
        if (frameResultPath != resultPath) return null;
        return new PlanComputeLiveMapRenderFrame(target.TargetID, target.ProjectSessionID,
            target.OperationOwnerToken, target.OperationContextID, identity.RunId, resultPath,
            block.Name, target.ContextToken, target.Map.MapID, target.NodeID,
            target.SelectionIndex, targetSequence, profileIndex, profile.Name,
            sourceTime, mapType.Value.ToString(),
            terrainSnapshot.Path, terrainSnapshot.Revision, MapResultRenderService.LayerUnits(project.Units, mapType.Value),
            definition.Cols, definition.Rows, rgba, definition.MinX, definition.MinY, definition.MaxX, definition.MaxY,
            NoDataValue, symbology.SurfaceFill.Colors.Select((color, index) =>
                new MapResultRenderLegendStop(EncodeColor(color), symbology.SurfaceFill.ColorValues[index])).ToArray());
    }

    private static bool IsSelectedRun(PlanComputeLiveMapRenderTarget target, string resultPath)
    {
        if (target.SelectionMode.Equals("Latest", StringComparison.OrdinalIgnoreCase)) return true;
        return target.SelectionMode.Equals("Explicit", StringComparison.OrdinalIgnoreCase) &&
            target.SelectedResultPath is { Length: > 0 } selected &&
            string.Equals(SourceFilePaths.Canonical(selected), SourceFilePaths.Canonical(resultPath), PathComparison);
    }

    private int ResolveProfileIndex(PlanComputeLiveMapRenderTarget target)
    {
        if (target.SelectionIndex == 0)
            return target.ProfileIndex >= 0 && target.ProfileIndex < capturedProfiles.Count
                ? target.ProfileIndex : -1;
        if (target.ProfileTime is not { Length: > 0 } selectedTime ||
            !DateTime.TryParse(selectedTime, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out DateTime targetTime)) return -1;
        foreach (CapturedProfile profile in capturedProfiles)
            if (Math.Abs((profile.Time - targetTime).Ticks) <= TimeSpan.TicksPerMillisecond * 10)
                return profile.Index;
        return -1;
    }

    private static RasterMapViewExtent BoundViewport(RasterMapViewExtent viewport)
    {
        double scale = Math.Min(1, (double)MaximumRasterSide / Math.Max(viewport.PixelWidth, viewport.PixelHeight));
        return viewport with
        {
            PixelWidth = Math.Max(1, (int)Math.Floor(viewport.PixelWidth * scale)),
            PixelHeight = Math.Max(1, (int)Math.Floor(viewport.PixelHeight * scale))
        };
    }

    private static string ComputeRevision(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string ComputeDigest(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static string EncodeColor(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}{color.A:X2}";
    private static StringComparison PathComparison => OperatingSystem.IsWindows()
        ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            if (block is not null) block.TimestepAdded -= OnTimestepAdded;
            lastFrameTicks.Clear();
            capturedProfiles.Clear();
        }
    }
}
