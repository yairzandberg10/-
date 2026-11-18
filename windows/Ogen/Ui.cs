using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Ogen;

/// <summary>Palette, fonts and the painted building blocks every screen is made of. Same look as the Android app.</summary>
internal static class Theme
{
    public static readonly Color Paper = Hex(0xF2EEE5), Card = Hex(0xFBF9F4), Ink = Hex(0x1E1C19), Ink2 = Hex(0x4A463F),
        Muted = Hex(0x857E73), Line = Hex(0xE2DCCF), Pine = Hex(0x2D5B4C), PineDark = Hex(0x1F4236),
        PineSoft = Hex(0xDDE8E2), Brick = Hex(0xA4442C), BrickSoft = Hex(0xF3E2DA), Night = Hex(0x1E1C19),
        Night2 = Hex(0x2B2824), OnNight = Hex(0xF2EEE5), OnNightMuted = Hex(0xA9A195), Hover = Hex(0xEAE5DA);

    private static Color Hex(int rgb) => Color.FromArgb(255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

    public enum W { Light, Regular, Medium }

    private static readonly Dictionary<(float, W), Font> Fonts = new();

    /// <summary>A font sized in device pixels (callers pass dp × scale).</summary>
    public static Font F(float px, W w = W.Regular)
    {
        px = (float)Math.Round(px, 1);
        if (Fonts.TryGetValue((px, w), out var f)) return f;
        string family = w switch { W.Light => "Segoe UI Light", W.Medium => "Segoe UI Semibold", _ => "Segoe UI" };
        f = new Font(family, px, FontStyle.Regular, GraphicsUnit.Pixel);
        Fonts[(px, w)] = f;
        return f;
    }

    public static GraphicsPath Round(RectangleF r, float radius)
    {
        var p = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public const TextFormatFlags Rtl = TextFormatFlags.RightToLeft | TextFormatFlags.Right | TextFormatFlags.NoPrefix;
    public const TextFormatFlags Center = TextFormatFlags.RightToLeft | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPrefix;
}

/// <summary>Base for painted blocks: knows its scale and how tall it wants to be at a given width.</summary>
internal abstract class Block : Control
{
    protected float S = 1f;
    public int Gap; // space above, in dp

    protected Block()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint
                 | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    public void SetScale(float s) { S = s; Invalidate(); }
    protected int D(float dp) => (int)Math.Round(dp * S);
    public abstract int Measure(int width);

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        Draw(e.Graphics);
    }

    protected abstract void Draw(Graphics g);
}

/// <summary>Vertical stack of blocks with side padding; scrolls when taller than the window.</summary>
internal sealed class Stack : Panel
{
    public float S = 1f;
    public int PadX = 24, PadTop = 12, PadBottom = 20;

    public Stack()
    {
        AutoScroll = true;
        DoubleBuffered = true;
        BackColor = Theme.Paper;
    }

    public T Add<T>(T b, int gapDp = 0) where T : Block
    {
        b.Gap = gapDp;
        b.SetScale(S);
        Controls.Add(b);
        return b;
    }

    public void Relayout()
    {
        SuspendLayout();
        int sx = AutoScrollPosition.X, sy = AutoScrollPosition.Y;
        int pad = (int)(PadX * S);
        int y = (int)(PadTop * S);
        int w = ClientSize.Width - 2 * pad;
        foreach (Control c in Controls)
        {
            if (c is not Block b) continue;   // not .Visible: false until the form itself is shown
            y += (int)(b.Gap * S);
            int h = b.Measure(w);
            b.SetBounds(pad + sx, y + sy, w, h);
            y += h;
        }
        AutoScrollMinSize = new Size(0, y + (int)(PadBottom * S));
        ResumeLayout(false);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Relayout();
    }
}

internal sealed class TextBlock : Block
{
    private readonly float size;
    private readonly Theme.W weight;
    public Color Color;
    public bool Centered;

    public TextBlock(string text, float sizeDp, Color color, Theme.W weight = Theme.W.Regular, bool centered = false)
    {
        Text = text;
        size = sizeDp;
        Color = color;
        this.weight = weight;
        Centered = centered;
    }

    private TextFormatFlags Flags => (Centered ? Theme.Center : Theme.Rtl) | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;

    public override int Measure(int width) =>
        TextRenderer.MeasureText(Text, Theme.F(size * S, weight), new Size(width, int.MaxValue), Flags).Height;

    protected override void Draw(Graphics g) =>
        TextRenderer.DrawText(g, Text, Theme.F(size * S, weight), ClientRectangle, Color, Flags);
}

/// <summary>Progress bar: filled from the right (RTL), like the Android hero.</summary>
internal sealed class BarBlock : Block
{
    public float Fraction;
    public Color Fill;

