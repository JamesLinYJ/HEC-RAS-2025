using System.ComponentModel.DataAnnotations;
using Ras.Backend;

internal static class FeatureQueryChecks
{
    internal static async Task Run()
    {
        var map = new MapTreeRequest("feature-query-validation.ras", null, null,
            "map-id", 0, "Project Map", "Project", null);
        var validExtent = new FeatureQueryExtent(0, 0, 10, 10);

        await Expect<ArgumentException>(() => FeatureQueryService.QueryAsync(new(
            map, "Unknown", validExtent, null, false, null, null, null)));
        await Expect<ValidationException>(() => FeatureQueryService.QueryAsync(new(
            map, "NFHL", new FeatureQueryExtent(10, 0, 10, 0), null, false, null, null, null)));
        await Expect<ArgumentException>(() => FeatureQueryService.QueryAsync(new(
            map, "NLD", validExtent, "UnsupportedLayer", false, null, null, null)));
        await Expect<ValidationException>(() => FeatureQueryService.QueryAsync(new(
            map, "NFHL", validExtent, null, true, "polygon-id", null, null)));
        await Expect<ArgumentException>(() => FeatureQueryService.SaveAsync(new(
            map, "../outside", "Shapefile", Path.GetTempPath())));
        await Expect<ArgumentException>(() => FeatureQueryService.SaveAsync(new(
            map, Guid.NewGuid().ToString("N"), "UnsupportedFormat", Path.GetTempPath())));

        Console.WriteLine("Feature-query source kind, extent, NLD layer, boundary use, result identity, and export format guards passed.");
    }

    private static async Task Expect<TException>(Func<Task> action) where TException : Exception
    {
        try { await action().ConfigureAwait(false); }
        catch (TException) { return; }
        throw new InvalidOperationException($"Expected {typeof(TException).Name} from feature-query validation.");
    }
}
