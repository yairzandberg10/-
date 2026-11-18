using System;
using Ogen.Core;
using Xunit;

namespace Ogen.Tests;

public class RulesTests
{
    const long MIN = 60_000L;
    static readonly long T = new DateTimeOffset(new DateTime(2026, 11, 16, 10, 0, 0, DateTimeKind.Local)).ToUnixTimeMilliseconds();

    [Theory]
    [InlineData("Funny cats - YouTube - Google Chrome")]
    [InlineData("YouTube and 3 more pages - Personal - Microsoft​ Edge")]
    [InlineData("(3) Facebook — Mozilla Firefox")]
    [InlineData("Instagram")]
    [InlineData("Dana (@dana) • Instagram photos and videos - Google Chrome")]
    [InlineData("TikTok - Make Your Day - Brave")]
    [InlineData("Home / X - Google Chrome")]
    [InlineData("Elon on X: \"hello\" / X - Microsoft Edge")]
    [InlineData("What is this? : r/whatisthisthing - Google Chrome")]
    [InlineData("Reddit - Dive into anything - Opera")]
    [InlineData("Netflix - Mozilla Firefox")]
    [InlineData("Feed | LinkedIn - Google Chrome")]
    public void BlockedTitles(string title) => Assert.True(Rules.BlockedTitle(title), title);

    [Theory]
    [InlineData("youtube download - Google Search - Google Chrome")]
    [InlineData("facebook - חיפוש ב-Google - Google Chrome")]
    [InlineData("How Facebook changed advertising | The Economist - Microsoft Edge")]
    [InlineData("Gmail - Inbox (3) - Google Chrome")]
    [InlineData("Kickstarter - Google Chrome")]
    [InlineData("Email threads explained - Google Chrome")]
    [InlineData("New Tab - Google Chrome")]
    [InlineData("")]
    public void AllowedTitles(string title) => Assert.False(Rules.BlockedTitle(title), title);

    [Fact]
    public void SocialBlockedEvenWithoutLimit()
    {
        var p = new Policy { CheckIn = false };
        Assert.Equal(Verdict.SocialSite, Rules.Classify(p, T, "chrome.exe", "Funny cats - YouTube - Google Chrome"));
        Assert.Equal(Verdict.SocialApp, Rules.Classify(p, T, "TikTok", "TikTok"));
        Assert.Equal(Verdict.SocialApp, Rules.Classify(p, T, "ApplicationFrameHost", "Netflix"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "notepad", "Untitled - Notepad"));
        // a non-browser with a social-looking title is fine (e.g. a document about YouTube)
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "winword", "YouTube - Word"));
    }

    [Fact]
    public void TamperScreensClosedWhileGuarding()
    {
        var p = new Policy { CheckIn = false };
        Assert.Equal(Verdict.Tamper, Rules.Classify(p, T, "Taskmgr", "Task Manager"));
        Assert.Equal(Verdict.Tamper, Rules.Classify(p, T, "mmc", "Task Scheduler"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "mmc", "Device Manager"));
        p.RequestSocialBlock(false, T);
        p.Tick(T + Policy.Day);
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T + Policy.Day, "Taskmgr", "Task Manager"));
    }

    [Fact]
    public void TimeUpLeavesOnlyFreeApps()
    {
        var p = new Policy { CheckIn = false };
        p.RequestAllow("spotify", T);
        p.RequestLimit(30 * MIN, T);
        p.AddUsage(30 * MIN, T);
        Assert.Equal(Verdict.Locked, Rules.Classify(p, T, "chrome", "New Tab - Google Chrome"));
        Assert.Equal(Verdict.Locked, Rules.Classify(p, T, "WINWORD.EXE", "Doc"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "explorer", "Downloads"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "Spotify.exe", "Spotify"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "PhoneExperienceHost", "Phone Link"));
        Assert.Equal(Verdict.Ok, Rules.Classify(p, T, "Ogen", "עוגן"));
    }

    [Fact]
    public void AlwaysOpenAppIsNotCounted()
    {
        var p = new Policy();
        p.RequestAllow("spotify", T);
        Assert.True(Rules.Free(p, "Spotify.exe"));
        Assert.True(Rules.Free(p, "explorer"));
        Assert.False(Rules.Free(p, "chrome"));
    }
}
