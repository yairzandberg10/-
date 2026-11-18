using System;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>Night card used for "time is up" on the home screen.</summary>
internal sealed class CardBlock : Block
{
    private readonly (string text, float size, Color color, Theme.W w)[] lines;
    private readonly Color bg;

    public CardBlock(Color bg, params (string, float, Color, Theme.W)[] lines) { this.bg = bg; this.lines = lines; }

    private const TextFormatFlags Flags = Theme.Center | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;

    private int LineH(int i, int w) =>
        TextRenderer.MeasureText(lines[i].text, Theme.F(lines[i].size * S, lines[i].w), new Size(w, int.MaxValue), Flags).Height;

    public override int Measure(int width)
    {
        int w = width - D(32), h = D(36);
        for (int i = 0; i < lines.Length; i++) h += LineH(i, w) + (i > 0 ? D(4) : 0);
        return h;
    }

    protected override void Draw(Graphics g)
    {
        using (var b = new SolidBrush(bg)) using (var p = Theme.Round(new RectangleF(0, 0, Width - 1, Height - 1), D(16))) g.FillPath(b, p);
        int w = Width - D(32), y = D(18);
        for (int i = 0; i < lines.Length; i++)
        {
            if (i > 0) y += D(4);
            int h = LineH(i, w);
            TextRenderer.DrawText(g, lines[i].text, Theme.F(lines[i].size * S, lines[i].w), new Rectangle(D(16), y, w, h), lines[i].color, Flags);
            y += h;
        }
    }
}

internal sealed class MainForm : Form
{
    public enum Page { Home, Limit, Social, Allow, CheckIn }

    private const long MIN = 60_000L, STEP = 15 * MIN;

    private readonly AppModel m;
    private readonly Stack stack = new();
    private readonly Timer refresh = new() { Interval = 1000 };
    private readonly Label toast = new();
    private readonly Timer toastTimer = new() { Interval = 2600 };
    private Page page = Page.Home;
    private long draft = -1;
    private string lastSnapshot = "";

    /// <summary>Set by the tray: false when autostart / watchdog could not be registered.</summary>
    public bool ProtectionOk = true;
    public Action? FixProtection;

    public MainForm(AppModel model)
    {
        m = model;
        Text = "עוגן";
        Icon = AnchorMark.TrayIcon(Theme.Pine, 64);
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Theme.Paper;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;

        stack.Dock = DockStyle.Fill;
        Controls.Add(stack);

        toast.Visible = false;
        toast.AutoSize = false;
        toast.TextAlign = ContentAlignment.MiddleCenter;
        toast.BackColor = Theme.Ink;
        toast.ForeColor = Theme.Paper;
        toast.RightToLeft = RightToLeft.Yes;
        Controls.Add(toast);
        toast.BringToFront();
        toastTimer.Tick += (_, _) => { toast.Visible = false; toastTimer.Stop(); };

        ApplyScale();
        m.Changed += () => { if (Visible && Snapshot() != lastSnapshot) Render(); };
        refresh.Tick += (_, _) => { if (Visible && Snapshot() != lastSnapshot) Render(); };
        refresh.Start();
        Render();
    }

    private float Sc => DeviceDpi / 96f;

    private void ApplyScale()
    {
        stack.S = Sc;
        ClientSize = new Size((int)(460 * Sc), (int)(720 * Sc));
        MinimumSize = new Size((int)(360 * Sc), (int)(480 * Sc));
        toast.Font = Theme.F(14 * Sc);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        ApplyScale();
        Render();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if ((e.KeyCode == Keys.Escape || e.KeyCode == Keys.BrowserBack || (e.Alt && e.KeyCode == Keys.Left)) && page != Page.Home)
        {
            Go(Page.Home);
            e.Handled = true;
        }
        base.OnKeyDown(e);
    }

    protected override void OnVisibleChanged(EventArgs e)
    {
        base.OnVisibleChanged(e);
        if (Visible) Render();
    }

    /// <summary>What the screen shows; re-render only when it changes (minute resolution).</summary>
    private string Snapshot()
    {
        long now = m.Now();
        var p = m.P;
        p.Tick(now);
        return $"{page}|{p.LimitMs}|{Fmt.Hm(p.UsedMs)}|{p.SocialBlock}|{string.Join(",", p.ExtraAllowed)}|{p.Pending.Count}|"
               + $"{(p.Locked(now) ? Fmt.Words(p.LockEnds(now) - now) : "")}|{ProtectionOk}|{draft}|{p.CheckIn}|{p.SessionEnd}|{Fmt.Hm(p.SessionRemaining(now))}";
    }

