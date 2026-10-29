using System.IO.Pipes;
using System.Net.Sockets;
using Geospatial.Vectors;
using Ras.Backend;
using Utility.Systems;

internal static class StreamModeTinRenderingChecks
{
    internal static async Task RunAsync()
    {
        Guid sessionID = Guid.NewGuid();
        Guid unrelatedSessionID = Guid.NewGuid();
        byte[][] tinRecords =
        [
            await EncodeAsync(CreateTin(0)),
            await EncodeAsync(CreateTin(20)),
            await EncodeAsync(CreateTin(40))
        ];
        byte[] polylineRecord = await EncodeAsync(new Polyline(new[] {
            new Point(-10, -10), new Point(-5, -5) }));
        using var sourceRecords = new MemoryStream();
        sourceRecords.Write(polylineRecord);
        sourceRecords.Write(tinRecords[0]);
        sourceRecords.Write(polylineRecord);
        sourceRecords.Write(tinRecords[1]);
        sourceRecords.Write(tinRecords[2]);

        using var server = TestStreamServer.Create();
        Task writer = WriteAndCloseAsync(server, sourceRecords.ToArray());
        var frames = new List<StreamModeMapFrame>();
        try
        {
            StreamModeTinAssetReference unrelatedAsset = StreamModeTinAssetStore.Store(
                unrelatedSessionID, 0, tinRecords[0]);
            StreamModeConnectResult connectResult = await MapStreamModeService.RunAsync(
                new StreamModeConnectRequest(server.Endpoint, sessionID), frames.Add, controls: null)
                .WaitAsync(TimeSpan.FromSeconds(10));
            await writer.WaitAsync(TimeSpan.FromSeconds(10));

            StreamModeMapFrame[] tinFrames = frames.Where(frame => frame.ObjectType == nameof(Tin)).ToArray();
            StreamModeTinAssetReference[] assets = tinFrames.Select(frame => frame.TinAsset
                ?? throw new InvalidOperationException("A streamed Tin must carry its exact replayable owner reference."))
                .ToArray();
            Check(connectResult.ObjectsReceived == 5 && tinFrames.Length == 3 &&
                assets.Select(asset => asset.Sequence).SequenceEqual([1L, 3L, 4L]) &&
                assets.All(asset => asset.SessionID == sessionID) &&
                tinFrames.Select(frame => frame.Sequence).SequenceEqual(assets.Select(asset => asset.Sequence)),
                "Mixed stream records retain every true Tin profile in source order with the owning session and sequence.");

            for (int index = 0; index < assets.Length; index++)
            {
                byte[] replayed = await StreamModeTinAssetStore.ReadAsync(assets[index], CancellationToken.None);
                Check(replayed.SequenceEqual(tinRecords[index]),
                    "A TIN asset replays the exact original source record and passes its SHA-256 identity check.");
            }

            StreamModeTinOptionsResult options = await StreamModeTinRenderingService.LoadOptionsAsync(
                new StreamModeTinOptionsRequest(assets, SelectedProfileIndex: 1));
            Check(options.Assets.SequenceEqual(assets) && options.SelectedProfileIndex == 1,
                "The options payload preserves the complete BandedTin profile group and selected source profile.");
            StreamModeTinOptionDescriptor[] descriptors = options.Options;
            Check(Option(descriptors, "RenderEdges") is { CurrentValue: "true", DefaultValue: "true", IsEnabled: true } &&
                Option(descriptors, "RenderPoints") is { CurrentValue: "true", DefaultValue: "true", IsEnabled: true } &&
                Option(descriptors, "LabelTriangles") is { CurrentValue: "false", DefaultValue: "false", IsEnabled: true },
                "TIN option values and defaults come from the retained BandedTinRenderLayer.");
            Check(Option(descriptors, "PaintZ") is { IsEnabled: false, SourceEffect: "storedWithoutSurfacePaint" } &&
                Option(descriptors, "PaintM") is { IsEnabled: false, SourceEffect: "storedWithoutSurfacePaint" } &&
                Option(descriptors, "LabelEdges") is { IsEnabled: false, SourceEffect: "sourceReportsNotImplemented" } &&
                Option(descriptors, "LabelPoints") is { IsEnabled: false, SourceEffect: "sourceReportsNotImplemented" },
                "The UI contract exposes source no-op paint and label options as disabled with accurate source behavior.");

            Guid requestID = Guid.NewGuid();
            var viewport = new StreamModeTinViewport(-5, -5, 55, 15, 160, 80);
            StreamModeTinOptionAssignment[] assignments =
            [
                new("RenderEdges", "false"),
                new("RenderPoints", "false"),
                new("LabelTriangles", "true")
            ];
            StreamModeTinRenderResult rendered = await StreamModeTinRenderingService.RenderAsync(
                new StreamModeTinRenderRequest(assets, 1, requestID, viewport, assignments));
            Check(rendered.Assets.SequenceEqual(assets) && rendered.SelectedProfileIndex == 1 &&
                rendered.RequestID == requestID && rendered.Width > 0 && rendered.Height > 0 &&
                Convert.FromBase64String(rendered.RgbaBase64).Length == rendered.Width * rendered.Height * 4,
                "TIN rendering returns the retained source raster as viewport-sized RGBA, correlated to the owner group and request.");
            Check(rendered.Labels.Length == 1 && rendered.Labels[0].Text == "T[0]" &&
                rendered.Labels[0].X > 20 && rendered.Labels[0].X < 30,
                "The retained BandedTin renderer labels the selected profile's real triangle at its source centroid.");

            StreamModeTinRenderResult translucentPoints = await StreamModeTinRenderingService.RenderAsync(
                new StreamModeTinRenderRequest(assets, 1, Guid.NewGuid(), viewport,
                [new StreamModeTinOptionAssignment("RenderEdges", "false"),
                 new StreamModeTinOptionAssignment("RenderPoints", "true")]));
            byte[] pointPixels = Convert.FromBase64String(translucentPoints.RgbaBase64);
            bool hasStraightAlphaPointFill = Enumerable.Range(0, pointPixels.Length / 4).Any(index =>
            {
                int offset = index * 4;
                byte alpha = pointPixels[offset + 3];
                return alpha is > 0 and < 255 && pointPixels[offset] == 0 &&
                    pointPixels[offset + 1] == 0 && pointPixels[offset + 2] > alpha;
            });
            Check(hasStraightAlphaPointFill,
                "An actual source default TIN point fill retains translucent blue RGB above alpha in the straight-alpha RGBA wire format.");

            await ExpectAsync<ArgumentException>(() => StreamModeTinRenderingService.RenderAsync(
                new StreamModeTinRenderRequest(assets, 1, Guid.NewGuid(), viewport,
                [new StreamModeTinOptionAssignment("PaintZ", "true")])));
            await ExpectAsync<ArgumentException>(() => StreamModeTinRenderingService.RenderAsync(
                new StreamModeTinRenderRequest(assets, 1, Guid.NewGuid(), viewport,
                [new StreamModeTinOptionAssignment("LabelEdges", "true")])));
            await ExpectAsync<ArgumentException>(() => StreamModeTinRenderingService.RenderAsync(
                new StreamModeTinRenderRequest(assets, 1, Guid.NewGuid(), viewport,
                [new StreamModeTinOptionAssignment("LabelPoints", "true")])));
            await ExpectAsync<ArgumentException>(() => StreamModeTinRenderingService.LoadOptionsAsync(
                new StreamModeTinOptionsRequest(assets, SelectedProfileIndex: assets.Length)));
            await ExpectAsync<InvalidDataException>(() => StreamModeTinRenderingService.LoadOptionsAsync(
                new StreamModeTinOptionsRequest([assets[0] with { Sha256 = new string('0', 64) }],
                    SelectedProfileIndex: 0)));

            StreamModeTinSessionReleaseResult releasedSession =
                StreamModeTinRenderingService.ReleaseSession(new StreamModeTinSessionReleaseRequest(sessionID));
            Check(releasedSession.Released, "Whole-session cleanup removes all stored TIN records for its owner.");
            Check(!StreamModeTinAssetStore.Release(assets[0]),
                "The session release removed its exact source asset records.");
            Check((await StreamModeTinAssetStore.ReadAsync(unrelatedAsset, CancellationToken.None))
                .SequenceEqual(tinRecords[0]),
                "Whole-session cleanup preserves source records belonging to a different session.");
            Check(StreamModeTinRenderingService.ReleaseSession(
                new StreamModeTinSessionReleaseRequest(sessionID)).Released,
                "Whole-session cleanup is idempotent after the owner directory has already been removed.");
        }
        finally
        {
            _ = StreamModeTinRenderingService.ReleaseSession(new StreamModeTinSessionReleaseRequest(sessionID));
            _ = StreamModeTinRenderingService.ReleaseSession(new StreamModeTinSessionReleaseRequest(unrelatedSessionID));
        }

        Console.WriteLine("Streamed source TIN owner, option and BandedTin renderer checks passed.");
    }

