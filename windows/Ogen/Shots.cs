using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>
/// "Ogen.exe --shots dir": renders every screen in a fixed state to PNG, for CI and the README.
/// Nothing is saved and no guard runs.
/// </summary>
internal static class Shots
{
    private const long MIN = 60_000L, H = 60 * MIN;

    public static int Run(string dir)
    {
        Directory.CreateDirectory(dir);
        var nowLocal = DateTime.Today.AddHours(15).AddMinutes(20);
        long now = new DateTimeOffset(nowLocal).ToUnixTimeMilliseconds();

        AppModel Model(Action<Policy> setup)
        {
            var p = new Policy();
            p.Tick(now);
            setup(p);
            var m = new AppModel(p, new TrustedClock(), () => now, () => 1_000_000, preview: true);
            m.Names["spotify"] = "Spotify";
            m.Names["whatsapp"] = "WhatsApp";
            m.Names["code"] = "Visual Studio Code";
            return m;
        }

        var ci = Model(p => p.RequestLimit(3 * H, now - 3 * H));
        ci.P.UsedMs = 70 * MIN;
        using (var f = new CheckInForm(ci))
        {
            f.ShowNow(ci.P, null);
            Capture(f, Path.Combine(dir, "00-checkin.png"));
            f.Hide();
        }
        Window(dir, "00b-home-session", Model(p =>
        {
            p.RequestLimit(3 * H, now - 3 * H);
            p.UsedMs = 70 * MIN;
            p.StartSession(H, "שיעורי בית במתמטיקה", "יש לי מבחן ביום ראשון", 0, now - 22 * MIN);
        }), MainForm.Page.Home, f => f.PreviewSessions = new() { ("09:10", 45, "מצגת לעבודה", "להגיש עד הצהריים"), ("15:00", 60, "שיעורי בית במתמטיקה", "יש לי מבחן ביום ראשון") });
        Window(dir, "00c-checkin-page", Model(_ => { }), MainForm.Page.CheckIn);
        Window(dir, "01-home", Model(_ => { }), MainForm.Page.Home);
        Window(dir, "02-home-limit", Model(p => { p.RequestLimit(2 * H, now - 3 * H); p.UsedMs = 75 * MIN; }), MainForm.Page.Home);
        Window(dir, "03-home-low", Model(p => { p.RequestLimit(H, now - 3 * H); p.UsedMs = 56 * MIN; }), MainForm.Page.Home);
        Window(dir, "04-home-time-up", Model(p => { p.RequestLimit(H, now - 3 * H); p.UsedMs = H; }), MainForm.Page.Home);
        Window(dir, "05-limit", Model(_ => { }), MainForm.Page.Limit);
        Window(dir, "06-limit-pending", Model(p => { p.RequestLimit(H, now - 3 * H); p.RequestLimit(3 * H, now - 2 * H); }), MainForm.Page.Limit);
        Window(dir, "07-social", Model(_ => { }), MainForm.Page.Social);
        Window(dir, "08-social-pending", Model(p => p.RequestSocialBlock(false, now - H)), MainForm.Page.Social);
        Window(dir, "09-allow", Model(p =>
        {
            p.RequestAllow("spotify", now);
            p.RequestAllow("whatsapp", now);
            p.RequestLimit(2 * H, now);
            p.RequestAllow("code", now);
        }), MainForm.Page.Allow);

        using (var c = new ConfirmForm("שעה ו-30 דק׳ של שימוש ביום", "מתחיל מהיום. אחרי האישור לא תוכל להוסיף זמן או לבטל במשך 24 שעות.", 1f))
        {
            c.StartPosition = FormStartPosition.Manual;
            c.Location = new Point(40, 40);
            c.Show();
            Capture(c, Path.Combine(dir, "10-confirm.png"));
            c.Hide();
        }

        Cover(dir, "11-block-time-up", Model(p => { p.RequestLimit(H, now - 3 * H); p.UsedMs = H; }), Verdict.Locked);
        Cover(dir, "12-block-site", Model(p => { p.RequestLimit(2 * H, now - 3 * H); p.UsedMs = 40 * MIN; }), Verdict.SocialSite);
        Cover(dir, "13-block-tamper", Model(_ => { }), Verdict.Tamper);
        SaveTray(dir);
        return 0;
    }

    private static void Window(string dir, string name, AppModel m, MainForm.Page page, Action<MainForm>? setup = null)
    {
        using var f = new MainForm(m) { StartPosition = FormStartPosition.Manual, Location = new Point(40, 20) };
        setup?.Invoke(f);
        f.Show();
        f.Go(page);
        Capture(f, Path.Combine(dir, name + ".png"));
        f.Hide();
    }

    private static void Cover(string dir, string name, AppModel m, Verdict v)
    {
        using var b = new BlockForm(m);
        b.ShowAt(v, new Rectangle(0, 0, 1280, 800));
        Capture(b, Path.Combine(dir, name + ".png"));
        b.Hide();
    }

    private static void SaveTray(string dir)
    {
        using var bmp = new Bitmap(96, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.FromArgb(32, 32, 32));
            int x = 0;
            foreach (var c in new[] { Theme.Pine, Theme.Brick, Theme.Muted })
            {
                using var ic = AnchorMark.TrayIcon(c);
                g.DrawIcon(ic, x, 0);
                x += 32;
            }
        }
        bmp.Save(Path.Combine(dir, "14-tray-icons.png"), ImageFormat.Png);
    }

    /// <summary>Real screen capture of the window (what a user sees); falls back to DrawToBitmap.</summary>
    private static void Capture(Form f, string path)
    {
        f.TopMost = true;
        f.Activate();
        for (int i = 0; i < 10; i++) { Application.DoEvents(); Thread.Sleep(40); }
        var r = f.Bounds;
        using var bmp = new Bitmap(r.Width, r.Height);
        try
        {
            using var g = Graphics.FromImage(bmp);
            g.CopyFromScreen(r.Location, Point.Empty, r.Size);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            f.DrawToBitmap(bmp, new Rectangle(Point.Empty, r.Size));
        }
        bmp.Save(path, ImageFormat.Png);
        f.TopMost = false;
    }
}