    public BarBlock(float fraction, Color fill) { Fraction = fraction; Fill = fill; }

    public override int Measure(int width) => D(6);

    protected override void Draw(Graphics g)
    {
        var r = new RectangleF(0, 0, Width - 1, Height - 1);
        using (var bg = new SolidBrush(Theme.Line)) using (var p = Theme.Round(r, r.Height / 2)) g.FillPath(bg, p);
        float f = Math.Clamp(Fraction, 0, 1);
        if (f <= 0) return;
        var fr = new RectangleF(r.Right - r.Width * f, 0, r.Width * f, r.Height);
        using var fb = new SolidBrush(Fill);
        using var fp = Theme.Round(fr, r.Height / 2);
        g.FillPath(fb, fp);
    }
}

/// <summary>Clickable block with hover, focus and keyboard support.</summary>
internal abstract class Clickable : Block
{
    protected bool Hot, Down;

    protected Clickable()
    {
        SetStyle(ControlStyles.Selectable, true);
        TabStop = true;
        Cursor = Cursors.Hand;
    }

    public bool Enabled2 { get; set; } = true;

    protected override void OnMouseEnter(EventArgs e) { Hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { Hot = false; Down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { Down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { Down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override bool IsInputKey(Keys k) => k is Keys.Enter or Keys.Space || base.IsInputKey(k);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode is Keys.Enter or Keys.Space) { OnClick(EventArgs.Empty); e.Handled = true; }
        base.OnKeyDown(e);
    }

    protected void FocusRing(Graphics g, RectangleF r, float radius)
    {
        if (!Focused || !ShowFocusCues) return;
        using var pen = new Pen(Theme.Pine, Math.Max(1.5f, 2 * S));
        using var p = Theme.Round(RectangleF.Inflate(r, -1, -1), radius);
        g.DrawPath(pen, p);
    }
}

internal enum BtnStyle { Primary, Ghost, Danger, Night, NightGhost, Plain }

internal sealed class ButtonBlock : Clickable
{
    public BtnStyle Style;
    private readonly float size;

    public ButtonBlock(string text, BtnStyle style, Action onClick, float sizeDp = 15)
    {
        Text = text;
        Style = style;
        size = sizeDp;
        Click += (_, _) => { if (Enabled2) onClick(); };
        AccessibleRole = AccessibleRole.PushButton;
        AccessibleName = text;
    }

    public override int Measure(int width) => D(46);

    protected override void Draw(Graphics g)
    {
        var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        float rad = D(12);
        (Color bg, Color fg, Color? border) = Style switch
        {
            BtnStyle.Primary => (Down ? Theme.PineDark : Hot ? Theme.PineDark : Theme.Pine, Theme.Paper, (Color?)null),
            BtnStyle.Ghost => (Hot ? Theme.Hover : Theme.Card, Theme.Pine, Theme.Line),
            BtnStyle.Danger => (Hot ? Theme.BrickSoft : Theme.Card, Theme.Brick, Theme.Line),
            BtnStyle.Night => (Hot ? Color.FromArgb(0x3A, 0x36, 0x30) : Theme.Night2, Theme.OnNight, null),
            BtnStyle.NightGhost => (Hot ? Theme.Night2 : Theme.Night, Theme.OnNightMuted, (Color?)Theme.Night2),
            _ => (Hot ? Theme.Hover : Theme.Paper, Theme.Muted, null),
        };
        using (var b = new SolidBrush(bg)) using (var p = Theme.Round(r, rad)) g.FillPath(b, p);
        if (border is Color bc) { using var pen = new Pen(bc, Math.Max(1, S)); using var p = Theme.Round(r, rad); g.DrawPath(pen, p); }
        TextRenderer.DrawText(g, Text, Theme.F(size * S, Theme.W.Medium), Rectangle.Round(r), Enabled2 ? fg : Theme.Muted,
            Theme.Center | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        FocusRing(g, r, rad);
    }
}

/// <summary>A settings row: title on the right, value and chevron on the left, hairline below.</summary>
internal sealed class RowBlock : Clickable
{
    public string Value;
    public Color ValueColor;

    public RowBlock(string title, string value, Color valueColor, Action onClick)
    {
        Text = title;
        Value = value;
        ValueColor = valueColor;
        Click += (_, _) => onClick();
        AccessibleRole = AccessibleRole.PushButton;
        AccessibleName = title + " " + value;
    }

    public override int Measure(int width) => D(56);

    protected override void Draw(Graphics g)
    {
        var r = ClientRectangle;
        if (Hot) using (var b = new SolidBrush(Theme.Hover)) g.FillRectangle(b, r);
        using (var pen = new Pen(Theme.Line, Math.Max(1, S))) g.DrawLine(pen, 0, r.Bottom - 1, r.Right, r.Bottom - 1);
        int pad = D(6);
        var text = new Rectangle(pad, 0, r.Width - 2 * pad, r.Height);
        TextRenderer.DrawText(g, Text, Theme.F(17 * S), text, Theme.Ink, Theme.Rtl | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        var chev = new Rectangle(pad, 0, D(14), r.Height);
        TextRenderer.DrawText(g, "‹", Theme.F(20 * S, Theme.W.Light), chev, Theme.Muted, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        var val = new Rectangle(pad + D(20), 0, r.Width / 2, r.Height);
        TextRenderer.DrawText(g, Value, Theme.F(15 * S), val, ValueColor,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.RightToLeft | TextFormatFlags.NoPrefix);
        FocusRing(g, new RectangleF(0, 0, r.Width, r.Height - 1), D(6));
    }
}

/// <summary>Rounded note box; optional action link on the left ("בטל").</summary>
internal sealed class NoteBlock : Clickable
{
    private readonly Color bg, fg;
    private readonly string? action;
    private readonly Action? onAction;

    public NoteBlock(string text, Color bg, Color fg, string? action = null, Action? onAction = null)
    {
        Text = text;
        this.bg = bg;
        this.fg = fg;
        this.action = action;
        this.onAction = onAction;
        if (onAction == null) { TabStop = false; Cursor = Cursors.Default; }
        else Click += (_, _) => onAction();
        AccessibleName = text + (action != null ? " " + action : "");
    }

    private int ActionWidth => action == null ? 0 : D(64);

    private const TextFormatFlags Flags = Theme.Rtl | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl;

    public override int Measure(int width)
    {
        int inner = width - D(32) - ActionWidth;
        return TextRenderer.MeasureText(Text, Theme.F(14 * S), new Size(inner, int.MaxValue), Flags).Height + D(28);
    }

    protected override void Draw(Graphics g)
    {
        var r = new RectangleF(0, 0, Width - 1, Height - 1);
        using (var b = new SolidBrush(bg)) using (var p = Theme.Round(r, D(12))) g.FillPath(b, p);
        var text = new Rectangle(D(16) + ActionWidth, D(14), Width - D(32) - ActionWidth, Height - D(28));
        TextRenderer.DrawText(g, Text, Theme.F(14 * S), text, fg, Flags);
        if (action != null)
        {
            var a = new Rectangle(D(8), 0, ActionWidth, Height);
            TextRenderer.DrawText(g, action, Theme.F(15 * S, Theme.W.Medium), a, Hot ? Theme.PineDark : Theme.Brick,
                Theme.Center | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            FocusRing(g, r, D(12));
        }
    }
}

/// <summary>Home header: anchor + "עוגן" on the right, status dot on the left.</summary>
internal sealed class HeaderBlock : Block
{
    public string Status;
    public bool Ok;

    public HeaderBlock(string status, bool ok) { Status = status; Ok = ok; }

    public override int Measure(int width) => D(44);

    protected override void Draw(Graphics g)
    {
        int h = Height;
        float icon = D(24);
        AnchorMark.Draw(g, new RectangleF(Width - icon, (h - icon) / 2, icon, icon), Theme.Ink, 1.8f * S);
        var name = new Rectangle(0, 0, Width - (int)icon - D(10), h);
        TextRenderer.DrawText(g, "עוגן", Theme.F(19 * S, Theme.W.Medium), name, Theme.Ink, Theme.Rtl | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        float dot = D(8);
        using (var b = new SolidBrush(Ok ? Theme.Pine : Theme.Brick)) g.FillEllipse(b, 0, (h - dot) / 2, dot, dot);
        var st = new Rectangle((int)dot + D(6), 0, Width / 2, h);
        TextRenderer.DrawText(g, Status, Theme.F(14 * S, Theme.W.Medium), st, Ok ? Theme.Pine : Theme.Brick,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.RightToLeft);
    }
}

/// <summary>Sub-page header: back arrow on the right and the page title.</summary>
internal sealed class SubHeaderBlock : Clickable
{
    public SubHeaderBlock(string title, Action back)
    {
        Text = title;
        Click += (_, _) => back();
        AccessibleName = "חזרה";
        AccessibleRole = AccessibleRole.PushButton;
    }

    public override int Measure(int width) => D(48);

    protected override void Draw(Graphics g)
    {
        var arrow = new Rectangle(Width - D(40), 0, D(40), Height);
        if (Hot) using (var b = new SolidBrush(Theme.Hover)) using (var p = Theme.Round(arrow, D(10))) g.FillPath(b, p);
        TextRenderer.DrawText(g, "→", Theme.F(22 * S), arrow, Theme.Ink, Theme.Center | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        var t = new Rectangle(0, 0, Width - D(50), Height);
        TextRenderer.DrawText(g, Text, Theme.F(20 * S, Theme.W.Medium), t, Theme.Ink, Theme.Rtl | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        FocusRing(g, arrow, D(10));
    }
}

/// <summary>"−  1:30  +" stepper used on the limit page.</summary>
internal sealed class StepperBlock : Block
{
    public string Value;
    public string Caption;
    private readonly ButtonBlock minus, plus;

    public StepperBlock(string value, string caption, Action onMinus, Action onPlus, bool canMinus, bool canPlus)
    {
        Value = value;
        Caption = caption;
        // RTL: "+" sits on the right, "−" on the left
        plus = new ButtonBlock("+", BtnStyle.Ghost, onPlus, 24) { Enabled2 = canPlus, AccessibleName = "יותר זמן" };
        minus = new ButtonBlock("−", BtnStyle.Ghost, onMinus, 24) { Enabled2 = canMinus, AccessibleName = "פחות זמן" };
        Controls.Add(plus);
        Controls.Add(minus);
    }

    public override int Measure(int width) => D(112);

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        int b = D(56);
        plus.SetScale(S);
        minus.SetScale(S);
        plus.SetBounds(Width - b, D(20), b, b);
        minus.SetBounds(0, D(20), b, b);
    }

    protected override void Draw(Graphics g)
    {
        var mid = new Rectangle(D(60), 0, Width - D(120), D(84));
        TextRenderer.DrawText(g, Value, Theme.F(56 * S, Theme.W.Light), mid, Theme.Ink,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        var cap = new Rectangle(0, D(84), Width, D(26));
        TextRenderer.DrawText(g, Caption, Theme.F(14 * S), cap, Theme.Muted, Theme.Center | TextFormatFlags.SingleLine);
    }
}

/// <summary>Row in the always-open list: app name (+ sub text) on the right, action link on the left.</summary>
internal sealed class AppRowBlock : Clickable
{
    private readonly string? sub;
    private readonly string action;

    public AppRowBlock(string name, string? sub, string action, Action onAction)
    {
        Text = name;
        this.sub = sub;
        this.action = action;
        Click += (_, _) => onAction();
        AccessibleName = name + " " + action;
    }

    public override int Measure(int width) => D(sub == null ? 50 : 62);

    protected override void Draw(Graphics g)
    {
        var r = ClientRectangle;
        if (Hot) using (var b = new SolidBrush(Theme.Hover)) g.FillRectangle(b, r);
        using (var pen = new Pen(Theme.Line, Math.Max(1, S))) g.DrawLine(pen, 0, r.Bottom - 1, r.Right, r.Bottom - 1);
        int aw = D(64);
        var name = new Rectangle(aw, sub == null ? 0 : D(8), r.Width - aw - D(6), sub == null ? r.Height : D(26));
        TextRenderer.DrawText(g, Text, Theme.F(16 * S), name, Theme.Ink, Theme.Rtl | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        if (sub != null)
        {
            var s = new Rectangle(aw, D(32), r.Width - aw - D(6), D(22));
            TextRenderer.DrawText(g, sub, Theme.F(13 * S), s, Theme.Pine, Theme.Rtl | TextFormatFlags.SingleLine);
        }
        var a = new Rectangle(0, 0, aw, r.Height);
        TextRenderer.DrawText(g, action, Theme.F(15 * S, Theme.W.Medium), a, Theme.Brick, Theme.Center | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        FocusRing(g, new RectangleF(0, 0, r.Width, r.Height - 1), D(6));
    }
}

/// <summary>Empty vertical space or a centered anchor.</summary>
internal sealed class AnchorBlock : Block
{
    private readonly float size;
    private readonly Color color;

    public AnchorBlock(float sizeDp, Color color) { size = sizeDp; this.color = color; }

    public override int Measure(int width) => D(size);

    protected override void Draw(Graphics g)
    {
        float s = D(size);
        AnchorMark.Draw(g, new RectangleF((Width - s) / 2, 0, s, s), color, s / 24f * 1.6f);
    }
}
