using System.IO.Pipes;
using System.Net.Sockets;
using System.Text;
using Geospatial.Vectors;
using Ras.Backend;
using Utility.Systems;

internal static class StreamModeChecks
{
    internal static async Task RunAsync()
    {
        byte[] wireRecord = await EncodeAsync(new Polyline(new[] {
            new Point(10.25, 20.5), new Point(30.75, 40.125) }));
        using (var fragmented = new OneByteReadStream(wireRecord))
        {
            var decoded = await StreamableObjectHelper.ReadAsync(fragmented) as Polyline;
            Check(decoded is { Count: 2 } && decoded[0].X == 10.25 && decoded[1].Y == 40.125,
                "Fragmented source binary header, payload and coordinates are decoded exactly.");
            Check(await StreamableObjectHelper.ReadAsync(fragmented) is null,
                "Clean EOF between source objects ends the stream normally.");
        }

        await ExpectAsync<EndOfStreamException>(async () =>
        {
            using var partialHeader = new OneByteReadStream([1, 2]);
            await StreamableObjectHelper.ReadAsync(partialHeader);
        });

        await ExpectAsync<EndOfStreamException>(async () =>
        {
            using var truncatedPayload = new MemoryStream();
            using (var writer = new BinaryWriter(truncatedPayload, Encoding.ASCII, leaveOpen: true))
            {
                WriteTypeName(writer, typeof(Polyline));
                writer.Write(3);
                writer.Write((byte)0x41);
            }
            truncatedPayload.Position = 0;
            await StreamableObjectHelper.ReadAsync(truncatedPayload);
        });

        await ExpectAsync<InvalidDataException>(async () =>
        {
            using var oversizedPacket = new MemoryStream();
            using (var writer = new BinaryWriter(oversizedPacket, Encoding.ASCII, leaveOpen: true))
            {
                WriteTypeName(writer, typeof(Polyline));
                writer.Write(StreamableObjectHelper.MaximumObjectPacketLength + 1);
            }
            oversizedPacket.Position = 0;
            var allowed = SupportedTypes(typeof(Polyline));
            await StreamableObjectHelper.ReadAsync(oversizedPacket, allowed);
        });

        await ExpectAsync<NotSupportedException>(async () =>
        {
            using var disallowed = new MemoryStream(wireRecord, writable: false);
            await StreamableObjectHelper.ReadAsync(disallowed,
                new Dictionary<string, Type>(StringComparer.Ordinal));
        });

        await ReadFragmentedEndpointAsync(wireRecord);
        await ReadTinEndpointAsync();
        await CancelEndpointReadAsync();
        await RejectOverlongUnixSocketPathAsync();
        Console.WriteLine("Retained map stream protocol regressions passed.");
    }

    private static async Task ReadFragmentedEndpointAsync(byte[] wireRecord)
    {
        using var server = TestStreamServer.Create();
        Task writer = WriteFragmentedAndCloseAsync(server, wireRecord);

        var frames = new List<StreamModeMapFrame>();
        Guid sessionID = Guid.NewGuid();
        StreamModeConnectResult result = await MapStreamModeService.RunAsync(
            new StreamModeConnectRequest(server.Endpoint, sessionID), frames.Add, controls: null)
            .WaitAsync(TimeSpan.FromSeconds(10));
        await writer.WaitAsync(TimeSpan.FromSeconds(10));
        Check(result.ObjectsReceived == 1 && frames.Count == 1 &&
            frames[0].ObjectType == nameof(Polyline) && frames[0].CoordinateCount == 2 &&
            frames[0].Coordinates[0] == new StreamModeCoordinate(10.25, 20.5) &&
            frames[0].Paths[0].SequenceEqual([0, 1]),
            "The stream service accepts a fragmented retained Polyline over the platform endpoint and preserves its source coordinates.");
    }

