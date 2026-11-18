using System;
using Ogen.Core;
using Xunit;

namespace Ogen.Tests;

public class CheckInTests
{
    const long MIN = 60_000L, H = 60 * MIN;
    static readonly long T = new DateTimeOffset(new DateTime(2026, 11, 16, 10, 0, 0, DateTimeKind.Local)).ToUnixTimeMilliseconds();
    const long Boot = 1_000_000;

    [Fact]
    public void NothingWorksUntilYouCheckIn()
    {
        var p = new Policy();
        Assert.True(p.NeedsCheckIn(T));
        Assert.Equal(Verdict.CheckIn, Rules.Classify(p, T, "notepad", "Untitled - Notepad"));
        Assert.Equal(Verdict.CheckIn, Rules.Classify(p, T, "explorer", "Downloads"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "Ogen", "עוגן"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "TextInputHost", ""));
        Assert.Equal(Verdict.Tamper, Rules.Classify(p, T, "taskmgr", "Task Manager"));
    }

    [Fact]
    public void SessionOpensTheComputerUntilItEnds()
    {
        var p = new Policy();
        p.StartSession(30 * MIN, "עבודה על פרויקט", "להגיש מחר", Boot, T);
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T + 29 * MIN, "notepad", "x"));
        Assert.Equal(Verdict.SocialSite, Rules.Classify(p, T + MIN, "chrome", "YouTube - Google Chrome"));
        Assert.Equal(Verdict.CheckIn, Rules.Classify(p, T + 30 * MIN, "notepad", "x"));
        Assert.Equal("עבודה על פרויקט", p.SessionWhat);
    }

    [Fact]
    public void SessionNeverOutlastsTheDailyTime()
    {
        var p = new Policy();
        p.RequestLimit(H, T);
        p.AddUsage(50 * MIN, T);
        p.StartSession(2 * H, "a", "b", Boot, T);
        Assert.Equal(T + 10 * MIN, p.SessionEnd);
    }

    [Fact]
    public void RestartAsksAgain_SameBootDoesNot()
    {
        var p = new Policy();
        p.StartSession(H, "a", "b", Boot, T);
        p.ForgetSessionIfOtherBoot(Boot + 5_000, T + MIN);
        Assert.True(p.SessionActive(T + MIN));
        p.ForgetSessionIfOtherBoot(Boot + 3 * H, T + 2 * MIN);
        Assert.False(p.SessionActive(T + 2 * MIN));
        Assert.True(p.NeedsCheckIn(T + 2 * MIN));
    }

    [Fact]
    public void TimeUpBeatsCheckIn()
    {
        var p = new Policy();
        p.RequestLimit(30 * MIN, T);
        p.AddUsage(30 * MIN, T);
        Assert.False(p.NeedsCheckIn(T));
        Assert.Equal(Verdict.Locked, Rules.Classify(p, T, "notepad", "x"));
    }

    [Fact]
    public void TurningCheckInOffWaits24h()
    {
        var p = new Policy();
        Assert.False(p.RequestCheckIn(false, T));
        Assert.True(p.CheckIn);
        p.Tick(T + Policy.Day);
        Assert.False(p.CheckIn);
        Assert.True(p.RequestCheckIn(true, T + Policy.Day));
        Assert.True(p.CheckIn);
    }

    [Fact]
    public void SessionSurvivesSerialization_AndOldStateStillLoads()
    {
        var p = new Policy();
        p.StartSession(H, "לימודים | מתמטיקה\nשורה", "מבחן", Boot, T);
        var q = Policy.Parse(p.Serialize());
        Assert.Equal(p.Serialize(), q.Serialize());
        Assert.Equal("לימודים / מתמטיקה שורה", q.SessionWhat);
        var old = Policy.Parse("w1\n1800000\n60000\n0\n1\nspotify\n");
        Assert.Equal(30 * MIN, old.LimitMs);
        Assert.Contains("spotify", old.ExtraAllowed);
        Assert.True(old.CheckIn);
    }

    [Theory]
    [InlineData("youtube.com/watch?v=abc", true)]
    [InlineData("https://www.youtube.com/", true)]
    [InlineData("m.facebook.com", true)]
    [InlineData("www.reddit.com/r/all", true)]
    [InlineData("google.com/search?q=youtube", false)]
    [InlineData("notyoutube.com", false)]
    [InlineData("youtube", false)]
    [InlineData("how to use youtube", false)]
    public void Urls(string url, bool blocked) => Assert.Equal(blocked, Rules.BlockedUrl(url));

    [Fact]
    public void AddressBarCatchesWhatTheTitleMisses()
    {
        var p = new Policy();
        p.StartSession(H, "a", "b", Boot, T);
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "chrome", "www.reddit.com - Google Chrome"));
        Assert.Equal(Verdict.SocialSite, Rules.Classify(p, T, "chrome", "www.reddit.com - Google Chrome", "www.reddit.com"));
    }
}