    public void Go(Page to)
    {
        page = to;
        draft = -1;
        Render();
        stack.AutoScrollPosition = new Point(0, 0);
    }

    public void Toast(string text)
    {
        toast.Text = text;
        var sz = TextRenderer.MeasureText(text, toast.Font);
        int w = sz.Width + (int)(32 * Sc), h = (int)(40 * Sc);
        toast.SetBounds((ClientSize.Width - w) / 2, ClientSize.Height - h - (int)(20 * Sc), w, h);
        toast.Visible = true;
        toast.BringToFront();
        toastTimer.Stop();
        toastTimer.Start();
    }

    public void Render()
    {
        lastSnapshot = Snapshot();
        Control? focused = stack.Controls.Cast<Control>().FirstOrDefault(c => c.Focused);
        string? focusName = focused?.AccessibleName;
        stack.SuspendLayout();
        var old = stack.Controls.Cast<Control>().ToList();
        stack.Controls.Clear();
        foreach (var c in old) c.Dispose();
        long now = m.Now();
        switch (page)
        {
            case Page.Limit: BuildLimit(now); break;
            case Page.Social: BuildSocial(now); break;
            case Page.Allow: BuildAllow(now); break;
            case Page.CheckIn: BuildCheckIn(now); break;
            default: BuildHome(now); break;
        }
        stack.ResumeLayout(false);
        stack.Relayout();
        // keyboard focus survives a re-render
        var again = focusName == null ? null : stack.Controls.Cast<Control>().FirstOrDefault(c => c.AccessibleName == focusName);
        again?.Focus();
    }

    // ---------------- home ----------------

