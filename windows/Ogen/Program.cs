using System;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;
using Ogen.Core;

namespace Ogen;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        int shots = Array.IndexOf(args, "--shots");
        if (shots >= 0) return Shots.Run(shots + 1 < args.Length ? args[shots + 1] : "shots");

        bool background = args.Contains("--background");
        bool noInstall = args.Contains("--no-install");
        if (!noInstall && Install.RelaunchFromInstallDir(args)) return 0;

        using var mutex = new Mutex(true, Install.MutexName, out bool first);
        if (!first)
        {
            if (!background) Install.Signal(Install.ShowEventName);
            return 0;
        }
        try
        {
            Application.Run(new Tray(AppModel.Load(), background, noInstall));
        }
        finally
        {
            try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
        }
        return 0;
    }
}

/// <summary>Lives in the notification area. Owns the window, the guard and the cover.</summary>
internal sealed class Tray : ApplicationContext
{
    private readonly AppModel m;
    private readonly bool noInstall;
    private readonly NotifyIcon icon = new();
    private readonly MainForm form;
    private readonly BlockForm cover;
    private readonly Guard guard;
    private readonly ToolStripMenuItem exitItem, removeItem;
    private readonly System.Windows.Forms.Timer protect = new() { Interval = 5 * 60_000 };
    private readonly EventWaitHandle showEvent = new(false, EventResetMode.AutoReset, Install.ShowEventName);
    private readonly EventWaitHandle updateEvent = new(false, EventResetMode.AutoReset, Install.UpdateEventName);
    private readonly RegisteredWaitHandle showWait, updateWait;
    private readonly Icon pineIcon = AnchorMark.TrayIcon(Theme.Pine), brickIcon = AnchorMark.TrayIcon(Theme.Brick), mutedIcon = AnchorMark.TrayIcon(Theme.Muted);
    private bool quitting;

    public Tray(AppModel model, bool background, bool noInstall)
    {
        m = model;
        this.noInstall = noInstall;
        form = new MainForm(m) { FixProtection = () => RegisterAsync(true) };
        form.FormClosing += (_, e) =>
        {
            if (quitting || e.CloseReason != CloseReason.UserClosing) return;
            e.Cancel = true;   // closing the window keeps the guard running
            form.Hide();
        };
        _ = form.Handle;       // a UI-thread handle for BeginInvoke even while hidden

        cover = new BlockForm(m) { OpenApp = ShowWindow };
        guard = new Guard(m, cover);
        guard.Warn += text => icon.ShowBalloonTip(5000, "עוגן", text, ToolTipIcon.Info);
        guard.Ticked += UpdateIcon;

        var menu = new ContextMenuStrip { RightToLeft = RightToLeft.Yes };
        menu.Items.Add("פתיחת עוגן", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        exitItem = new ToolStripMenuItem("יציאה", null, (_, _) => Quit(false));
        removeItem = new ToolStripMenuItem("הסרה מהמחשב", null, (_, _) => Quit(true));
        menu.Items.Add(exitItem);
        menu.Items.Add(removeItem);
        menu.Opening += (_, _) =>
        {
            bool free = !m.P.Guarding(m.Now());
            exitItem.Enabled = removeItem.Enabled = free;
            exitItem.ToolTipText = free ? null : "אפשר לצאת רק כשאין זמן מסך וחסימה פעילים";
        };
        icon.ContextMenuStrip = menu;
        icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };
        icon.BalloonTipClicked += (_, _) => ShowWindow();
        UpdateIcon();
        icon.Visible = true;

        showWait = ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) => Ui(ShowWindow), null, -1, false);
        updateWait = ThreadPool.RegisterWaitForSingleObject(updateEvent, (_, _) => Ui(() => Quit(false, forUpdate: true)), null, -1, false);

        SystemEvents.SessionEnding += (_, _) => m.Save();
        protect.Tick += (_, _) => RegisterAsync(false);
        protect.Start();
        RegisterAsync(false);

        if (!background) ShowWindow();
    }

    private void Ui(Action a)
    {
        try { form.BeginInvoke(a); }
        catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException) { }
    }

    private void ShowWindow()
    {
        form.Go(Ogen.MainForm.Page.Home);
        form.Show();
        if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
        form.Activate();
        Native.SetForegroundWindow(form.Handle);
    }

    /// <summary>Autostart + watchdog task, re-asserted every few minutes (schtasks runs off the UI thread).</summary>
    private void RegisterAsync(bool userAsked)
    {
        if (noInstall) return;
        Task.Run(Install.Register).ContinueWith(t =>
        {
            bool ok = t.Status == TaskStatus.RanToCompletion && t.Result;
            Ui(() =>
            {
                if (form.ProtectionOk != ok) { form.ProtectionOk = ok; form.Render(); }
                if (userAsked) form.Toast(ok ? "עוגן יופעל עם Windows" : "לא הצלחתי להפעיל. נסה שוב");
            });
        }, TaskScheduler.Default);
    }

    private void UpdateIcon()
    {
        long now = m.Now();
        var p = m.P;
        string tip;
        if (p.Locked(now)) { icon.Icon = brickIcon; tip = "עוגן · זמן המסך להיום נגמר"; }
        else if (p.LimitMs != Policy.None) { icon.Icon = pineIcon; tip = "עוגן · נשאר " + Fmt.Hm(p.RemainingMs()); }
        else { icon.Icon = p.Guarding(now) ? pineIcon : mutedIcon; tip = p.SocialBlock ? "עוגן · רשתות ויוטיוב חסומים" : "עוגן · כבוי"; }
        if (icon.Text != tip) icon.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    private void Quit(bool uninstall, bool forUpdate = false)
    {
        // A newer copy of Ogen is taking over: the policy is saved and carries over.
        if (!forUpdate)
        {
            if (m.P.Guarding(m.Now())) return;
            string q = uninstall ? "להסיר את עוגן מהמחשב?" : "לצאת מעוגן?";
            string msg = uninstall ? "עוגן יוסר וכל ההגדרות יימחקו." : "עוגן לא יפעל עד שתפתח אותו שוב.";
            if (!ConfirmForm.Ask(form, q, msg)) return;
            if (!noInstall)
            {
                if (uninstall) Install.Uninstall();
                else Install.DisableWatchdog();
            }
        }
        quitting = true;
        m.Save();
        guard.Dispose();
        showWait.Unregister(null);
        updateWait.Unregister(null);
        icon.Visible = false;
        icon.Dispose();
        cover.Dispose();
        form.Close();
        ExitThread();
    }
}
