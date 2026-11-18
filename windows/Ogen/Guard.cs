using System;
using System.IO;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>
/// The enforcer. Watches which window is in front, counts screen time, and covers anything the
/// current commitment does not allow. Windows counterpart of the Android GuardService.
/// </summary>
internal sealed class Guard : IDisposable
{
    private const long IdleLimit = 5 * 60_000L;   // no input for 5 minutes: you're not using the PC
    private const long MIN = 60_000L;

    private readonly AppModel m;
    private readonly BlockForm cover;
    private readonly Timer timer = new() { Interval = 1000 };
    private readonly Native.WinEventProc hookProc;  // keep the delegate alive
    private readonly IntPtr hookFg, hookName;
    private readonly uint selfPid = (uint)Environment.ProcessId;

    private long lastTick = Environment.TickCount64;
    private long lastSave = Environment.TickCount64;
    private long lastEval;
    private bool usageDirty;
    private bool warned5, warned1;
    private IntPtr closedTab;
    private long closedAt;

    /// <summary>A heads-up for the tray ("5 minutes left").</summary>
    public event Action<string>? Warn;
    /// <summary>Raised every second, for the tray tooltip.</summary>
    public event Action? Ticked;

    public readonly record struct Fg(IntPtr Hwnd, uint Pid, string Proc, string Title);

    public Guard(AppModel model, BlockForm cover)
    {
        m = model;
        this.cover = cover;
        timer.Tick += (_, _) => Safe(Tick);
        hookProc = OnWinEvent;
        hookFg = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, hookProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        hookName = Native.SetWinEventHook(Native.EVENT_OBJECT_NAMECHANGE, Native.EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, hookProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        timer.Start();
        Log.Write($"guard on: hooks fg={hookFg != IntPtr.Zero} name={hookName != IntPtr.Zero} limit={m.P.LimitMs} used={m.P.UsedMs} social={m.P.SocialBlock}");
    }

    /// <summary>Never let one odd window kill enforcement.</summary>
    private static void Safe(Action a)
    {
        try { a(); }
        catch (Exception e) { Log.Write("guard error: " + e); }
    }

    private void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time)
    {
        // title changes (switching browser tabs) only matter for the window in front
        if (ev == Native.EVENT_OBJECT_NAMECHANGE && (obj != 0 || hwnd != Native.GetForegroundWindow())) return;
        long t = Environment.TickCount64;
        if (ev == Native.EVENT_OBJECT_NAMECHANGE && t - lastEval < 300) return;
        lastEval = t;
        Safe(() => Evaluate(Current(), m.Now()));
    }

    public static Fg Current()
    {
        IntPtr h = Native.GetForegroundWindow();
        if (h == IntPtr.Zero) return default;
        Native.GetWindowThreadProcessId(h, out uint pid);
        string proc = Rules.Normalize(Path.GetFileName(Native.ProcessPath(pid)));
        if (proc == "applicationframehost")
        {
            // a Store app: the real process is a child window's owner
            uint hosted = Native.HostedAppPid(h, pid);
            if (hosted != 0)
            {
                string real = Rules.Normalize(Path.GetFileName(Native.ProcessPath(hosted)));
                if (real.Length > 0) { proc = real; pid = hosted; }
            }
        }
        return new Fg(h, pid, proc, Native.WindowText(h));
    }

    private void Tick()
    {
        var p = m.P;
        long now = m.Now();
        bool changed = p.Tick(now);
        long t = Environment.TickCount64;
        long dt = Math.Clamp(t - lastTick, 0, 5000); // a long gap means sleep, not use
        lastTick = t;

        var fg = Current();
        if (p.LimitMs != Policy.None && !p.BudgetSpent() && fg.Hwnd != IntPtr.Zero && fg.Pid != selfPid
            && !Rules.Free(p, fg.Proc) && Native.IdleMs() < IdleLimit)
        {
            p.AddUsage(dt, now);
            usageDirty = true;
            if (p.BudgetSpent()) changed = true;
        }

        long rem = p.RemainingMs();
        if (rem == Policy.None || rem > 5 * MIN) { warned5 = warned1 = false; }
        else if (rem > 0)
        {
            if (!warned5 && rem <= 5 * MIN && rem > MIN) { warned5 = true; Warn?.Invoke("נשארו 5 דקות של זמן מסך להיום"); }
            if (!warned1 && rem <= MIN) { warned1 = warned5 = true; Warn?.Invoke("נשארה דקה אחת. שמור את מה שאתה עושה"); }
        }

        Evaluate(fg, now);

        if (changed || m.ClockDirty || (usageDirty && t - lastSave > 30_000))
        {
            m.Save();
            lastSave = t;
            usageDirty = false;
        }
        if (changed || usageDirty) m.RaiseChanged();
        Ticked?.Invoke();
    }

    /// <summary>Decide whether the window in front must be covered.</summary>
    private void Evaluate(Fg fg, long now)
    {
        if (fg.Hwnd == IntPtr.Zero || fg.Pid == selfPid || fg.Proc.Length == 0) return;
        var v = Rules.Classify(m.P, now, fg.Proc, fg.Title);
        if (fg.Hwnd != lastLogged || fg.Title != lastTitle)
        {
            lastLogged = fg.Hwnd;
            lastTitle = fg.Title;
            Log.Write($"front: {fg.Proc} \"{Short(fg.Title)}\" -> {v}");
        }
        if (v == Verdict.Ok) return;

        switch (v)
        {
            case Verdict.Tamper:
                Native.PostMessage(fg.Hwnd, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                Native.ShowWindowAsync(fg.Hwnd, Native.SW_MINIMIZE);
                break;
            case Verdict.SocialSite:
            {
                // close just that tab (Ctrl+W), once per window per moment
                long t = Environment.TickCount64;
                if ((fg.Hwnd != closedTab || t - closedAt > 1500) && Native.GetForegroundWindow() == fg.Hwnd)
                {
                    Native.SendCtrlW();
                    closedTab = fg.Hwnd;
                    closedAt = t;
                }
                break;
            }
            default: // Locked, SocialApp: nothing is closed, the window is put away
                Native.ShowWindowAsync(fg.Hwnd, Native.SW_MINIMIZE);
                break;
        }
        cover.ShowFor(v, Screen.FromHandle(fg.Hwnd));
    }

    private IntPtr lastLogged;
    private string lastTitle = "";
    private static string Short(string s) => s.Length > 80 ? s[..80] : s;

    public void Dispose()
    {
        timer.Dispose();
        if (hookFg != IntPtr.Zero) Native.UnhookWinEvent(hookFg);
        if (hookName != IntPtr.Zero) Native.UnhookWinEvent(hookName);
        if (usageDirty) m.Save();
    }
}
