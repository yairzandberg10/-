using System;
using System.Collections.Concurrent;
using System.Threading.Tasks;
using Interop.UIAutomationClient;

namespace Ogen;

/// <summary>
/// Reads the address bar of a browser window through UI Automation, so a blocked site is caught
/// even when its tab title doesn't say what it is. Reads run off the UI thread and are cached per
/// window + title (the title changes whenever the page does).
/// </summary>
internal static class UrlReader
{
    private const int UIA_ControlTypePropertyId = 30003;
    private const int UIA_EditControlTypeId = 50004;
    private const int UIA_ValueValuePropertyId = 30045;

    private static readonly ConcurrentDictionary<(IntPtr, string), (string url, long at, int tries)> Cache = new();
    private static readonly ConcurrentDictionary<(IntPtr, string), bool> Busy = new();
    private static CUIAutomation? auto;
    private static bool broken;

    /// <summary>The URL if already known; otherwise starts reading it and calls <paramref name="done"/> later.</summary>
    public static string? Get(IntPtr hwnd, string title, Action done)
    {
        if (broken) return null;
        var key = (hwnd, title);
        long t = Environment.TickCount64;
        if (Cache.TryGetValue(key, out var c))
        {
            // Chrome builds its accessibility tree only once someone asks, so an empty first
            // answer is retried a few times before we give up on this page.
            if (c.url.Length > 0 || c.tries >= 6 || t - c.at < 700) return c.url.Length > 0 ? c.url : null;
        }
        int tries = c.tries;
        if (Busy.TryAdd(key, true))
        {
            Task.Run(() =>
            {
                string u = Read(hwnd);
                if (Cache.Count > 300) Cache.Clear();
                Cache[key] = (u, Environment.TickCount64, tries + 1);
                Busy.TryRemove(key, out _);
                if (u.Length > 0 || tries + 1 >= 6) Log.Write($"address bar: \"{(u.Length > 60 ? u[..60] : u)}\" after {tries + 1} tries");
                if (u.Length > 0) done();
            });
        }
        return null;
    }

    private static string Read(IntPtr hwnd)
    {
        try
        {
            auto ??= new CUIAutomation();
            var root = auto.ElementFromHandle(hwnd);
            if (root == null) return "";
            var cond = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, UIA_EditControlTypeId);
            // the address bar is the first edit field in the browser's own UI
            var edit = root.FindFirst(TreeScope.TreeScope_Descendants, cond);
            if (edit == null) return "";
            return edit.GetCurrentPropertyValue(UIA_ValueValuePropertyId) as string ?? "";
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidCastException or UnauthorizedAccessException)
        {
            return "";
        }
        catch (Exception e)
        {
            Log.Write("url reader disabled: " + e.GetType().Name + " " + e.Message);
            broken = true;
            return "";
        }
    }
}
