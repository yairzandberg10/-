using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using Microsoft.Win32;
using Ogen.Core;

namespace Ogen;

/// <summary>Holds the policy, the trusted clock and persistence. Shared by the guard and the UI.</summary>
internal sealed class AppModel
{
    public Policy P;
    public readonly TrustedClock Clock;
    public readonly Dictionary<string, string> Names = new(StringComparer.OrdinalIgnoreCase);
    public readonly bool Preview;
    private readonly Func<long> wall;
    private readonly Func<long> tick;
    private long seq;
    private bool clockDirty;

    /// <summary>Raised on the UI thread whenever the policy or usage changed.</summary>
    public event Action? Changed;

    public AppModel(Policy p, TrustedClock clock, Func<long> wall, Func<long> tick, bool preview)
    {
        P = p;
        Clock = clock;
        this.wall = wall;
        this.tick = tick;
        Preview = preview;
    }

    public static AppModel Load()
    {
        var (policy, clock, seq) = Store.Load();
        var m = new AppModel(policy, clock,
            () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), () => Environment.TickCount64, false) { seq = seq };
        foreach (var kv in Store.LoadNames()) m.Names[kv.Key] = kv.Value;
        return m;
    }

    public long WallNow() => wall();

    public long Now()
    {
        long t = Clock.Now(wall(), tick(), P.Committed, out bool dirty);
        if (dirty) clockDirty = true;
        return t;
    }

    public bool ClockDirty => clockDirty;

    public void Save()
    {
        if (Preview) return;
        seq++;
        Store.Save(P, Clock, seq);
        clockDirty = false;
    }

    /// <summary>Apply a user change, persist it and refresh every view.</summary>
    public T Mutate<T>(Func<long, T> change)
    {
        long now = Now();
        T r = change(now);
        Save();
        Changed?.Invoke();
        return r;
    }

    public void RaiseChanged() => Changed?.Invoke();

    public string When(long trusted) => Fmt.When(Clock.ToWall(trusted), wall());

    public string DisplayName(string pkg) => Names.TryGetValue(pkg, out var n) && n.Length > 0 ? n : pkg;

    public void RememberName(string pkg, string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return;
        Names[pkg] = name.Trim();
        if (!Preview) Store.SaveNames(Names);
    }
}

/// <summary>
/// State lives in a file under %LOCALAPPDATA%\Ogen and is mirrored to the registry.
/// Deleting one copy does not reset anything: the newest surviving copy wins.
/// </summary>
internal static class Store
{
    private const string Header = "ogen-state 1";
    private const string RegKey = @"Software\Ogen";

    public static string DataDir =>
        Environment.GetEnvironmentVariable("OGEN_DATA") is { Length: > 0 } d
            ? d
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ogen");

    private static string StateFile => Path.Combine(DataDir, "state.txt");
    private static string NamesFile => Path.Combine(DataDir, "names.txt");
    private static bool UseRegistry => Environment.GetEnvironmentVariable("OGEN_DATA") is not { Length: > 0 };

    public static (Policy, TrustedClock, long) Load()
    {
        var a = Parse(ReadFile());
        var b = Parse(ReadRegistry());
        var best = a.seq >= b.seq ? a : b;
        return (best.policy ?? new Policy(), best.clock ?? new TrustedClock(), best.seq);
    }

    public static void Save(Policy p, TrustedClock c, long seq)
    {
        string blob = string.Join("\n", Header, seq, c.Offset, c.LastWall, c.LastTick) + "\n" + p.Serialize();
        try
        {
            Directory.CreateDirectory(DataDir);
            string tmp = StateFile + ".tmp";
            File.WriteAllText(tmp, blob);
            File.Move(tmp, StateFile, true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        if (UseRegistry)
        {
            try
            {
                using var k = Registry.CurrentUser.CreateSubKey(RegKey);
                k.SetValue("state", blob);
            }
            catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
        }
    }

    private static string? ReadFile()
    {
        try { return File.Exists(StateFile) ? File.ReadAllText(StateFile) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static string? ReadRegistry()
    {
        if (!UseRegistry) return null;
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RegKey);
            return k?.GetValue("state") as string;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException) { return null; }
    }

    private static (Policy? policy, TrustedClock? clock, long seq) Parse(string? blob)
    {
        if (blob == null) return (null, null, -1);
        var lines = blob.Replace("\r", "").Split('\n');
        if (lines.Length < 6 || lines[0] != Header) return (null, null, -1);
        try
        {
            long seq = long.Parse(lines[1], CultureInfo.InvariantCulture);
            var clock = new TrustedClock
            {
                Offset = long.Parse(lines[2], CultureInfo.InvariantCulture),
                LastWall = long.Parse(lines[3], CultureInfo.InvariantCulture),
                LastTick = long.Parse(lines[4], CultureInfo.InvariantCulture),
            };
            var policy = Policy.Parse(string.Join("\n", lines.Skip(5)));
            return (policy, clock, seq);
        }
        catch (Exception e) when (e is FormatException or OverflowException)
        {
            return (null, null, -1);
        }
    }

    public static Dictionary<string, string> LoadNames()
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            if (!File.Exists(NamesFile)) return d;
            foreach (var line in File.ReadAllLines(NamesFile))
            {
                int i = line.IndexOf('\t');
                if (i > 0) d[line[..i]] = line[(i + 1)..];
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return d;
    }

    public static void SaveNames(Dictionary<string, string> names)
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            File.WriteAllLines(NamesFile, names.Select(kv => kv.Key + "\t" + kv.Value.Replace('\t', ' ')));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
