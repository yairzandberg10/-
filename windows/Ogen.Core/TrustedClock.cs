using System;

namespace Ogen.Core;

/// <summary>
/// A "trusted" clock, ported from the Android app.
///
/// While a commitment is active, manual clock changes are absorbed into an offset
/// (detected by comparing the wall clock against the time since boot), so moving the
/// clock forward does not apply a queued loosening early and moving it to tomorrow
/// does not reset today's usage.
/// </summary>
public sealed class TrustedClock
{
    public const long Drift = 90_000L;

    public long Offset;
    public long LastWall;
    public long LastTick = -1;

    /// <param name="wall">Wall clock, unix ms.</param>
    /// <param name="tick">Milliseconds since boot (includes sleep), e.g. Environment.TickCount64.</param>
    /// <param name="committedAt">Whether a commitment is active at a given trusted time.</param>
    /// <returns>Trusted time. <paramref name="dirty"/> is true when the state should be persisted.</returns>
    public long Now(long wall, long tick, Func<long, bool> committedAt, out bool dirty)
    {
        long before = Offset;
        long lastTrusted = LastWall - Offset;
        if (LastTick >= 0 && tick >= LastTick)
        {
            // same boot: we know exactly how much real time passed
            long expected = LastWall + (tick - LastTick);
            long jump = wall - expected;
            if (Math.Abs(jump) > Drift && committedAt(lastTrusted)) Offset += jump;
        }
        else if (LastTick >= 0)
        {
            // after a reboot: never let trusted time go backwards
            if (wall - Offset < lastTrusted) Offset = wall - lastTrusted;
        }
        long trusted = wall - Offset;
        if (!committedAt(trusted) && Offset != 0)
        {
            // nothing to protect: return to real time
            Offset = 0;
            trusted = wall;
        }
        // markers stay valid between writes, so only persist every 30s or when the offset moves
        dirty = Offset != before || LastTick < 0 || tick < LastTick || tick - LastTick > 30_000;
        if (dirty)
        {
            LastWall = wall;
            LastTick = tick;
        }
        return trusted;
    }

    /// <summary>Convert a trusted time into the device's wall clock, for display.</summary>
    public long ToWall(long trusted) => trusted + Offset;
}
