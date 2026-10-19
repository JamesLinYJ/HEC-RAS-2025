using System.Text;
using Utility.DataStructures;
using Utility.Extensions;
using Utility.Filtering;

if (args.Length == 3 && args[0] == "--background-map-cache-lock-probe")
{
    await BackgroundMapTileDiskCacheChecks.RunLockProbeAsync(args[1], args[2]);
    return;
}

using (var encoded = new MemoryStream())
{
    using (var writer = new BinaryWriter(encoded, Encoding.ASCII, leaveOpen: true))
    {
        writer.WriteStringA("short");
        writer.WriteStringA(new string('x', 4096));
        writer.WriteStringA("");
        writer.Write(0x12345678);
    }
    using var input = new FragmentedStream(encoded.ToArray());
    using var reader = new BinaryReader(input);
    Check(await reader.ReadStringAsync() == "short", "Fragmented string read");
    Check(await reader.ReadStringAsync() == new string('x', 4096), "String larger than former fixed buffer");
    Check(await reader.ReadStringAsync() == "", "Empty string");
    Check(reader.ReadInt32() == 0x12345678, "Following record not consumed");
}
await Expect<InvalidDataException>(async () =>
{
    using var reader = new BinaryReader(new MemoryStream(BitConverter.GetBytes(-1)));
    await reader.ReadStringAsync();
});
await Expect<EndOfStreamException>(async () =>
{
    using var reader = new BinaryReader(new MemoryStream([5, 0, 0, 0, 65, 66]));
    await reader.ReadStringAsync();
});
var values = new ReadOnlyAdvancedCompositeCollection<string?> { ItemsSource1 = new string?[] { "first", null }, ItemsSource2 = new[] { "last" } };
Check(values.IndexOf(null) == 1 && values.IndexOf("last") == 2 && values.IndexOf("absent") == -1, "Composite collection null/equality and source offsets");
var numbers = new ReadOnlyAdvancedCompositeCollection<int> { ItemsSource1 = new[] { 0, 2 }, ItemsSource2 = new[] { 3 } };
Check(numbers.IndexOf(0) == 0 && numbers.IndexOf(3) == 2, "Value-type composite collection equality");
int threshold = 2, resets = 0;
var filter = new FunctionalFilter<int>(value => value >= threshold);
filter.FilterStatusChanged += _ => resets++;
threshold = 3; filter.Reset();
Check(resets == 1 && filter.Filter([1, 2, 3]).SequenceEqual(new[] { 3 }), "Reset notifies listeners after predicate context changes");

