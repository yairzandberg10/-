using System;
using Ogen.Core;
using Xunit;

namespace Ogen.Tests;

public class PolicyTests
{
    const long MIN = 60_000L, H = 60 * MIN;

    static long At(int day, int hour, int min) =>
        new DateTimeOffset(new DateTime(2026, 11, day, hour, min, 0, DateTimeKind.Local)).ToUnixTimeMilliseconds();

    [Fact]
    public void TighteningIsImmediate_LooseningIsQueued24h()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        Assert.True(p.RequestLimit(60 * MIN, t));
        Assert.Equal(60 * MIN, p.LimitMs);
        Assert.True(p.RequestLimit(30 * MIN, t));
        Assert.Equal(30 * MIN, p.LimitMs);
        Assert.False(p.RequestLimit(120 * MIN, t));
        Assert.Equal(30 * MIN, p.LimitMs);
        p.Tick(t + 23 * H);
        Assert.Equal(30 * MIN, p.LimitMs);
        p.Tick(t + 24 * H);
        Assert.Equal(120 * MIN, p.LimitMs);
    }

    [Fact]
    public void RemovingLimitIsQueued_AndMidnightDoesNotHelp()
    {
        var p = new Policy();
        long t = At(16, 23, 55);
        p.RequestLimit(10 * MIN, t);
        Assert.False(p.RequestLimit(Policy.None, t));
        p.Tick(At(17, 0, 1));
        Assert.Equal(10 * MIN, p.LimitMs);
        Assert.True(p.Committed(At(17, 0, 1)));
        p.Tick(At(17, 23, 56));
        Assert.Equal(Policy.None, p.LimitMs);
    }

    [Fact]
    public void BudgetLocksUntilMidnight_ThenResets()
    {
        var p = new Policy();
        long t = At(16, 9, 0);
        p.RequestLimit(30 * MIN, t);
        p.AddUsage(29 * MIN, t);
        Assert.False(p.Locked(t));
        p.AddUsage(2 * MIN, t);
        Assert.True(p.Locked(t));
        Assert.Equal(At(17, 0, 0), p.LockEnds(t));
        p.Tick(At(17, 0, 0));
        Assert.False(p.Locked(At(17, 0, 0)));
        Assert.Equal(0, p.UsedMs);
    }

    [Fact]
    public void TighteningCancelsQueuedLoosening()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        p.RequestLimit(60 * MIN, t);
        p.RequestLimit(240 * MIN, t);
        Assert.NotNull(p.PendingLimit());
        p.RequestLimit(45 * MIN, t);
        Assert.Null(p.PendingLimit());
        Assert.Equal(45 * MIN, p.LimitMs);
    }

    [Fact]
    public void AllowAndSocialAreQueuedWhileCommitted()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        Assert.True(p.RequestAllow("whatsapp", t)); // not committed yet: immediate
        p.RequestLimit(60 * MIN, t);
        Assert.False(p.RequestAllow("spotify", t));
        Assert.DoesNotContain("spotify", p.ExtraAllowed);
        Assert.False(p.RequestSocialBlock(false, t));
        Assert.True(p.SocialBlock);
        p.Disallow("whatsapp");
        Assert.DoesNotContain("whatsapp", p.ExtraAllowed);
        p.Tick(t + 24 * H);
        Assert.Contains("spotify", p.ExtraAllowed);
        Assert.False(p.SocialBlock);
    }

    [Fact]
    public void SocialBlockIsOnByDefault_AndTurningOffAlwaysWaits24h()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        Assert.True(p.SocialBlock);
        Assert.True(p.Guarding(t));
        Assert.False(p.Committed(t));
        Assert.True(p.RequestAllow("whatsapp", t));
        Assert.False(p.RequestSocialBlock(false, t));
        Assert.True(p.SocialBlock);
        p.Tick(t + 24 * H - 1);
        Assert.True(p.SocialBlock);
        p.Tick(t + 24 * H);
        Assert.False(p.SocialBlock);
        Assert.False(p.Guarding(t + 24 * H));
    }

    [Fact]
    public void TurningSocialBackOnCancelsQueuedOff()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        p.RequestSocialBlock(false, t);
        Assert.NotNull(p.PendingSocialOff());
        Assert.True(p.RequestSocialBlock(true, t));
        Assert.Null(p.PendingSocialOff());
        p.Tick(t + 25 * H);
        Assert.True(p.SocialBlock);
    }

    [Fact]
    public void SerializationRoundTrip()
    {
        var p = new Policy();
        long t = At(16, 10, 0);
        p.RequestLimit(60 * MIN, t);
        p.AddUsage(5 * MIN, t);
        p.RequestAllow("spotify", t);
        p.RequestLimit(Policy.None, t);
        var q = Policy.Parse(p.Serialize());
        Assert.Equal(p.Serialize(), q.Serialize());
        Assert.Equal(2, q.Pending.Count);
    }

    [Fact]
    public void CorruptStateFailsStrict()
    {
        var p = Policy.Parse("w1\n1800000\n0\n0\n1\n\n1|oops|x|y\n");
        Assert.Equal(30 * MIN, p.LimitMs);
        Assert.True(p.SocialBlock);
        Assert.True(Policy.Parse("garbage").SocialBlock);
    }
}

