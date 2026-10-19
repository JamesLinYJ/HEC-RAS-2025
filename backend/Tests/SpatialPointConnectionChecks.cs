using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography;
using System.Text.Json;
using Geospatial.PairedData;
using Geospatial.Vectors;
using Ras.Backend;
using Ras.Layers;
using Ras.Layers.Meteorology;
using Utility.Files;
using Utility.Units;

internal static class SpatialPointConnectionChecks
{
    private sealed record FixtureConnection(string Name, string Path);
    private sealed record RemoteInput(string LayerId, string ConnectionName, string ConnectionPath,
        string TargetConnectionName, string TargetConnectionPath);
    private sealed record UnconfiguredRemoteInput(string LayerId, string ConnectionName, string ConnectionPath);
    private sealed record FunctionalInput(string LayerId, bool Enabled, string LocalDataType, double[] Values);
    private sealed record FixtureManifest(string Schema, bool Fresh, string ProjectPath, string BoundaryHdfPath,
        FixtureConnection[] Connections, RemoteInput RemoteInput, UnconfiguredRemoteInput UnconfiguredRemoteInput,
        FunctionalInput FunctionalInput,
        Dictionary<string, string> Files);

    internal static async Task Run()
    {
        using var temporary = new TemporaryDirectory();
        string projectPath = Path.Combine(temporary.FullName, "空间点连接配置.ras");
        string connectionsDirectory = Path.Combine(temporary.FullName, "连接数据");
        Directory.CreateDirectory(connectionsDirectory);
        string connectionAPath = Path.Combine(connectionsDirectory, "站点A.csv");
        string connectionBPath = Path.Combine(connectionsDirectory, "站点B.csv");
        File.WriteAllText(connectionAPath, "time,value\n2026-10-18T00:00:00Z,1\n");
        File.WriteAllText(connectionBPath, "time,value\n2026-10-18T00:00:00Z,2\n");

        var project = Project.CreateNew(projectPath, UnitSystem.SI);
        var boundary = project.AddNewBoundaryCondition("空间点连接配置", new DateTime(2026, 10, 18, 8, 0, 0), TimeSpan.FromHours(2));
        var station = new MeteorologicStation("共享站点", new Point(100, 200));
        boundary.MetStations.Add(station);
        var connectionA = project.ConnectionSource.AddFileConnection("站点连接 A", connectionAPath);
        var connectionB = project.ConnectionSource.AddFileConnection("站点连接 B", connectionBPath);
        var remote = new MetGaugedData(station)
        {
            DataLocation = DataLocation.Remote,
            LocalDataType = LocalDataType.Constant,
            ConnectionName = connectionA.Name,
            ConnectionPath = "/weather/station-a.csv"
        };
        boundary.Precipitation.Gauges.Add(remote);
        var unconfiguredRemote = new MetGaugedData(station)
        {
            DataLocation = DataLocation.Remote,
            LocalDataType = LocalDataType.Constant,
            ConnectionName = "",
            ConnectionPath = ""
        };
        boundary.Precipitation.Gauges.Add(unconfiguredRemote);
        double[] functionalValues = [12.5, 16.75, 19.25];
        var functional = new MetGaugedData(station)
        {
            IsEnabled = false,
            DataLocation = DataLocation.Local,
            LocalDataType = LocalDataType.Functional,
            TableTimeSeries = TimeSeriesDefinition.Regular(Time.Hours, 1),
            Table = functionalValues,
            Table2 = []
        };
        boundary.AirDensity.Gauges.Add(functional);

        project.Save();
        string boundaryHdfPath = boundary.Filename;
        boundary.Dispose();

        using (var sourceRead = new BoundaryCondition(boundaryHdfPath, project))
        {
            MetGaugedData persistedFunctional = sourceRead.AirDensity.Gauges.Single();
            Check(!persistedFunctional.IsEnabled && persistedFunctional.LocalDataType == LocalDataType.Functional
                && persistedFunctional.Table.SequenceEqual(functionalValues),
                "The retained source persists disabled Functional metadata and its existing table values without evaluation.");
            MetGaugedData persistedRemote = sourceRead.Precipitation.Gauges.Single(gauge => gauge.ConnectionName == connectionA.Name);
            Check(persistedRemote.DataLocation == DataLocation.Remote && persistedRemote.ConnectionName == connectionA.Name
                && persistedRemote.ConnectionPath == "/weather/station-a.csv",
                "The retained source persists remote connection name and path as source references.");
            MetGaugedData persistedUnconfigured = sourceRead.Precipitation.Gauges.Single(gauge => gauge.ConnectionName == "");
            Check(persistedUnconfigured.DataLocation == DataLocation.Remote && persistedUnconfigured.ConnectionPath == "",
                "The retained source permits a remote input with no configured connection and preserves its blank reference.");
        }

        ExportAcceptanceFixture(temporary.FullName, projectPath, boundaryHdfPath,
            connectionA, connectionAPath, connectionB, connectionBPath,
            connectionA.Name, remote.ConnectionPath, connectionB.Name, "/weather/station-b.csv", functionalValues);

        byte[] originalHdf = File.ReadAllBytes(boundaryHdfPath);
        byte[] originalProject = File.ReadAllBytes(projectPath);
        ModelSnapshot current = await ModelEditorAdapter.LoadAsync(new(boundaryHdfPath, "Boundary Conditions", projectPath));
        BoundaryEditorData currentBoundary = current.Boundary ?? throw new InvalidOperationException("The source model did not expose its boundary editor.");
        string remoteScope = currentBoundary.Spatial!["precipitation"].Inputs.Single(input =>
            current.Fields[input.Scope + "/ConnectionName"] == connectionA.Name
            && current.Fields[input.Scope + "/ConnectionPath"] == "/weather/station-a.csv").Scope;
        string unconfiguredScope = currentBoundary.Spatial["precipitation"].Inputs.Single(input =>
            current.Fields[input.Scope + "/DataLocation"] == nameof(DataLocation.Remote)
            && current.Fields[input.Scope + "/ConnectionName"] == "").Scope;
        string functionalScope = currentBoundary.Spatial["airDensity"].Inputs.Single().Scope;
        string functionalPage = functionalScope + "/Time Series";
        Check(current.Fields[remoteScope + "/ConnectionName"] == connectionA.Name
            && current.Fields[remoteScope + "/ConnectionPath"] == "/weather/station-a.csv",
            "Source editor fields expose the actual remote connection reference.");
        Check(current.Fields[unconfiguredScope + "/DataLocation"] == nameof(DataLocation.Remote)
            && current.Fields[unconfiguredScope + "/ConnectionName"] == ""
            && current.Fields[unconfiguredScope + "/ConnectionPath"] == "",
            "An unconfigured remote input remains a valid retained source record with empty connection fields.");
        Check(current.Fields[functionalScope + "/IsEnabled"] == "false"
            && current.Fields[functionalScope + "/LocalDataType"] == nameof(LocalDataType.Functional)
            && currentBoundary.Series[functionalPage].Rows.Select(row => double.Parse(row.Values["Value"], System.Globalization.CultureInfo.InvariantCulture)).SequenceEqual(functionalValues)
            && currentBoundary.Series[functionalPage].Operations.Length == 0,
            "Functional source data is visible as retained read-only data, with its disabled status and no unsupported edit operations.");

        Dictionary<string, string> fields = new(StringComparer.Ordinal)
        {
            [remoteScope + "/ConnectionName"] = connectionB.Name,
            [remoteScope + "/ConnectionPath"] = "/weather/station-b.csv"
        };
        ModelSaveRequest Draft(ModelSnapshot snapshot) => new(boundaryHdfPath, "Boundary Conditions", projectPath,
            snapshot.Revision, fields, [], SourceState: snapshot.SourceState,
            Rows: snapshot.Boundary!.Series.Values.Where(series => series.TableId != null)
                .ToDictionary(series => series.TableId!, series => series.Rows));

        current = await ModelEditorAdapter.TransformSpatialAsync(new(Draft(current), "precipitation", "refresh", null));
        Check(current.Fields[remoteScope + "/ConnectionName"] == connectionB.Name
            && current.Fields[remoteScope + "/ConnectionPath"] == "/weather/station-b.csv",
            "A source refresh retains changed remote connection fields in the unsaved parent draft.");
        Check(File.ReadAllBytes(boundaryHdfPath).SequenceEqual(originalHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(originalProject),
            "Remote connection refresh does not write the source HDF or project.");

        ModelSnapshot saved = await ModelEditorAdapter.SaveAsync(Draft(current));
        ModelSnapshot reopened = await ModelEditorAdapter.LoadAsync(new(boundaryHdfPath, "Boundary Conditions", projectPath, SourceState: saved.SourceState));
        BoundaryEditorData reopenedBoundary = reopened.Boundary ?? throw new InvalidOperationException("The reopened source did not expose its boundary editor.");
        Check(reopened.Fields[remoteScope + "/ConnectionName"] == connectionB.Name
            && reopened.Fields[remoteScope + "/ConnectionPath"] == "/weather/station-b.csv",
            "Parent save and independent source load preserve the selected remote connection and path.");
        Check(reopened.Fields[unconfiguredScope + "/ConnectionName"] == ""
            && reopened.Fields[unconfiguredScope + "/ConnectionPath"] == "",
            "Saving another remote input preserves an unconfigured remote reference without blocking the parent save.");
        Check(reopened.Fields[functionalScope + "/IsEnabled"] == "false"
            && reopened.Fields[functionalScope + "/LocalDataType"] == nameof(LocalDataType.Functional)
            && reopenedBoundary.Series[functionalPage].Rows.Select(row => double.Parse(row.Values["Value"], System.Globalization.CultureInfo.InvariantCulture)).SequenceEqual(functionalValues),
            "Changing remote configuration does not change or drop disabled Functional metadata or retained data.");
        using (var independentRead = new BoundaryCondition(boundaryHdfPath, project))
        {
            MetGaugedData actualRemote = independentRead.Precipitation.Gauges.Single(gauge => gauge.ConnectionName == connectionB.Name);
            MetGaugedData actualFunctional = independentRead.AirDensity.Gauges.Single();
            Check(actualRemote.ConnectionName == connectionB.Name && actualRemote.ConnectionPath == "/weather/station-b.csv",
                "Independent HDF source reads verify the committed remote configuration.");
            MetGaugedData actualUnconfigured = independentRead.Precipitation.Gauges.Single(gauge => gauge.ConnectionName == "");
            Check(actualUnconfigured.DataLocation == DataLocation.Remote && actualUnconfigured.ConnectionPath == "",
                "Independent HDF source reads verify the blank remote reference survived an unrelated edit.");
            Check(!actualFunctional.IsEnabled && actualFunctional.LocalDataType == LocalDataType.Functional
                && actualFunctional.Table.SequenceEqual(functionalValues),
                "Independent HDF source reads verify unchanged disabled Functional source data.");
        }

        byte[] savedHdf = File.ReadAllBytes(boundaryHdfPath), savedProject = File.ReadAllBytes(projectPath);
        fields[remoteScope + "/ConnectionName"] = "不存在的连接";
        await Reject<ValidationException>(() => ModelEditorAdapter.SaveAsync(Draft(reopened)));
        Check(File.ReadAllBytes(boundaryHdfPath).SequenceEqual(savedHdf)
            && File.ReadAllBytes(projectPath).SequenceEqual(savedProject),
            "A missing external connection is rejected before the staged HDF replaces source files.");
        Console.WriteLine("Remote point connection draft, parent save/reopen, missing-reference rejection and disabled Functional source-data retention passed.");
    }

    private static void ExportAcceptanceFixture(string sourceDirectory, string projectPath, string boundaryHdfPath,
        FileExternalConnection connectionA, string connectionAFile, FileExternalConnection connectionB, string connectionBFile,
        string initialConnectionName, string initialConnectionPath, string targetConnectionName, string targetConnectionPath,
        double[] functionalValues)
    {
        string? configuredPath = Environment.GetEnvironmentVariable("HECRAS_SPATIAL_POINT_CONFIG_ACCEPTANCE_DIRECTORY");
        if (string.IsNullOrWhiteSpace(configuredPath)) return;
        string destination = Path.GetFullPath(configuredPath);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("The spatial point configuration acceptance destination already exists.");
        string staging = destination + ".pending-" + Guid.NewGuid().ToString("N");
        try
        {
            string[] sourceFiles = Directory.GetFiles(sourceDirectory, "*", SearchOption.AllDirectories);
            foreach (string source in sourceFiles)
            {
                string target = Path.Combine(staging, Path.GetRelativePath(sourceDirectory, source));
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(source, target, overwrite: false);
            }
            string Relative(string path) => Path.GetRelativePath(sourceDirectory, path).Replace(Path.DirectorySeparatorChar, '/');
            Dictionary<string, string> hashes = sourceFiles.ToDictionary(Relative,
                path => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))), StringComparer.Ordinal);
            var manifest = new FixtureManifest("spatial-point-config-acceptance-v1", true,
                Relative(projectPath), Relative(boundaryHdfPath),
                [new(connectionA.Name, Relative(connectionAFile)), new(connectionB.Name, Relative(connectionBFile))],
                new("precipitation", initialConnectionName, initialConnectionPath, targetConnectionName, targetConnectionPath),
                new UnconfiguredRemoteInput("precipitation", "", ""),
                new("airDensity", false, nameof(LocalDataType.Functional), functionalValues), hashes);
            File.WriteAllText(Path.Combine(staging, "manifest.json"),
                JsonSerializer.Serialize(manifest, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
            Directory.Move(staging, destination);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private static async Task Reject<T>(Func<Task<ModelSnapshot>> action) where T : Exception
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
