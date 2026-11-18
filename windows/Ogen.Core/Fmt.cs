using System;

namespace Ogen.Core;

/// <summary>Hebrew time formatting, same wording as the Android app.</summary>
public static class Fmt
{
    /// <summary>"1:05" (rounded up to the minute).</summary>
    public static string Hm(long ms)
    {
        if (ms < 0) ms = 0;
        long totalMin = (ms + 59_999) / 60_000;
        return $"{totalMin / 60}:{totalMin % 60:00}";
    }

    /// <summary>"שעה ו-20 דק׳", "45 דק׳", "3 שעות".</summary>
    public static string Words(long ms)
    {
        long m = Math.Max(0, (ms + 59_999) / 60_000);
        long h = m / 60, r = m % 60;
        string hs = h == 0 ? "" : h == 1 ? "שעה" : h == 2 ? "שעתיים" : h + " שעות";
        if (h == 0) return r + " דק׳";
        if (r == 0) return hs;
        return hs + " ו-" + r + " דק׳";
    }

    public static string Clock(long wallMs)
    {
        var t = DateTimeOffset.FromUnixTimeMilliseconds(wallMs).ToLocalTime();
        return $"{t.Hour:00}:{t.Minute:00}";
    }

    /// <summary>"היום ב-14:30", "מחר ב-09:00", "ב-21/11 ב-09:00".</summary>
    public static string When(long wallMs, long nowWallMs)
    {
        var t = DateTimeOffset.FromUnixTimeMilliseconds(wallMs).ToLocalTime();
        var n = DateTimeOffset.FromUnixTimeMilliseconds(nowWallMs).ToLocalTime();
        int days = (t.Date - n.Date).Days;
        string clock = Clock(wallMs);
        if (days <= 0) return "היום ב-" + clock;
        if (days == 1) return "מחר ב-" + clock;
        return $"ב-{t.Day}/{t.Month} ב-{clock}";
    }
}
