using System;
using System.Drawing;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>Full-screen night cover shown over anything that is blocked.</summary>
internal sealed class BlockForm : Form
{
    private readonly AppModel m;
    private readonly Stack stack = new() { PadX = 0, PadTop = 0, PadBottom = 0 };
    private readonly Timer refresh = new() { Interval = 15_000 };
    private Verdict reason;
    public Action? OpenApp;

    public BlockForm(AppModel model)
    {
        m = model;
        Text = "עוגן";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Theme.Night;
        KeyPreview = true;
        stack.BackColor = Theme.Night;
        stack.AutoScroll = false;
        Controls.Add(stack);
        refresh.Tick += (_, _) => { if (Visible) Build(); };
        refresh.Start();
    }

    protected override bool ShowWithoutActivation => false;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW: stays out of Alt+Tab
            return cp;
        }
    }

    public void ShowFor(Verdict why, Screen screen) => ShowAt(why, screen.Bounds);

    public void ShowAt(Verdict why, Rectangle bounds)
    {
        reason = why;
        Bounds = bounds;
        Build();
        if (!Visible) Show();
        TopMost = true;
        BringToFront();
        Activate();
        Native.SetForegroundWindow(Handle);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode is Keys.Escape or Keys.Enter) Hide();
        base.OnKeyDown(e);
    }

    // Alt+F4 just hides the cover
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }

    private void Build()
    {
        float s = DeviceDpi / 96f;
        stack.S = s;
        stack.SuspendLayout();
        var old = new Control[stack.Controls.Count];
        stack.Controls.CopyTo(old, 0);
        stack.Controls.Clear();
        foreach (var c in old) c.Dispose();
        long now = m.Now();

        stack.Add(new AnchorBlock(40, Theme.OnNight));
        stack.Add(new TextBlock(Title(reason), 30, Theme.OnNight, Theme.W.Medium, true), 18);
        if (reason == Verdict.Locked)
        {
            stack.Add(new TextBlock("0:00", 72, Theme.OnNight, Theme.W.Light, true), 6);
            stack.Add(new TextBlock("מתאפס בחצות, בעוד " + Fmt.Words(m.P.LockEnds(now) - now), 15, Theme.OnNightMuted, Theme.W.Regular, true), 2);
        }
        else if (m.P.LimitMs != Policy.None)
        {
            stack.Add(new TextBlock("נשאר לך להשתמש היום: " + Fmt.Hm(m.P.RemainingMs()), 15, Theme.OnNightMuted, Theme.W.Regular, true), 6);
        }
        stack.Add(new TextBlock(Body(reason), 16, Theme.OnNightMuted, Theme.W.Regular, true), 16);
        var ok = stack.Add(new ButtonBlock("הבנתי", BtnStyle.Night, Hide), 28);
        stack.Add(new ButtonBlock("פתיחת עוגן", BtnStyle.NightGhost, () => { Hide(); OpenApp?.Invoke(); }), 8);

        int w = Math.Min((int)(460 * s), ClientSize.Width - (int)(32 * s));
        int h = 0;
        foreach (Block b in stack.Controls) h += b.Measure(w) + (int)(b.Gap * s);
        stack.SetBounds((ClientSize.Width - w) / 2, Math.Max(0, (ClientSize.Height - h) / 2), w, h);
        stack.ResumeLayout(false);
        stack.Relayout();
        ok.Focus();
    }

    public static string Title(Verdict v) => v switch
    {
        Verdict.Tamper => "המסך הזה סגור עכשיו",
        Verdict.SocialApp => "לא עכשיו",
        Verdict.SocialSite => "האתר הזה חסום",
        _ => "זמן המסך להיום נגמר",
    };

    public static string Body(Verdict v) => v switch
    {
        Verdict.Tamper => "אי אפשר לעצור את עוגן או לכבות אותו. זה בדיוק מה שהבטחת לעצמך.",
        Verdict.SocialApp => "רשתות חברתיות ווידאו חסומים תמיד.",
        Verdict.SocialSite => "אתרים של רשתות חברתיות ווידאו חסומים בכל דפדפן. הלשונית נסגרה.",
        _ => "עד חצות פתוחות רק האפליקציות שתמיד פתוחות. שום דבר לא נסגר – החלונות רק מוזערו. מחר מתחילים מחדש.",
    };

    protected override void Dispose(bool disposing)
    {
        if (disposing) refresh.Dispose();
        base.Dispose(disposing);
    }
}
