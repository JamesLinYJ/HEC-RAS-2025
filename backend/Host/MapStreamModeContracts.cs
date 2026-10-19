namespace Ras.Backend;

/// <summary>Connects to the source application's -stream=&lt;pipe&gt; endpoint.</summary>
public sealed record StreamModeConnectRequest(string PipeName);

public sealed record StreamModeCoordinate(double X, double Y, double? Z = null, double? M = null);

/// <summary>
/// One actual retained IStreamableObject converted to native map primitives.
/// Coordinate indices, paths, and triangles preserve source geometry order.
/// </summary>
public sealed record StreamModeMapFrame(
    long Sequence,
    string ObjectType,
    int CoordinateCount,
    StreamModeCoordinate[] Coordinates,
    int[][] Paths,
    int[][] Triangles,
    bool IsClosed,
    bool HasZ = false,
    bool HasM = false,
    double? ZFillValue = null,
    double? MFillValue = null);

public sealed record StreamModeConnectResult(string PipeName, long ObjectsReceived);