    private void BuildHome(long now)
    {
        var p = m.P;
        bool guarding = p.Guarding(now);
        stack.Add(new HeaderBlock(guarding ? "מגן" : "כבוי", guarding));

        if (p.SessionActive(now) && !p.Locked(now))
        {
            long rem = p.SessionRemaining(now);
            long total = Math.Max(1, p.SessionEnd - p.SessionStart);
            bool low = rem <= 5 * MIN;
            stack.Add(new TextBlock("נשאר מהזמן שקבעת", 15, Theme.Muted, Theme.W.Medium, true), 20);
            stack.Add(new TextBlock(Fmt.Hm(rem), 84, low ? Theme.Brick : Theme.Ink, Theme.W.Light, true), 0);
            stack.Add(new BarBlock((float)(total - rem) / total, low ? Theme.Brick : Theme.Pine), 8);
            stack.Add(new NoteBlock("מה: " + p.SessionWhat + "\nלמה: " + p.SessionWhy, Theme.PineSoft, Theme.PineDark), 12);
            if (p.LimitMs != Policy.None)
                stack.Add(new TextBlock("נשאר להיום: " + Fmt.Hm(p.RemainingMs()) + " מתוך " + Fmt.Hm(p.LimitMs), 14, Theme.Muted, Theme.W.Regular, true), 8);
            stack.Add(new ButtonBlock("סיימתי – לנעול את המחשב", BtnStyle.Ghost, () =>
            {
                if (!ConfirmForm.Ask(this, "לסיים עכשיו?", "המחשב יינעל, ובכניסה הבאה עוגן ישאל שוב.")) return;
                m.Mutate(t => { p.EndSession(t); return 0; });
                Hide();
                if (!m.Preview) Native.LockWorkStation();
            }), 10);
        }
        else if (p.Locked(now))
        {
            long end = p.LockEnds(now);
            stack.Add(new CardBlock(Theme.Night,
                ("זמן המסך להיום נגמר", 15, Theme.OnNightMuted, Theme.W.Medium),
                ("0:00", 64, Theme.OnNight, Theme.W.Light),
                ("מתאפס בחצות, בעוד " + Fmt.Words(end - now) + "\nעד אז פתוחות רק האפליקציות שתמיד פתוחות", 14, Theme.OnNightMuted, Theme.W.Regular)), 16);
        }
        else if (p.LimitMs != Policy.None)
        {
            long rem = p.RemainingMs();
            bool low = rem <= Math.Max(5 * MIN, p.LimitMs / 5);
            stack.Add(new TextBlock("נשאר לך להשתמש היום", 15, Theme.Muted, Theme.W.Medium, true), 24);
            stack.Add(new TextBlock(Fmt.Hm(rem), 84, low ? Theme.Brick : Theme.Ink, Theme.W.Light, true), 0);
            float used = p.LimitMs <= 0 ? 1 : (float)p.UsedMs / p.LimitMs;
            stack.Add(new BarBlock(used, low ? Theme.Brick : Theme.Pine), 8);
            stack.Add(new TextBlock("השתמשת ב-" + Fmt.Hm(p.UsedMs) + " מתוך " + Fmt.Hm(p.LimitMs), 14, Theme.Muted, Theme.W.Regular, true), 10);
        }
        else
        {
            stack.Add(new TextBlock("לא נקבע זמן מסך", 15, Theme.Muted, Theme.W.Medium, true), 24);
            stack.Add(new TextBlock("∞", 76, Theme.Line, Theme.W.Light, true), 0);
            stack.Add(new TextBlock(p.SocialBlock ? "רשתות ויוטיוב חסומים כבר עכשיו" : "המחשב פתוח לגמרי", 14, Theme.Muted, Theme.W.Regular, true), 4);
        }

        string limitVal = p.LimitMs == Policy.None ? "לא נקבע" : Fmt.Hm(p.LimitMs);
        if (p.PendingLimit() != null) limitVal += " · שינוי ממתין";
        stack.Add(new RowBlock("שאלה בכל כניסה", p.CheckIn ? (p.PendingCheckInOff() != null ? "פועלת · תכובה" : "פועלת") : "כבויה",
            p.CheckIn ? Theme.Muted : Theme.Brick, () => Go(Page.CheckIn)), 24);
        stack.Add(new RowBlock("זמן מסך ליום", limitVal, Theme.Muted, () => Go(Page.Limit)));
        stack.Add(new RowBlock("רשתות ויוטיוב", p.SocialBlock ? "חסומים" : "פתוחים", Theme.Muted, () => Go(Page.Social)));
        int n = p.ExtraAllowed.Count;
        stack.Add(new RowBlock("תמיד פתוח", n == 1 ? "אפליקציה אחת" : n + " אפליקציות", Theme.Muted, () => Go(Page.Allow)));
        if (!ProtectionOk && !m.Preview)
            stack.Add(new RowBlock("הפעלה עם Windows", "להפעיל", Theme.Brick, () => FixProtection?.Invoke()));

        var today = m.Preview ? PreviewSessions : SessionLog.Today();
        if (today.Count > 0)
        {
            stack.Add(new TextBlock("היום", 16, Theme.Ink, Theme.W.Medium), 22);
            foreach (var (time, minutes, what, why) in today.TakeLast(6).Reverse())
                stack.Add(new TextBlock($"{time} · {Fmt.Words(minutes * MIN)} · {what} – {why}", 14, Theme.Ink2), 6);
        }
    }

    /// <summary>Sample diary for screenshots.</summary>
    public System.Collections.Generic.List<(string, long, string, string)> PreviewSessions = new();

    // ---------------- check-in ----------------

    private void BuildCheckIn(long now)
    {
        var p = m.P;
        stack.Add(new SubHeaderBlock("שאלה בכל כניסה", () => Go(Page.Home)));
        stack.Add(new TextBlock(p.CheckIn ? "פועלת" : "כבויה", 26, p.CheckIn ? Theme.Pine : Theme.Brick, Theme.W.Medium), 4);
        stack.Add(new TextBlock(
            "בכל הדלקה של המחשב, ובכל חזרה אחרי 10 דקות ומעלה של מחשב נעול, עוגן שואל: מה אתה הולך לעשות, כמה זמן ולמה. עד שעונים – שום דבר לא פתוח. כשהזמן שקבעת נגמר המחשב ננעל, ובכניסה הבאה הוא שואל שוב.",
            14, Theme.Ink2), 8);
        var pend = p.PendingCheckInOff();
        if (pend != null)
            stack.Add(new NoteBlock("תכובה " + m.When(pend.At), Theme.PineSoft, Theme.PineDark, "בטל",
                () => { m.Mutate(t => p.RequestCheckIn(true, t)); Toast("נשארת פועלת"); }), 16);
        else if (p.CheckIn)
            stack.Add(new ButtonBlock("לכבות (בעוד 24 שעות)", BtnStyle.Plain, () =>
            {
                if (!ConfirmForm.Ask(this, "לכבות את השאלה?", "הכיבוי ייכנס לתוקף רק בעוד 24 שעות, ואפשר לבטל את הבקשה עד אז.")) return;
                m.Mutate(t => p.RequestCheckIn(false, t));
                Toast("נרשם – תכובה בעוד 24 שעות");
            }), 16);
        else
            stack.Add(new ButtonBlock("להפעיל – מיד", BtnStyle.Primary, () => { m.Mutate(t => p.RequestCheckIn(true, t)); Toast("פועלת"); }), 16);
    }

