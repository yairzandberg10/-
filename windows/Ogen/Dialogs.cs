using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Ogen.Core;

namespace Ogen;

/// <summary>Small RTL confirm dialog in the app's style (title, message, אישור / ביטול).</summary>
internal sealed class ConfirmForm : Form
{
    private readonly Stack stack = new() { PadX = 22, PadTop = 18, PadBottom = 18 };

    public ConfirmForm(string title, string message, float scale)
    {
        Text = "עוגן";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MinimizeBox = MaximizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Theme.Card;
        KeyPreview = true;
        stack.BackColor = Theme.Card;
        stack.S = scale;
        stack.Dock = DockStyle.Fill;
        stack.AutoScroll = false;
        Controls.Add(stack);

        stack.Add(new TextBlock(title, 19, Theme.Ink, Theme.W.Medium));
        stack.Add(new TextBlock(message, 15, Theme.Ink2), 8);
        var ok = stack.Add(new ButtonBlock("אישור", BtnStyle.Primary, () => { DialogResult = DialogResult.OK; Close(); }), 18);
        stack.Add(new ButtonBlock("ביטול", BtnStyle.Plain, () => { DialogResult = DialogResult.Cancel; Close(); }), 6);

        int w = (int)(380 * scale);
        int h = 0;
        stack.ClientSize = new Size(w, 10);
        foreach (Block b in stack.Controls) h += b.Measure(w - (int)(2 * stack.PadX * scale)) + (int)(b.Gap * scale);
        ClientSize = new Size(w, h + (int)((stack.PadTop + stack.PadBottom) * scale));
        Shown += (_, _) => ok.Focus();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) { DialogResult = DialogResult.Cancel; Close(); }
        base.OnKeyDown(e);
    }

    public static bool Ask(Form owner, string title, string message)
    {
        using var f = new ConfirmForm(title, message, owner.DeviceDpi / 96f) { Icon = owner.Icon };
        return f.ShowDialog(owner) == DialogResult.OK;
    }
}

/// <summary>Pick an app for "always open": the apps with open windows, or any .exe.</summary>
internal sealed class AppPickerForm : Form
{
    private readonly Stack stack = new();
    private (string pkg, string name)? result;

    private AppPickerForm(AppModel m, float scale)
    {
        Text = "הוספת אפליקציה";
        FormBorderStyle = FormBorderStyle.Sizable;
        MinimizeBox = MaximizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Theme.Paper;
        KeyPreview = true;
        stack.S = scale;
        stack.Dock = DockStyle.Fill;
        Controls.Add(stack);
        ClientSize = new Size((int)(400 * scale), (int)(560 * scale));

        stack.Add(new SubHeaderBlock("הוספת אפליקציה", () => Close()));
        stack.Add(new TextBlock("אפליקציות שפתוחות עכשיו:", 14, Theme.Muted), 2);
        var apps = RunningApps().Where(a => !Rules.Free(m.P, a.pkg) && !m.P.ExtraAllowed.Contains(a.pkg)).ToList();
        if (apps.Count == 0) stack.Add(new TextBlock("אין חלונות פתוחים אחרים. פתח את האפליקציה ונסה שוב, או בחר קובץ.", 14, Theme.Ink2), 8);
        foreach (var a in apps)
        {
            var app = a;
            stack.Add(new AppRowBlock(app.name, app.pkg + ".exe", "הוסף", () => { result = app; Close(); }), 2);
        }
        stack.Add(new ButtonBlock("בחירת קובץ exe…", BtnStyle.Ghost, Browse), 14);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Close();
        base.OnKeyDown(e);
    }

    private void Browse()
    {
        using var d = new OpenFileDialog
        {
            Filter = "אפליקציות (*.exe)|*.exe",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        };
        if (d.ShowDialog(this) != DialogResult.OK) return;
        result = (Rules.Normalize(Path.GetFileName(d.FileName)), Describe(d.FileName));
        Close();
    }

    private static string Describe(string path)
    {
        try
        {
            var v = FileVersionInfo.GetVersionInfo(path);
            if (!string.IsNullOrWhiteSpace(v.FileDescription)) return v.FileDescription.Trim();
            if (!string.IsNullOrWhiteSpace(v.ProductName)) return v.ProductName.Trim();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { }
        return Path.GetFileNameWithoutExtension(path);
    }

    private static List<(string pkg, string name)> RunningApps()
    {
        var list = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var proc in Process.GetProcesses())
        {
            try
            {
                if (proc.MainWindowHandle == IntPtr.Zero || string.IsNullOrWhiteSpace(proc.MainWindowTitle)) continue;
                string pkg = Rules.Normalize(proc.ProcessName);
                if (list.ContainsKey(pkg)) continue;
                string path = Native.ProcessPath((uint)proc.Id);
                list[pkg] = path.Length > 0 ? Describe(path) : proc.ProcessName;
            }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            finally { proc.Dispose(); }
        }
        return list.Select(kv => (kv.Key, kv.Value)).OrderBy(a => a.Value, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public static (string pkg, string name)? Pick(Form owner, AppModel m)
    {
        using var f = new AppPickerForm(m, owner.DeviceDpi / 96f) { Icon = owner.Icon };
        f.ShowDialog(owner);
        return f.result;
    }
}
