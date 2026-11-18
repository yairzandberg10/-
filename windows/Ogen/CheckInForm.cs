using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>A text field inside the painted layout (rounded dark box, RTL).</summary>
internal sealed class FieldBlock : Block
{
    public readonly TextBox Box = new();

    public FieldBlock(string placeholder)
    {
        Box.BorderStyle = BorderStyle.None;
        Box.RightToLeft = RightToLeft.Yes;
        Box.PlaceholderText = placeholder;
        Box.BackColor = Theme.Night2;
        Box.ForeColor = Theme.OnNight;
        Box.MaxLength = 120;
        Box.AccessibleName = placeholder;
        Controls.Add(Box);
    }

    public override int Measure(int width) => D(50);

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        Box.Font = Theme.F(18 * S);
        int h = Box.PreferredHeight;
        Box.SetBounds(D(16), (Height - h) / 2, Width - D(32), h);
    }

    protected override void Draw(Graphics g)
    {
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (var b = new SolidBrush(Theme.Night2)) using (var p = Theme.Round(r, D(12))) g.FillPath(b, p);
        using var pen = new Pen(Box.Focused ? Theme.OnNightMuted : Color.FromArgb(0x3A, 0x36, 0x30), Math.Max(1, S));
        using var pp = Theme.Round(r, D(12));
        g.DrawPath(pen, pp);
    }
}

/// <summary>Duration choices, wrapped right-to-left.</summary>
internal sealed class ChipsBlock : Block
{
    private readonly List<(ButtonBlock btn, long ms)> chips = new();
    public long Selected { get; private set; }
    public event Action? Changed;

    public ChipsBlock(IEnumerable<(string label, long ms, bool enabled)> options)
    {
        foreach (var (label, ms, enabled) in options)
        {
            long v = ms;
            ButtonBlock? b = null;
            b = new ButtonBlock(label, BtnStyle.NightGhost, () => Select(v), 15) { Enabled2 = enabled };
            chips.Add((b, ms));
            Controls.Add(b);
        }
    }

    public void Select(long ms)
    {
        Selected = ms;
        foreach (var (b, v) in chips) { b.Style = v == ms ? BtnStyle.Primary : BtnStyle.NightGhost; b.Invalidate(); }
        Changed?.Invoke();
    }

    private int ChipW => D(108);
    private int Cols(int width) => Math.Max(1, (width + D(8)) / (ChipW + D(8)));

    public override int Measure(int width)
    {
        int rows = (chips.Count + Cols(width) - 1) / Cols(width);
        return rows * D(46) + (rows - 1) * D(8);
    }

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        int cols = Cols(Width);
        int w = (Width - (cols - 1) * D(8)) / cols;
        for (int i = 0; i < chips.Count; i++)
        {
            int r = i / cols, c = i % cols;
            chips[i].btn.SetScale(S);
            chips[i].btn.SetBounds(Width - (c + 1) * w - c * D(8), r * D(54), w, D(46));
        }
    }

    protected override void Draw(Graphics g) { }
}

/// <summary>
/// Full-screen question before the computer can be used: what are you going to do, for how
/// long, and why. Answering starts a session; when it runs out Windows is locked and it asks again.
/// </summary>
internal sealed class CheckInForm : Form
{
    private const long MIN = 60_000L;
    private readonly AppModel m;
    private readonly Stack stack = new() { PadX = 0, PadTop = 0, PadBottom = 0 };
    private readonly List<Form> others = new();
    private FieldBlock? what, why;
    private ChipsBlock? chips;
    private TextBlock? error;
    private string? banner;