    // ---------------- limit ----------------

    private void BuildLimit(long now)
    {
        var p = m.P;
        stack.Add(new SubHeaderBlock("זמן מסך ליום", () => Go(Page.Home)));
        if (draft < 0) draft = p.LimitMs != Policy.None ? p.LimitMs : 2 * 60 * MIN;

        stack.Add(new StepperBlock(Fmt.Hm(draft), Fmt.Words(draft) + " של שימוש ביום",
            onMinus: () => { draft = Math.Max(STEP, draft - STEP); Render(); },
            onPlus: () => { draft = Math.Min(16 * 60 * MIN, draft + STEP); Render(); },
            canMinus: draft > STEP, canPlus: draft < 16 * 60 * MIN), 8);

        bool committed = p.Committed(now);
        bool looser = committed && draft > p.LimitMs;
        bool same = committed && draft == p.LimitMs;
        if (!same)
        {
            stack.Add(looser
                ? new ButtonBlock("הוסף זמן · נכנס בעוד 24 שעות", BtnStyle.Ghost, () => ConfirmLimit(draft))
                : new ButtonBlock(p.LimitMs == Policy.None ? "קבע זמן מסך" : "עדכן", BtnStyle.Primary, () => ConfirmLimit(draft)), 16);
        }

        var pend = p.PendingLimit();
        if (pend != null)
        {
            string what = pend.Value == Policy.None ? "ביטול זמן המסך" : Fmt.Hm(pend.Value) + " ביום";
            stack.Add(new NoteBlock(what + " ייכנס לתוקף " + m.When(pend.At), Theme.PineSoft, Theme.PineDark, "בטל",
                () => { m.Mutate(t => { p.CancelPending(Policy.ChLimit, null); return 0; }); Toast("הבקשה בוטלה"); }), 12);
        }
        else if (committed)
        {
            stack.Add(new ButtonBlock("ביטול זמן המסך", BtnStyle.Plain, () => ConfirmLimit(Policy.None)), 8);
        }

        stack.Add(new TextBlock(
            "הזמן יורד רק כשאתה משתמש במחשב באפליקציות רגילות. האפליקציות שתמיד פתוחות לא נספרות. כשהזמן נגמר – רק הן פתוחות, עד חצות.\n\nפחות זמן נכנס מיד. יותר זמן או ביטול – רק אחרי 24 שעות.",
            14, Theme.Muted), 16);
    }

    private void ConfirmLimit(long value)
    {
        var p = m.P;
        long now = m.Now();
        string title, msg;
        if (value == Policy.None)
        {
            title = "לבטל את זמן המסך?";
            msg = "הביטול ייכנס לתוקף רק בעוד 24 שעות. עד אז הזמן הנוכחי ממשיך.";
        }
        else if (p.LimitMs == Policy.None || !p.Committed(now) || value <= p.LimitMs)
        {
            title = Fmt.Words(value) + " של שימוש ביום";
            msg = "מתחיל מהיום. אחרי האישור לא תוכל להוסיף זמן או לבטל במשך 24 שעות.";
        }
        else
        {
            title = "להעלות ל-" + Fmt.Words(value) + "?";
            msg = "התוספת תיכנס לתוקף רק בעוד 24 שעות. אפשר לבטל את הבקשה בכל רגע.";
        }
        if (!ConfirmForm.Ask(this, title, msg)) return;
        bool applied = m.Mutate(t => p.RequestLimit(value, t));
        draft = -1;
        Go(Page.Home);
        Toast(applied ? "נקבע" : "נרשם – ייכנס לתוקף בעוד 24 שעות");
    }

