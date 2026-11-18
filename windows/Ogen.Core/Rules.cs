using System;
using System.Collections.Generic;
using System.Linq;

namespace Ogen.Core;

public enum Verdict
{
    Ok,
    Tamper,     // a screen that could switch Ogen off (Task Manager, Task Scheduler...)
    Locked,     // daily time is up and this app is not "always open"
    SocialApp,  // a social / video app
    SocialSite, // a social / video site in a browser tab
}

/// <summary>Which processes / windows are allowed, blocked or protected. No Windows dependencies.</summary>
public static class Rules
{
    /// <summary>Always usable and never counted: the shell, system UI and Phone Link (calls &amp; messages).</summary>
    private static readonly HashSet<string> BaseFree = new(StringComparer.OrdinalIgnoreCase)
    {
        "ogen", "explorer", "systemsettings", "systemsettingsbroker", "applicationframehost",
        "shellexperiencehost", "startmenuexperiencehost", "shellhost", "searchhost", "searchapp", "searchui",
        "textinputhost", "lockapp", "logonui", "consent", "credentialuibroker", "pickerhost", "openwith",
        "ctfmon", "dwm", "sihost", "taskhostw", "securityhealthsystray", "securityhealthhost",
        "phoneexperiencehost", "yourphone", "crossdeviceresume",
    };

    private static readonly HashSet<string> SocialApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "tiktok", "instagram", "facebook", "netflix", "twitch", "snapchat", "reddit", "pinterest",
        "youtube", "disneyplus", "disney+", "primevideo", "amazonvideo", "linkedin", "x", "twitter",
        "bilibili", "tumblr", "9gag",
    };

    private static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "msedge", "firefox", "brave", "opera", "opera_gx", "launcher", "vivaldi", "iexplore", "arc",
        "librewolf", "waterfox", "floorp", "zen", "chromium", "thorium", "yandex", "browser", "duckduckgo",
        "palemoon", "basilisk", "seamonkey", "maxthon", "ucbrowser", "whale", "tor", "mullvadbrowser", "sidekick",
    };

    /// <summary>Page names that show up as their own segment of a tab title ("Video - YouTube").</summary>
    private static readonly string[] Sites =
    {
        "youtube", "youtube music", "instagram", "tiktok", "facebook", "netflix", "twitch", "reddit", "pinterest",
        "snapchat", "9gag", "tumblr", "bilibili", "douyin", "vimeo", "dailymotion", "linkedin", "twitter",
        "disney+", "prime video", "messenger",
    };

    /// <summary>Short names that are also everyday words: only an exact title segment counts.</summary>
    private static readonly string[] ExactSites = { "x", "threads", "kick" };

    /// <summary>Title segments that mean "this is a search results page", never a blocked site.</summary>
    private static readonly string[] SearchPages =
    {
        "google search", "חיפוש ב-google", "חיפוש google", "bing", "duckduckgo", "search", "חיפוש", "yahoo search",
    };

    private static readonly HashSet<string> TamperProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "taskmgr", "regedit", "msconfig", "resmon", "perfmon", "procexp", "procexp64", "procexp64a",
        "processhacker", "systeminformer", "autoruns", "autoruns64", "autorunsc", "procmon", "procmon64",
    };

    /// <summary>Management consoles (mmc.exe) that can switch the watchdog task off.</summary>
    private static readonly string[] TamperTitles =
    {
        "task scheduler", "מתזמן המשימות", "computer management", "ניהול המחשב",
    };

    public static string Normalize(string? processName)
    {
        if (string.IsNullOrWhiteSpace(processName)) return "";
        var n = processName.Trim();
        if (n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) n = n[..^4];
        return n.ToLowerInvariant();
    }

    /// <summary>Usable during a lockdown and never counted toward the daily time.</summary>
    public static bool Free(Policy p, string proc)
    {
        proc = Normalize(proc);
        return proc.Length == 0 || BaseFree.Contains(proc) || p.ExtraAllowed.Contains(proc);
    }

    public static bool IsBrowser(string proc) => Browsers.Contains(Normalize(proc));

    public static bool IsSocialApp(string proc, string? title)
    {
        proc = Normalize(proc);
        if (SocialApps.Contains(proc)) return true;
        // Store apps all run inside ApplicationFrameHost: their window title is the app's name
        if (proc == "applicationframehost" && title != null) return SocialApps.Contains(title.Trim());
        return false;
    }

    public static bool IsTamper(string proc, string? title)
    {
        proc = Normalize(proc);
        if (TamperProcesses.Contains(proc)) return true;
        if (proc == "mmc" && title != null)
        {
            var t = title.ToLowerInvariant();
            return TamperTitles.Any(t.Contains);
        }
        return false;
    }

    private static readonly string[] Separators = { " - ", " | ", " – ", " — ", " / ", " • ", " · ", ": ", " :: " };

    /// <summary>Does a browser window title belong to a blocked site?</summary>
    public static bool BlockedTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title)) return false;
        var segments = title.Split(Separators, StringSplitOptions.RemoveEmptyEntries)
            .Select(CleanSegment).Where(s => s.Length > 0).ToList();
        if (segments.Any(s => SearchPages.Contains(s))) return false;
        foreach (var s in segments)
        {
            if (s.StartsWith("r/", StringComparison.Ordinal) && s.Length > 2 && !s.Contains(' ')) return true; // reddit
            if (ExactSites.Contains(s)) return true;
            foreach (var site in Sites)
            {
                if (s == site) return true;
                // "YouTube and 3 more pages", "Instagram photos and videos", "TikTok, Make Your Day"
                if (s.StartsWith(site + " ", StringComparison.Ordinal) || s.StartsWith(site + ",", StringComparison.Ordinal))
                    return true;
            }
            if (s.EndsWith(" on x", StringComparison.Ordinal) || s.EndsWith(" on threads", StringComparison.Ordinal)
                || s.EndsWith(" on instagram", StringComparison.Ordinal) || s.EndsWith(" on tiktok", StringComparison.Ordinal))
                return true;
        }
        return false;
    }

    /// <summary>"(3) Facebook" → "facebook"; strips unread counters and zero-width marks.</summary>
    private static string CleanSegment(string s)
    {
        s = s.Replace("​", "").Replace("‎", "").Replace("‏", "").Trim().ToLowerInvariant();
        while (s.StartsWith('('))
        {
            int close = s.IndexOf(')');
            if (close < 0) break;
            s = s[(close + 1)..].TrimStart();
        }
        return s;
    }

    /// <summary>Decide whether the window in front must be blocked. Mirrors GuardService.evaluate on Android.</summary>
    public static Verdict Classify(Policy p, long now, string proc, string? title)
    {
        proc = Normalize(proc);
        if (proc == "ogen" || !p.Guarding(now)) return Verdict.Ok;

        // 1. Escape routes are closed while anything is guarded.
        if (IsTamper(proc, title)) return Verdict.Tamper;

        // 2. Time is up: only "always open" apps.
        if (p.Locked(now) && !Free(p, proc))
            return Verdict.Locked;

        // 3. Social / video stays off.
        if (p.SocialBlock && !p.ExtraAllowed.Contains(proc))
        {
            if (IsSocialApp(proc, title)) return Verdict.SocialApp;
            if (IsBrowser(proc) && BlockedTitle(title)) return Verdict.SocialSite;
        }
        return Verdict.Ok;
    }
}