    private static StreamModeTinOptionDescriptor Option(
        IEnumerable<StreamModeTinOptionDescriptor> options, string name) =>
        options.Single(option => option.Name == name);

    private static Tin CreateTin(double offset)
    {
        var tin = new Tin(new List<Point>
        {
            new(offset, 0), new(offset + 10, 0), new(offset, 10)
        }, new[,] { { 0, 1, 2 } });
        tin.TrackZ([100 + offset, 101 + offset, 102 + offset]);
        tin.TrackM([-2 + offset, offset, 2 + offset]);
        return tin;
    }

    private static async Task<byte[]> EncodeAsync(IStreamableObject source)
    {
        using var output = new MemoryStream();
        await StreamableObjectHelper.WriteAsync(output, source);
        return output.ToArray();
    }

    private static async Task WriteAndCloseAsync(TestStreamServer server, byte[] bytes)
    {
        await using Stream peer = await server.AcceptAsync().WaitAsync(TimeSpan.FromSeconds(10));
        await peer.WriteAsync(bytes);
        await peer.FlushAsync();
    }

    private static async Task ExpectAsync<TException>(Func<Task> operation)
        where TException : Exception
    {
        try
        {
            await operation();
        }
        catch (TException)
        {
            return;
        }
        throw new InvalidOperationException("Expected " + typeof(TException).Name + ".");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class TestStreamServer : IDisposable
    {
        private readonly NamedPipeServerStream? namedPipe;
        private readonly Socket? unixListener;
        private readonly string? unixSocketPath;

        private TestStreamServer(string endpoint, NamedPipeServerStream namedPipe)
        {
            Endpoint = endpoint;
            this.namedPipe = namedPipe;
        }

        private TestStreamServer(string endpoint, Socket unixListener)
        {
            Endpoint = endpoint;
            this.unixListener = unixListener;
            unixSocketPath = endpoint;
        }

        public string Endpoint { get; }

        public static TestStreamServer Create()
        {
            if (OperatingSystem.IsWindows())
            {
                string pipeName = "hecras-tin-stream-" + Guid.NewGuid().ToString("N");
                var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                return new TestStreamServer(pipeName, pipe);
            }

            string path = "/tmp/hecras-tin-" + Guid.NewGuid().ToString("N") + ".sock";
            var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try
            {
                listener.Bind(new UnixDomainSocketEndPoint(path));
                listener.Listen(1);
                return new TestStreamServer(path, listener);
            }
            catch
            {
                listener.Dispose();
                throw;
            }
        }

        public async Task<Stream> AcceptAsync()
        {
            if (namedPipe is not null)
            {
                await namedPipe.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(10));
                return namedPipe;
            }

            Socket accepted = await unixListener!.AcceptAsync().WaitAsync(TimeSpan.FromSeconds(10));
            return new NetworkStream(accepted, ownsSocket: true);
        }

        public void Dispose()
        {
            namedPipe?.Dispose();
            unixListener?.Dispose();
            if (unixSocketPath is not null)
            {
                try { File.Delete(unixSocketPath); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
