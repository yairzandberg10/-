using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Ogen.Core;

/// <summary>
/// The whole commitment model, with no Windows dependencies so it can be unit tested.
/// Ported 1:1 from the Android app.
///
/// Rule of the app: anything that makes you STRICTER happens immediately.
/// Anything that LOOSENS a commitment (larger limit, removing the limit, allowing
/// another app, turning off the social block) is queued and only takes effect
/// 24 hours later. There is no other way out.
///
/// All times are "trusted" unix milliseconds (wall clock corrected for manual clock changes).
/// </summary>
public sealed class Policy
{
    public const long Day = 24L * 60 * 60 * 1000;
    public const long None = -1;

    public const int ChLimit = 1;      // value = new limit ms, or None to remove
    public const int ChAllow = 2;      // pkg = app (process name) to allow during lockdown
    public const int ChSocialOff = 3;  // turn off the always-on social/video block
    public const int ChCheckInOff = 4; // stop asking "what, how long, why" when you sit down

    public sealed record Change(int Type, long Value, string Pkg, long At);

    // ---- persisted state ----
    public long LimitMs = None;     // daily screen-time allowance
    public long UsedMs;             // used today
    public long UsageDay;           // start of the day UsedMs belongs to
    public bool SocialBlock = true; // always block social/video while committed
    public bool CheckIn = true;     // ask what / how long / why before the computer can be used

    // the current session (from the check-in); 0 = none
    public long SessionStart;
    public long SessionEnd;
    public long SessionBoot;        // which boot the session belongs to: a restart always asks again
    public string SessionWhat = "";
    public string SessionWhy = "";

    public readonly HashSet<string> ExtraAllowed = new(StringComparer.OrdinalIgnoreCase);
    public readonly List<Change> Pending = new();

    // ---- queries ----

    public bool Committed(long now) => LimitMs != None;

    /// <summary>The guard must run (and protect itself): any active limit, or the social block.</summary>
    public bool Guarding(long now) => Committed(now) || SocialBlock || CheckIn;

    /// <summary>A session is running: the user said what they are doing and the time has not run out.</summary>
    public bool SessionActive(long now) => SessionEnd > now;

    /// <summary>The check-in screen must be answered before anything else can be used.</summary>
    public bool NeedsCheckIn(long now) => CheckIn && !SessionActive(now) && !BudgetSpent();

    public long SessionRemaining(long now) => SessionActive(now) ? SessionEnd - now : 0;

    /// <summary>Start a session; never longer than what is left of the daily time.</summary>
    public void StartSession(long durationMs, string what, string why, long boot, long now)
    {
        Tick(now);
        long d = Math.Max(60_000, durationMs);
        if (LimitMs != None) d = Math.Min(d, Math.Max(60_000, RemainingMs()));
        SessionStart = now;
        SessionEnd = now + d;
        SessionBoot = boot;
        SessionWhat = Clean(what);
        SessionWhy = Clean(why);
    }

    /// <summary>Ending a session early is stricter: always allowed.</summary>
    public void EndSession(long now)
    {
        if (SessionEnd > now) SessionEnd = now;
    }

    /// <summary>A new boot (or a long time away) means a new session: ask again.</summary>
    public void ForgetSessionIfOtherBoot(long boot, long now)
    {
        if (SessionEnd > now && Math.Abs(boot - SessionBoot) > 120_000) SessionEnd = now;
    }

    private static string Clean(string s) => (s ?? "").Replace('\n', ' ').Replace('\r', ' ').Replace('|', '/').Trim();

    public bool BudgetSpent() => LimitMs != None && UsedMs >= LimitMs;

    public bool Locked(long now) => BudgetSpent();

    /// <summary>When the current lockdown ends (0 if not locked).</summary>
    public long LockEnds(long now) => BudgetSpent() ? NextDayStart(now) : 0;

    public long RemainingMs() => LimitMs == None ? None : Math.Max(0, LimitMs - UsedMs);

    public Change? PendingLimit() => Pending.FirstOrDefault(c => c.Type == ChLimit);
    public Change? PendingSocialOff() => Pending.FirstOrDefault(c => c.Type == ChSocialOff);
    public Change? PendingCheckInOff() => Pending.FirstOrDefault(c => c.Type == ChCheckInOff);
    public Change? PendingAllow(string pkg) =>
        Pending.FirstOrDefault(c => c.Type == ChAllow && string.Equals(c.Pkg, pkg, StringComparison.OrdinalIgnoreCase));

    // ---- time housekeeping ----

    /// <summary>Resets daily usage at midnight and applies queued changes whose time has come.</summary>
    public bool Tick(long now)
    {
        bool changed = false;
        long today = DayStart(now);
        if (today > UsageDay)
        {   // only ever moves forward
            UsageDay = today;
            UsedMs = 0;
            changed = true;
        }
        for (int i = Pending.Count - 1; i >= 0; i--)
        {
            var c = Pending[i];
            if (c.At <= now)
            {
                Apply(c);
                Pending.RemoveAt(i);
                changed = true;
            }
        }
        return changed;
    }

    public void AddUsage(long ms, long now)
    {
        Tick(now);
        if (ms > 0 && LimitMs != None) UsedMs += ms;
    }

    // ---- user requests ----

    /// <returns>true if applied immediately, false if queued for 24h.</returns>
    public bool RequestLimit(long newLimit, long now)
    {
        Tick(now);
        bool stricter = newLimit != None && (LimitMs == None || newLimit <= LimitMs);
        if (stricter || !Committed(now))
        {
            RemovePending(ChLimit, null);   // tightening cancels a queued loosening
            LimitMs = newLimit;
            if (UsageDay == 0) UsageDay = DayStart(now);
            return true;
        }
        RemovePending(ChLimit, null);
        Pending.Add(new Change(ChLimit, newLimit, "", now + Day));
        return false;
    }