    // ---------------- social ----------------

    private void BuildSocial(long now)
    {
        var p = m.P;
        stack.Add(new SubHeaderBlock("רשתות ויוטיוב", () => Go(Page.Home)));
        stack.Add(new TextBlock(p.SocialBlock ? "חסומים – תמיד" : "פתוחים", 26, p.SocialBlock ? Theme.Pine : Theme.Brick, Theme.W.Medium), 4);
        stack.Add(new TextBlock(
            "אינסטגרם, טיקטוק, יוטיוב, פייסבוק, X, סנאפצ׳ט, רדיט, נטפליקס וטוויץ׳ – גם האתרים בכל דפדפן וגם האפליקציות. לשונית של אתר חסום נסגרת מיד. החסימה פועלת כל הזמן, גם בלי מגבלה יומית.",
            14, Theme.Ink2), 8);

        var pend = p.PendingSocialOff();
        if (pend != null)
        {
            stack.Add(new NoteBlock("תכובה " + m.When(pend.At), Theme.PineSoft, Theme.PineDark, "בטל",
                () => { m.Mutate(t => p.RequestSocialBlock(true, t)); Toast("נשאר חסום"); }), 16);
        }
        else if (p.SocialBlock)
        {
            stack.Add(new ButtonBlock("לכבות (בעוד 24 שעות)", BtnStyle.Plain, () =>
            {
                if (!ConfirmForm.Ask(this, "לכבות את החסימה?", "הכיבוי ייכנס לתוקף רק בעוד 24 שעות. עד אז הכל נשאר חסום, ואפשר לבטל את הבקשה.")) return;
                m.Mutate(t => p.RequestSocialBlock(false, t));
                Toast("נרשם – ייכבה בעוד 24 שעות");
            }), 16);
        }
        else
        {
            stack.Add(new ButtonBlock("לחסום שוב – מיד", BtnStyle.Primary, () => { m.Mutate(t => p.RequestSocialBlock(true, t)); Toast("נחסם"); }), 16);
        }
    }

    // ---------------- always open ----------------

    private void BuildAllow(long now)
    {
        var p = m.P;
        stack.Add(new SubHeaderBlock("תמיד פתוח", () => Go(Page.Home)));
        stack.Add(new TextBlock("האפליקציות האלה לא נספרות בזמן המסך ונשארות פתוחות גם כשהזמן נגמר.", 14, Theme.Muted), 2);
        stack.Add(new TextBlock("שולחן העבודה · סייר הקבצים · הגדרות · קישור לטלפון", 15, Theme.Ink), 10);

        foreach (var pkg in p.ExtraAllowed.OrderBy(m.DisplayName, StringComparer.CurrentCultureIgnoreCase))
        {
            string k = pkg;
            stack.Add(new AppRowBlock(m.DisplayName(k), null, "הסר", () => { m.Mutate(t => { p.Disallow(k); return 0; }); Toast("הוסרה"); }), 4);
        }
        foreach (var ch in p.Pending.Where(c => c.Type == Policy.ChAllow))
        {
            string k = ch.Pkg;
            stack.Add(new AppRowBlock(m.DisplayName(k), "תתווסף " + m.When(ch.At), "בטל",
                () => m.Mutate(t => { p.CancelPending(Policy.ChAllow, k); return 0; })), 4);
        }

        stack.Add(new ButtonBlock("+ הוספת אפליקציה", BtnStyle.Ghost, AddApp), 14);
        stack.Add(new TextBlock(p.Committed(now) ? "הוספה נכנסת לתוקף אחרי 24 שעות. הסרה – מיד." : "בלי מגבלה פעילה, הוספה נכנסת מיד.", 13, Theme.Muted), 10);
    }

    private void AddApp()
    {
        var picked = AppPickerForm.Pick(this, m);
        if (picked == null) return;
        m.RememberName(picked.Value.pkg, picked.Value.name);
        bool now = m.Mutate(t => m.P.RequestAllow(picked.Value.pkg, t));
        Toast(now ? "נוספה" : "תתווסף בעוד 24 שעות");
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            refresh.Dispose();
            toastTimer.Dispose();
        }
        base.Dispose(disposing);
    }
}