    private static async Task ReadTinEndpointAsync()
    {
        var tin = new Tin(new List<Point> {
            new(0, 0), new(10, 0), new(0, 10)
        }, new[,] { { 0, 1, 2 } });
        tin.TrackZ([100.25, 101.5, 102.75]);
        tin.TrackM([-2.0, 0.0, 2.0]);
        byte[] wireRecord = await EncodeAsync(tin);
        using var server = TestStreamServer.Create();
        Task writer = WriteFragmentedAndCloseAsync(server, wireRecord);

        var frames = new List<StreamModeMapFrame>();
        StreamModeTinAssetReference? asset = null;
        Guid sessionID = Guid.NewGuid();
        try
        {
            StreamModeConnectResult result = await MapStreamModeService.RunAsync(
                new StreamModeConnectRequest(server.Endpoint, sessionID), frame =>
                {
                    frames.Add(frame);
                    asset = frame.TinAsset;
                }, controls: null)
                .WaitAsync(TimeSpan.FromSeconds(10));
            await writer.WaitAsync(TimeSpan.FromSeconds(10));
            Check(result.ObjectsReceived == 1 && frames.Count == 1 &&
                frames[0].ObjectType == nameof(Tin) && frames[0].Triangles.Length == 1 &&
                frames[0].Triangles[0].SequenceEqual([0, 1, 2]) &&
                frames[0].HasZ && frames[0].HasM &&
                frames[0].Coordinates[0].Z == 100.25 && frames[0].Coordinates[2].M == 2.0 &&
                asset is { SessionID: var owner } && owner == sessionID && asset.Sequence == 0,
                "The streamed BandedTin profile preserves source connectivity, per-point Z/M samples and its owner identity.");
        }
        finally
        {
            if (asset is not null)
                _ = StreamModeTinRenderingService.Release(new StreamModeTinAssetRequest(asset));
        }
    }

    private static async Task CancelEndpointReadAsync()
    {
        using var server = TestStreamServer.Create();
        Task<Stream> connected = server.AcceptAsync();
        using var cancellation = new CancellationTokenSource();
        Task<StreamModeConnectResult> reading = MapStreamModeService.RunAsync(
            new StreamModeConnectRequest(server.Endpoint, Guid.NewGuid()), onFrame: null, controls: null,
            cancellationToken: cancellation.Token);
        using Stream accepted = await connected.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();
        await ExpectAsync<OperationCanceledException>(() => reading.WaitAsync(TimeSpan.FromSeconds(10)));
    }

    private static async Task RejectOverlongUnixSocketPathAsync()
    {
        if (OperatingSystem.IsWindows()) return;

        string path = "/tmp/" + new string('x', 512);
        bool runtimeRejectedPath = false;
        try { _ = new UnixDomainSocketEndPoint(path); }
        catch (ArgumentOutOfRangeException) { runtimeRejectedPath = true; }
        Check(runtimeRejectedPath, "The platform Unix endpoint constructor rejects an overlong socket path.");

        try
        {
            await MapStreamModeService.RunAsync(new StreamModeConnectRequest(path, Guid.NewGuid()), onFrame: null, controls: null);
        }
        catch (ArgumentException error) when (error.Message.Contains("endpoint length", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        throw new InvalidOperationException("The stream-mode service must explain when a Unix socket path exceeds the platform endpoint length.");
    }

    private static async Task WriteFragmentedAndCloseAsync(TestStreamServer server, byte[] bytes)
    {
        await using Stream peer = await server.AcceptAsync().WaitAsync(TimeSpan.FromSeconds(10));
        foreach (byte value in bytes)
        {
            await peer.WriteAsync(new[] { value });
            await peer.FlushAsync();
        }
    }

    private static async Task<byte[]> EncodeAsync(IStreamableObject source)
    {
        using var output = new MemoryStream();
        await StreamableObjectHelper.WriteAsync(output, source);
        return output.ToArray();
    }

    private static void WriteTypeName(BinaryWriter writer, Type type)
    {
        string name = type.AssemblyQualifiedName
            ?? throw new InvalidOperationException("The source type has no assembly-qualified name.");
        writer.Write(name.Length);
        writer.Write(Encoding.ASCII.GetBytes(name));
    }

    private static IReadOnlyDictionary<string, Type> SupportedTypes(params Type[] types) =>
        types.ToDictionary(type => type.AssemblyQualifiedName
            ?? throw new InvalidOperationException("The source type has no assembly-qualified name."));

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
                string pipeName = "hecras-stream-" + Guid.NewGuid().ToString("N");
                var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                return new TestStreamServer(pipeName, pipe);
            }

            string path = "/tmp/hecras-sm-" + Guid.NewGuid().ToString("N")[..12] + ".sock";
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

    private sealed class OneByteReadStream(byte[] bytes) : MemoryStream(bytes, writable: false)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer,
            CancellationToken cancellationToken = default) =>
            base.ReadAsync(buffer[..Math.Min(buffer.Length, 1)], cancellationToken);
    }
}