    public CheckInForm(AppModel model)
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
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW: not in Alt+Tab
            return cp;
        }
    }

    // Alt+F4 does nothing here
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
        base.OnFormClosing(e);
    }

    /// <summary>Show (or bring back) the question. Idempotent: keeps what was already typed.</summary>
    public void ShowNow(Policy p, string? message)
    {
        var screen = Screen.PrimaryScreen ?? Screen.AllScreens[0];
        bool fresh = !Visible || message != banner;
        banner = message;
        if (fresh)
        {
            Bounds = screen.Bounds;
            Build(p);
            CoverOtherScreens(screen);
        }
        if (!Visible) Show();
        TopMost = true;
        if (Native.GetForegroundWindow() != Handle) Native.ForceForeground(Handle);
        if (what != null && !what.Box.Focused && !(why?.Box.Focused ?? false) && fresh) what.Box.Focus();
    }

    public new void Hide()
    {
        foreach (var f in others) f.Dispose();
        others.Clear();
        base.Hide();
    }

    private void CoverOtherScreens(Screen main)
    {
        foreach (var f in others) f.Dispose();
        others.Clear();
        foreach (var s in Screen.AllScreens.Where(s => !s.Primary))
        {
            var f = new Form
            {
                FormBorderStyle = FormBorderStyle.None, ShowInTaskbar = false, TopMost = true,
                StartPosition = FormStartPosition.Manual, Bounds = s.Bounds, BackColor = Theme.Night,
            };
            f.Show();
            others.Add(f);
        }
    }

    private void Build(Policy p)
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
        if (banner != null) stack.Add(new TextBlock(banner, 17, Color.FromArgb(0xE0, 0x8A, 0x70), Theme.W.Medium, true), 14);
        stack.Add(new TextBlock("מה אתה הולך לעשות עכשיו?", 30, Theme.OnNight, Theme.W.Medium, true), 14);
        what = stack.Add(new FieldBlock("למשל: שיעורי בית במתמטיקה"), 14);

        stack.Add(new TextBlock("כמה זמן?", 20, Theme.OnNight, Theme.W.Medium, true), 22);
        long left = p.LimitMs == Policy.None ? long.MaxValue : p.RemainingMs();
        var opts = new (string, long)[]
        {
            ("15 דק׳", 15 * MIN), ("30 דק׳", 30 * MIN), ("45 דק׳", 45 * MIN), ("שעה", 60 * MIN),
            ("שעה וחצי", 90 * MIN), ("שעתיים", 120 * MIN), ("3 שעות", 180 * MIN),
        };
        chips = stack.Add(new ChipsBlock(opts.Select(o => (o.Item1, o.Item2, o.Item2 <= Math.Max(left, 15 * MIN)))), 10);
        if (left != long.MaxValue)
            stack.Add(new TextBlock("נשאר לך היום " + Fmt.Words(left), 14, Theme.OnNightMuted, Theme.W.Regular, true), 8);

        stack.Add(new TextBlock("למה?", 20, Theme.OnNight, Theme.W.Medium, true), 22);
        why = stack.Add(new FieldBlock("למשל: יש לי מבחן ביום ראשון"), 10);

        error = stack.Add(new TextBlock("", 15, Color.FromArgb(0xE0, 0x8A, 0x70), Theme.W.Medium, true), 12);
        stack.Add(new ButtonBlock("להתחיל", BtnStyle.Primary, Start, 17), 8);
        stack.Add(new ButtonBlock("לנעול את המחשב", BtnStyle.NightGhost, () => Native.LockWorkStation()), 10);
        stack.Add(new TextBlock("כשהזמן נגמר המחשב ננעל, ובפעם הבאה שתיכנס עוגן ישאל שוב.", 13, Theme.OnNightMuted, Theme.W.Regular, true), 14);

        int w = Math.Min((int)(520 * s), ClientSize.Width - (int)(32 * s));
        int h = 0;
        foreach (Block b in stack.Controls) h += b.Measure(w) + (int)(b.Gap * s);
        stack.SetBounds((ClientSize.Width - w) / 2, Math.Max(0, (ClientSize.Height - h) / 2), w, h);
        stack.AutoScroll = h > ClientSize.Height;
        stack.ResumeLayout(false);
        stack.Relayout();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Enter)
        {
            if (what?.Box.Focused == true) why?.Box.Focus();
            else Start();
            e.Handled = e.SuppressKeyPress = true;
        }
        base.OnKeyDown(e);
    }

    private void Start()
    {
        string w = what?.Box.Text.Trim() ?? "", y = why?.Box.Text.Trim() ?? "";
        long d = chips?.Selected ?? 0;
        string? problem = w.Length < 2 ? "כתוב מה אתה הולך לעשות" : d == 0 ? "בחר כמה זמן" : y.Length < 2 ? "כתוב למה" : null;
        if (problem != null)
        {
            if (error != null) { error.Text = problem; error.Invalidate(); }
            (w.Length < 2 ? what : y.Length < 2 && d != 0 ? why : null)?.Box.Focus();
            return;
        }
        long boot = 0;
        m.Mutate(now =>
        {
            boot = now - Environment.TickCount64;
            m.P.StartSession(d, w, y, boot, now);
            return 0;
        });
        SessionLog.Add(d, w, y);
        Log.Write($"session started: {d / MIN} min \"{w}\"");
        banner = null;
        Hide();
    }
}

/// <summary>A small diary of sessions (%LOCALAPPDATA%\Ogen\sessions.txt), shown on the home screen.</summary>
internal static class SessionLog
{
    private static string File => Path.Combine(Store.DataDir, "sessions.txt");

    public static void Add(long ms, string what, string why)
    {
        try
        {
            Directory.CreateDirectory(Store.DataDir);
            System.IO.File.AppendAllText(File, $"{DateTime.Now:yyyy-MM-dd HH:mm}\t{ms / 60_000}\t{what.Replace('\t', ' ')}\t{why.Replace('\t', ' ')}{Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public static List<(string time, long minutes, string what, string why)> Today()
    {
        var list = new List<(string, long, string, string)>();
        try
        {
            if (!System.IO.File.Exists(File)) return list;
            string today = DateTime.Now.ToString("yyyy-MM-dd");
            foreach (var line in System.IO.File.ReadLines(File))
            {
                var f = line.Split('\t');
                if (f.Length < 4 || !f[0].StartsWith(today, StringComparison.Ordinal)) continue;
                list.Add((f[0][11..], long.TryParse(f[1], out var mm) ? mm : 0, f[2], f[3]));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return list;
    }
}
