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
    private readonly CheckInForm checkIn;
    private long lockedAt;           // when the Windows session was locked (TickCount64), 0 if not
    private bool lockPending;        // the session just ran out: lock Windows after a short countdown
    private long lockAt;
    private bool sessionWarned5, sessionWarned1;
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

    public Guard(AppModel model, BlockForm cover, CheckInForm checkIn)
    {
        m = model;
        this.cover = cover;
        this.checkIn = checkIn;
        Microsoft.Win32.SystemEvents.SessionSwitch += OnSessionSwitch;
        timer.Tick += (_, _) => Safe(Tick);
        hookProc = OnWinEvent;
        hookFg = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, hookProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        hookName = Native.SetWinEventHook(Native.EVENT_OBJECT_NAMECHANGE, Native.EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, hookProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        timer.Start();
        Log.Write($"guard on: hooks fg={hookFg != IntPtr.Zero} name={hookName != IntPtr.Zero} limit={m.P.LimitMs} used={m.P.UsedMs} social={m.P.SocialBlock} checkin={m.P.CheckIn}");
    }

    /// <summary>Away for 10 minutes or more (screen locked): a new session, so ask again.</summary>
    private void OnSessionSwitch(object? sender, Microsoft.Win32.SessionSwitchEventArgs e)
    {
        if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionLock)
        {
            lockedAt = Environment.TickCount64;
        }
        else if (e.Reason == Microsoft.Win32.SessionSwitchReason.SessionUnlock)
        {
            long away = lockedAt == 0 ? 0 : Environment.TickCount64 - lockedAt;
            lockedAt = 0;
            Log.Write($"unlocked after {away / 1000}s");
            if (away >= 10 * MIN && m.P.SessionActive(m.Now()))
            {
                m.Mutate(now => { m.P.EndSession(now); return 0; });
            }
            Safe(Tick);
        }
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

        // the session the user asked for
        long srem = p.SessionRemaining(now);
        if (p.CheckIn && p.SessionEnd != 0)
        {
            if (srem > 5 * MIN) sessionWarned5 = sessionWarned1 = false;
            else if (srem > 0)
            {
                if (!sessionWarned5 && srem > MIN) { sessionWarned5 = true; Warn?.Invoke("נשארו 5 דקות מהזמן שקבעת: " + p.SessionWhat); }
                if (!sessionWarned1 && srem <= MIN) { sessionWarned1 = sessionWarned5 = true; Warn?.Invoke("נשארה דקה. בעוד דקה המחשב יינעל"); }
            }
            else if (sessionWarned1 || sessionWarned5)
            {
                // it ran out while we were watching: lock Windows in a few seconds
                sessionWarned1 = sessionWarned5 = false;
                lockPending = true;
                lockAt = t + 8_000;
                changed = true;
                Log.Write("session over: " + p.SessionWhat);
                checkIn.ShowNow(m.P, "הזמן שקבעת נגמר. המחשב יינעל עוד רגע");
            }
        }
        if (lockPending && t >= lockAt)
        {
            lockPending = false;
            if (p.NeedsCheckIn(now)) { Log.Write("locking Windows"); Native.LockWorkStation(); }
        }

        if (p.NeedsCheckIn(now) && lockedAt == 0 && !checkIn.Visible) checkIn.ShowNow(m.P, null);
        else if (!p.NeedsCheckIn(now) && checkIn.Visible) checkIn.Hide();

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
        string? url = null;
        if (m.P.SocialBlock && Rules.IsBrowser(fg.Proc))
        {
            var target = fg;
            url = UrlReader.Get(fg.Hwnd, fg.Title, () => cover.BeginInvoke(() => Safe(() =>
            {
                var now2 = Current();
                if (now2.Hwnd == target.Hwnd) Evaluate(now2, m.Now());
            })));
        }
        var v = Rules.Classify(m.P, now, fg.Proc, fg.Title, url);
        if (fg.Hwnd != lastLogged || fg.Title != lastTitle)
        {
            lastLogged = fg.Hwnd;
            lastTitle = fg.Title;
            Log.Write($"front: {fg.Proc} \"{Short(fg.Title)}\" url={url ?? "?"} -> {v}");
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
            case Verdict.CheckIn:
                Native.ShowWindowAsync(fg.Hwnd, Native.SW_MINIMIZE);
                checkIn.ShowNow(m.P, null);
                return;
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
        Microsoft.Win32.SystemEvents.SessionSwitch -= OnSessionSwitch;
        if (hookFg != IntPtr.Zero) Native.UnhookWinEvent(hookFg);
        if (hookName != IntPtr.Zero) Native.UnhookWinEvent(hookName);
        if (usageDirty) m.Save();
    }
}
