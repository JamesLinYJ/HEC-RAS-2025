using System.Globalization;
using Ras.Backend;

internal static class TemporalInputChecks
{
    internal static void Run()
    {
        CheckCultureSpecificDateParsing();
        CheckTimeSpanComponentsAndTicks();
        CheckTryParseFailureDefaults();
        CheckSourceDateTimeConstructorBounds();
        CheckUnsupportedCultureIsNotSilentlyReplaced();
        Console.WriteLine("Temporal input parsing uses the retained .NET TryParse culture, defaults, ticks, and source component conversion.");
    }

    private static void CheckCultureSpecificDateParsing()
    {
        const string text = "03/04/2024";
        TemporalInputParseResult us = TemporalInputService.Parse(new("date", text, "en-US"));
        TemporalInputParseResult german = TemporalInputService.Parse(new("date", text, "de-DE"));
        Check(us.IsValid && us.CanonicalDate == "2024-03-04",
            "DateTime.TryParse interprets an ambiguous date with en-US ordering.");
        Check(german.IsValid && german.CanonicalDate == "2024-04-03",
            "DateTime.TryParse interprets the same ambiguous date with de-DE ordering.");
        Check(us.CanonicalDate == DateTime.Parse(text, CultureInfo.GetCultureInfo("en-US"), DateTimeStyles.None)
                .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
            && german.CanonicalDate == DateTime.Parse(text, CultureInfo.GetCultureInfo("de-DE"), DateTimeStyles.None)
                .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            "The service reports the actual DateTime.TryParse calendar parts.");
    }

    private static void CheckTimeSpanComponentsAndTicks()
    {
        var culture = CultureInfo.GetCultureInfo("de-DE");
        TimeSpan expected = new TimeSpan(1, 2, 3, 4).Add(TimeSpan.FromTicks(1_234_567));
        string text = expected.ToString("g", culture);
        TemporalInputParseResult parsed = TemporalInputService.Parse(new("time", text, "de-DE"));
        Check(parsed.IsValid && parsed.TimeSpanTicks == expected.Ticks,
            "TimeSpan.TryParse retains all seven fractional tick digits under the requested culture.");
        Check(parsed.TimeSpanDays == expected.Days && parsed.TimeSpanHours == expected.Hours
            && parsed.TimeSpanMinutes == expected.Minutes && parsed.TimeSpanSeconds == expected.Seconds,
            "The response exposes the exact TimeSpan component values consumed by TimeSpanToDateTime.");
        Check(parsed.CanonicalTime == "02:03:04" && parsed.CanSetDateTime,
            "The source converter drops duration days and fractional seconds while retaining the Hours component.");

        TemporalInputParseResult oneDay = TemporalInputService.Parse(new("time", "1.00:00:00", "en-US"));
        Check(oneDay.IsValid && oneDay.TimeSpanDays == 1 && oneDay.CanonicalTime == "00:00:00",
            "A one-day TimeSpan maps to the source converter's zero Hours component.");
    }

    private static void CheckTryParseFailureDefaults()
    {
        TemporalInputParseResult date = TemporalInputService.Parse(new("date", "not a date", "en-US"));
        TemporalInputParseResult time = TemporalInputService.Parse(new("time", "not a time", "en-US"));
        Check(!date.IsValid && date.CanonicalDate == "0001-01-01",
            "Failed DateTime.TryParse returns its DateTime.MinValue out value.");
        Check(!time.IsValid && time.TimeSpanTicks == TimeSpan.Zero.Ticks
            && time.TimeSpanDays == 0 && time.CanonicalTime == "00:00:00",
            "Failed TimeSpan.TryParse returns its zero TimeSpan out value.");
    }

    private static void CheckSourceDateTimeConstructorBounds()
    {
        TemporalInputParseResult negative = TemporalInputService.Parse(new("time", "-01:00", "en-US"));
        Check(negative.IsValid && !negative.CanSetDateTime && negative.CanonicalTime is null,
            "A valid negative TimeSpan is distinguished from a valid source DateTime conversion; the source constructor cannot accept its negative components.");
    }

    private static void CheckUnsupportedCultureIsNotSilentlyReplaced()
    {
        try
        {
            _ = TemporalInputService.Parse(new("date", "03/04/2024", "not a culture!"));
        }
        catch (ArgumentException)
        {
            return;
        }
        throw new InvalidOperationException("An unsupported culture must not silently fall back to a different date grammar.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
