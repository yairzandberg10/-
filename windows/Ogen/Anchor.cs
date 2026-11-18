using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Ogen;

/// <summary>The anchor mark, from the Android vector (24×24 viewport).</summary>
internal static class AnchorMark
{
    public static void Draw(Graphics g, RectangleF box, Color color, float stroke)
    {
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TranslateTransform(box.X, box.Y);
        float k = Math.Min(box.Width, box.Height) / 24f;
        g.ScaleTransform(k, k);
        using var pen = new Pen(color, stroke / k) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        g.DrawEllipse(pen, 10f, 3.2f, 4f, 4f);
        g.DrawLine(pen, 12f, 7.2f, 12f, 20.2f);
        g.DrawLine(pen, 8.3f, 10.4f, 15.7f, 10.4f);
        g.DrawBezier(pen, 5f, 13.2f, 5f, 17.2f, 8.1f, 20.2f, 12f, 20.2f);
        g.DrawBezier(pen, 12f, 20.2f, 15.9f, 20.2f, 19f, 17.2f, 19f, 13.2f);
        g.DrawLines(pen, new[] { new PointF(3.4f, 14.8f), new PointF(5f, 13.2f), new PointF(6.6f, 14.8f) });
        g.DrawLines(pen, new[] { new PointF(17.4f, 14.8f), new PointF(19f, 13.2f), new PointF(20.6f, 14.8f) });
        g.Restore(state);
    }

    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);

    /// <summary>Tray icon: light anchor on a pine (guarding) or brick (time up) rounded square.</summary>
    public static Icon TrayIcon(Color bg, int size = 32)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using (var b = new SolidBrush(bg)) using (var p = Theme.Round(new RectangleF(0, 0, size, size), size * 0.22f)) g.FillPath(b, p);
            float pad = size * 0.14f;
            Draw(g, new RectangleF(pad, pad, size - 2 * pad, size - 2 * pad), Theme.Paper, size / 12f);
        }
        IntPtr h = bmp.GetHicon();
        try { return (Icon)Icon.FromHandle(h).Clone(); }
        finally { DestroyIcon(h); }
    }
}