public class ClockTests
{
    const long MIN = 60_000L, H = 60 * MIN;

    [Fact]
    public void ClockJumpIsAbsorbedWhileCommitted()
    {
        var c = new TrustedClock();
        long wall = 1_800_000_000_000, tick = 1_000;
        Assert.Equal(wall, c.Now(wall, tick, _ => true, out _));
        // user moves the clock forward by a day, 10 seconds later
        long t2 = c.Now(wall + 24 * H + 10_000, tick + 10_000, _ => true, out bool dirty);
        Assert.True(dirty);
        Assert.Equal(wall + 10_000, t2);
    }

    [Fact]
    public void ClockReturnsToRealTimeWhenNothingIsProtected()
    {
        var c = new TrustedClock();
        long wall = 1_800_000_000_000, tick = 1_000;
        c.Now(wall, tick, _ => false, out _);
        Assert.Equal(wall + 24 * H, c.Now(wall + 24 * H, tick + 1_000, _ => false, out _));
    }

    [Fact]
    public void AfterRebootTrustedTimeNeverGoesBack()
    {
        var c = new TrustedClock();
        long wall = 1_800_000_000_000;
        c.Now(wall, 50 * H, _ => true, out _);
        // reboot (tick restarts), and the clock was moved back an hour
        long t = c.Now(wall - H, 5_000, _ => true, out _);
        Assert.Equal(wall, t);
    }

    [Fact]
    public void SleepIsNotAJump()
    {
        var c = new TrustedClock();
        long wall = 1_800_000_000_000, tick = 1_000;
        c.Now(wall, tick, _ => true, out _);
        // tick includes sleep time, so 8h of sleep moves both together
        Assert.Equal(wall + 8 * H, c.Now(wall + 8 * H, tick + 8 * H, _ => true, out _));
        Assert.Equal(0, c.Offset);
    }
}

public class FmtTests
{
    [Theory]
    [InlineData(0L, "0:00")]
    [InlineData(1L, "0:01")]
    [InlineData(65 * 60_000L, "1:05")]
    public void Hm(long ms, string expected) => Assert.Equal(expected, Fmt.Hm(ms));

    [Theory]
    [InlineData(45 * 60_000L, "45 דק׳")]
    [InlineData(60 * 60_000L, "שעה")]
    [InlineData(80 * 60_000L, "שעה ו-20 דק׳")]
    [InlineData(120 * 60_000L, "שעתיים")]
    [InlineData(180 * 60_000L, "3 שעות")]
    public void Words(long ms, string expected) => Assert.Equal(expected, Fmt.Words(ms));
}