int active = 0, maximum = 0, completed = 0;
var tasks = Enumerable.Range(0, 20).Select(index => new Task(() =>
{
    int count = Interlocked.Increment(ref active);
    int old;
    do { old = Volatile.Read(ref maximum); if (count <= old) break; }
    while (Interlocked.CompareExchange(ref maximum, count, old) != old);
    try
    {
        Thread.Sleep(2);
        if (index == 2) throw new InvalidOperationException("Expected worker failure");
    }
    finally { Interlocked.Decrement(ref active); Interlocked.Increment(ref completed); }
})).ToArray();
await Expect<InvalidOperationException>(() => Utility.Parallel.LimitAsyncWorse(() => tasks, 2).WaitAsync(TimeSpan.FromSeconds(10)));
Check(completed == 20 && maximum <= 2 && active == 0, "Parallel lanes retain limit, continue after failure and observe completion");
await RuntimeChecks.Run();
ProjectionChecks.Run();
ReprojectionChecks.Run();
ExternalConnectionChecks.Run();
AttributeTableChecks.Run();
RasterSymbologyChecks.Run();
MapSourceIdentityChecks.Run();
TableFilterChecks.Run();
DssRecordChecks.Run();
SourceModelChecks.Run();
LegacySourceChecks.Run();
await PlanEditorChecks.Run();
await PlanContextRefreshChecks.Run();
await SourcePathAliasChecks.Run();
await ModelEditorChecks.Run();
await GeometryTopologyChecks.Run();
await GeometryTopologyToolChecks.Run();
await GeometryMeshChecks.Run();
await GeometryCulvertChecks.Run();
await GeometryCulvertResetChecks.Run();
await BoundarySpatialChecks.Run();
await BoundarySeriesChecks.Run();
await BoundaryPayloadChecks.Run();
await BoundaryLineMapChecks.Run();
SpatialDataPersistenceChecks.Run();
await SpatialEditorChecks.Run();
UnitCalculatorChecks.Run();
WilcockChecks.Run();
ClassicCrossSectionChecks.Run();
await UnitConversionChecks.Run();
await SpatialDraftModeChecks.Run();
await SpatialGridChecks.Run();
await SpatialGridTimeBehaviorChecks.Run();
await ManningEditorChecks.Run();
await ClassificationEditorChecks.Run();
await ClassificationImportChecks.Run();
VectorDimensionChecks.Run();
MapPolylineGeoprocessChecks.Run();
MapTreeShapefileImportChecks.Run();
MapVectorSourceChecks.Run();
GeoprocessingToolChecks.Run();
await FeatureQueryChecks.Run();
await ClassificationGeometryChecks.Run();
await ClassificationPasteChecks.Run();
await PlanComputeJobMessageChecks.Run();
await TerrainEditorChecks.Run();
await TerrainInputAppendChecks.Run();
ModelCreationChecks.Run();
SurfaceCreationChecks.Run();
ResultInspectorChecks.Run();
PlanResultCatalogChecks.Run();
PlanResultAssociationChecks.Run();
WorkspaceFileImportChecks.Run();
CatalogModelActionChecks.Run();
CatalogModelContextActionChecks.Run();
await PlanComputeChecks.Run();
using var sourceFixtureLease = new SourceAcceptanceFixtureLease();
await PlanCulvertParticleChecks.Run();
await InitialConditionsTransactionChecks.Run();
await BoundaryInitialConditionsChecks.Run();
// The real CPU fixture above is a required producer. These later groups
// retain execution order but report every independent failure in one run.
var finalSourceChecks = new SourceCheckPhase();
await finalSourceChecks.Run(nameof(TerrainTopologyChecks), TerrainTopologyChecks.Run);
await finalSourceChecks.Run(nameof(MapTreeWindChildChecks), MapTreeWindChildChecks.Run);
await finalSourceChecks.Run(nameof(GeometryMeshPropertyTablesChecks), GeometryMeshPropertyTablesChecks.Run);
await finalSourceChecks.Run(nameof(GeometryMeshGenerationDuplexChecks), GeometryMeshGenerationDuplexChecks.Run);
await finalSourceChecks.Run(nameof(TerrainUSGSImportChecks), TerrainUSGSImportChecks.Run);
await finalSourceChecks.Run(nameof(MapResultOwnedGeometryChecks), MapResultOwnedGeometryChecks.Run);
await finalSourceChecks.Run(nameof(CatalogTreeChecks), CatalogTreeChecks.Run);
await finalSourceChecks.Run(nameof(CatalogDiagnosticsChecks), CatalogDiagnosticsChecks.Run);
await finalSourceChecks.Run(nameof(ResultComputeCatalogChecks), ResultComputeCatalogChecks.Run);
await finalSourceChecks.Run(nameof(GeometryBackupChecks), GeometryBackupChecks.Run);
await finalSourceChecks.Run(nameof(GeometryNamedBackupChecks), GeometryNamedBackupChecks.Run);
await finalSourceChecks.Run(nameof(SpatialPointConnectionChecks), SpatialPointConnectionChecks.Run);
await finalSourceChecks.Run(nameof(BackgroundMapOsmCpuChecks), BackgroundMapOsmCpuChecks.Run);
await finalSourceChecks.Run(nameof(BackgroundMapTileDiskCacheChecks), BackgroundMapTileDiskCacheChecks.Run);
await finalSourceChecks.Run(nameof(MapTreeLayerDiagnosticsChecks), MapTreeLayerDiagnosticsChecks.Run);
await finalSourceChecks.Run(nameof(MapTreeChecks), MapTreeChecks.Run);
await finalSourceChecks.Run(nameof(GeometryProjectMapChecks), GeometryProjectMapChecks.Run);
await finalSourceChecks.Run(nameof(AssociatedMapLayersChecks), AssociatedMapLayersChecks.Run);
await finalSourceChecks.Run(nameof(AssociatedRasterStyleChecks), AssociatedRasterStyleChecks.Run);
await finalSourceChecks.Run(nameof(MapLayerActionChecks), MapLayerActionChecks.Run);
await finalSourceChecks.Run(nameof(MapRasterImportChecks), MapRasterImportChecks.Run);
await finalSourceChecks.Run(nameof(MapResultChartChecks), MapResultChartChecks.Run);
await finalSourceChecks.Run(nameof(MapMultiResultDetailChecks), MapMultiResultDetailChecks.Run);
await finalSourceChecks.Run(nameof(PortableResultMapperChecks), PortableResultMapperChecks.Run);
await finalSourceChecks.Run(nameof(MapResultRenderChecks), MapResultRenderChecks.Run);
await finalSourceChecks.Run(nameof(MapDynamicProfileChecks), MapDynamicProfileChecks.Run);
await finalSourceChecks.Run(nameof(MapDynamicProfileLegacyMaximumChecks), MapDynamicProfileLegacyMaximumChecks.Run);
await finalSourceChecks.Run(nameof(GeometryCulvertMapCommandChecks), GeometryCulvertMapCommandChecks.Run);
await finalSourceChecks.Run(nameof(ResultPlanContextChecks), ResultPlanContextChecks.Run);
await finalSourceChecks.Run(nameof(ResultPlanSettingsChecks), ResultPlanSettingsChecks.Run);
await finalSourceChecks.Run(nameof(TerrainInputMapContextChecks), TerrainInputMapContextChecks.Run);
await finalSourceChecks.Run(nameof(SourcePropertyValidationChecks), SourcePropertyValidationChecks.Run);
await finalSourceChecks.Run(nameof(BugReportChecks), BugReportChecks.Run);
await finalSourceChecks.Run(nameof(BackendApplicationLoggingChecks), BackendApplicationLoggingChecks.Run);
await finalSourceChecks.Run(nameof(StreamModeChecks), StreamModeChecks.RunAsync);
await finalSourceChecks.Run(nameof(GeoprocessingSourceOperationChecks), GeoprocessingSourceOperationChecks.RunAsync);
await finalSourceChecks.Run(nameof(StableChannelDebugChecks), StableChannelDebugChecks.Run);
await finalSourceChecks.Run(nameof(DeveloperProjectArchiveChecks), DeveloperProjectArchiveChecks.Run);
await finalSourceChecks.Run(nameof(TestingServiceChecks), TestingServiceChecks.Run);
await finalSourceChecks.Run(nameof(MapShapefilePolylineDraftChecks), MapShapefilePolylineDraftChecks.Run);
await finalSourceChecks.Run(nameof(ProjectLibraryChecks), ProjectLibraryChecks.Run);
await finalSourceChecks.Run(nameof(WorkspaceUpdateChecks), WorkspaceUpdateChecks.Run);
await finalSourceChecks.Run(nameof(PlanAnalysisChecks), PlanAnalysisChecks.Run);
await finalSourceChecks.Run(nameof(MapTerrainElevationChecks), MapTerrainElevationChecks.Run);
await finalSourceChecks.Run(nameof(LinkedResultProfilesChecks), LinkedResultProfilesChecks.Run);
await finalSourceChecks.Run(nameof(LinkedResultMapChecks), LinkedResultMapChecks.Run);
await finalSourceChecks.Run(nameof(VectorSymbologyChecks), VectorSymbologyChecks.Run);
await finalSourceChecks.Run(nameof(DisplayUnitChoiceChecks), DisplayUnitChoiceChecks.Run);
await finalSourceChecks.Run(nameof(GeometryTopologyRenderInputChecks), GeometryTopologyRenderInputChecks.Run);
await finalSourceChecks.Run(nameof(GeometryTopologyCompletionChecks), GeometryTopologyCompletionChecks.Run);
await finalSourceChecks.Run(nameof(GeometryMeshArcPreviewChecks), GeometryMeshArcPreviewChecks.Run);
await finalSourceChecks.Run(nameof(GeometryMeshSideArcDiagnosticsChecks), GeometryMeshSideArcDiagnosticsChecks.Run);
await finalSourceChecks.Run(nameof(PlanPrecomputeChecks), PlanPrecomputeChecks.Run);
await finalSourceChecks.Run(nameof(PlanPrecomputeAssociatedDraftChecks), PlanPrecomputeAssociatedDraftChecks.Run);
await finalSourceChecks.Run(nameof(RasterImportContextPropertiesChecks), RasterImportContextPropertiesChecks.Run);
await finalSourceChecks.Run(nameof(TemporalInputChecks), TemporalInputChecks.Run);
await finalSourceChecks.Run(nameof(ProjectMigrationChecks), ProjectMigrationChecks.Run);
await finalSourceChecks.Run(nameof(HdfUnicodeChecks), HdfUnicodeChecks.Run);
await finalSourceChecks.Run(nameof(ModelSaveFailureChecks), ModelSaveFailureChecks.Run);
await finalSourceChecks.Run(nameof(PlanExportChecks), PlanExportChecks.Run);
await finalSourceChecks.Run(nameof(ResultProfileChecks), ResultProfileChecks.Run);
await finalSourceChecks.Run(nameof(ResultProfileSampleLineChecks), ResultProfileSampleLineChecks.Run);
finalSourceChecks.ThrowIfFailed();
Console.WriteLine("Backend source regression checks passed on " + System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier + ".");

static void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
}
static async Task Expect<T>(Func<Task> action) where T : Exception
{
    try { await action(); }
    catch (T) { return; }
    throw new InvalidOperationException("Expected " + typeof(T).Name);
}
sealed class FragmentedStream(byte[] bytes) : MemoryStream(bytes, writable: false)
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        => base.ReadAsync(buffer[..Math.Min(buffer.Length, 1)], cancellationToken);
}