    public bool RequestAllow(string pkg, long now)
    {
        Tick(now);
        if (ExtraAllowed.Contains(pkg) || PendingAllow(pkg) != null) return false;
        if (!Committed(now))
        {
            ExtraAllowed.Add(pkg);
            return true;
        }
        Pending.Add(new Change(ChAllow, 0, pkg, now + Day));
        return false;
    }

    /// <summary>Removing an app from the allow-list is stricter: immediate.</summary>
    public void Disallow(string pkg)
    {
        ExtraAllowed.Remove(pkg);
        RemovePending(ChAllow, pkg);
    }

    public bool RequestSocialBlock(bool on, long now)
    {
        Tick(now);
        if (on)
        {
            SocialBlock = true;
            RemovePending(ChSocialOff, null);
            return true;
        }
        if (!SocialBlock || PendingSocialOff() != null) return false;
        // turning the social block off is always delayed: it is the default protection
        Pending.Add(new Change(ChSocialOff, 0, "", now + Day));
        return false;
    }

    public bool RequestCheckIn(bool on, long now)
    {
        Tick(now);
        if (on)
        {
            CheckIn = true;
            RemovePending(ChCheckInOff, null);
            return true;
        }
        if (!CheckIn || PendingCheckInOff() != null) return false;
        Pending.Add(new Change(ChCheckInOff, 0, "", now + Day));
        return false;
    }

    /// <summary>Withdrawing a queued loosening is always allowed (it is stricter).</summary>
    public void CancelPending(int type, string? pkg) => RemovePending(type, pkg);

    // ---- internals ----

    private void Apply(Change c)
    {
        switch (c.Type)
        {
            case ChLimit: LimitMs = c.Value; break;
            case ChAllow: ExtraAllowed.Add(c.Pkg); break;
            case ChSocialOff: SocialBlock = false; break;
            case ChCheckInOff: CheckIn = false; break;
        }
    }

    private void RemovePending(int type, string? pkg) =>
        Pending.RemoveAll(c => c.Type == type && (pkg == null || string.Equals(c.Pkg, pkg, StringComparison.OrdinalIgnoreCase)));

    public static long DayStart(long t)
    {
        var local = DateTimeOffset.FromUnixTimeMilliseconds(t).ToLocalTime();
        return LocalMidnight(local.Date);
    }

    public static long NextDayStart(long t)
    {
        var local = DateTimeOffset.FromUnixTimeMilliseconds(t).ToLocalTime();
        return LocalMidnight(local.Date.AddDays(1));
    }

    private static long LocalMidnight(DateTime date)
    {
        var d = DateTime.SpecifyKind(date, DateTimeKind.Unspecified);
        return new DateTimeOffset(d, TimeZoneInfo.Local.GetUtcOffset(d)).ToUnixTimeMilliseconds();
    }

    // ---- serialization (plain text, one field per line) ----

    public string Serialize()
    {
        var b = new StringBuilder();
        b.Append("w2\n");
        b.Append(LimitMs).Append('\n').Append(UsedMs).Append('\n').Append(UsageDay).Append('\n')
         .Append(SocialBlock ? 1 : 0).Append('\n');
        b.Append(string.Join(",", ExtraAllowed.OrderBy(a => a, StringComparer.OrdinalIgnoreCase))).Append('\n');
        b.Append(CheckIn ? 1 : 0).Append('\n').Append(SessionStart).Append('\n').Append(SessionEnd).Append('\n')
         .Append(SessionBoot).Append('\n').Append(B64(SessionWhat)).Append('\n').Append(B64(SessionWhy)).Append('\n');
        foreach (var c in Pending)
            b.Append(c.Type).Append('|').Append(c.Value).Append('|').Append(c.Pkg).Append('|').Append(c.At).Append('\n');
        return b.ToString();
    }

    public static Policy Parse(string? s)
    {
        var p = new Policy();
        if (s == null) return p;
        var l = s.Replace("\r", "").Split('\n');
        bool v2 = l.Length >= 12 && l[0] == "w2";
        if (!v2 && (l.Length < 6 || l[0] != "w1")) return p;
        try
        {
            p.LimitMs = L(l[1]);
            p.UsedMs = L(l[2]);
            p.UsageDay = L(l[3]);
            p.SocialBlock = l[4] == "1";
            foreach (var a in l[5].Split(',')) if (a.Length > 0) p.ExtraAllowed.Add(a);
            int first = 6;
            if (v2)
            {
                p.CheckIn = l[6] == "1";
                p.SessionStart = L(l[7]);
                p.SessionEnd = L(l[8]);
                p.SessionBoot = L(l[9]);
                p.SessionWhat = Unb64(l[10]);
                p.SessionWhy = Unb64(l[11]);
                first = 12;
            }
            for (int i = first; i < l.Length; i++)
            {
                if (l[i].Length == 0) continue;
                var f = l[i].Split('|');
                p.Pending.Add(new Change(int.Parse(f[0], CultureInfo.InvariantCulture), L(f[1]), f[2], L(f[3])));
            }
        }
        catch (Exception e) when (e is FormatException or OverflowException or IndexOutOfRangeException)
        {
            // corrupted state: fail strict rather than open — keep what parsed
        }
        return p;
    }

    private static string B64(string s) => Convert.ToBase64String(Encoding.UTF8.GetBytes(s ?? ""));
    private static string Unb64(string s) => Encoding.UTF8.GetString(Convert.FromBase64String(s));

    private static long L(string s) => long.Parse(s, CultureInfo.InvariantCulture);
}
