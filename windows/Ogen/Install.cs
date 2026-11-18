using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using Microsoft.Win32;

namespace Ogen;

/// <summary>
/// Ogen copies itself to %LOCALAPPDATA%\Programs\Ogen, starts with Windows (Run key) and
/// registers a per-user scheduled task that relaunches it every minute if it was closed.
/// None of this needs administrator rights.
/// </summary>
internal static class Install
{
    public const string MutexName = @"Local\Ogen.Single";
    public const string ShowEventName = @"Local\Ogen.Show";
    public const string UpdateEventName = @"Local\Ogen.Update";
    private const string TaskName = "Ogen";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Ogen");

    public static string Exe => Path.Combine(Dir, "Ogen.exe");

    private static string Current => Environment.ProcessPath ?? "";

    public static bool RunningInstalled =>
        string.Equals(Path.GetFullPath(Current), Path.GetFullPath(Exe), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// When started from anywhere else (Downloads...), install or update the copy in Programs and
    /// start that one instead. Returns true when this process should exit.
    /// </summary>
    public static bool RelaunchFromInstallDir(string[] args)
    {
        if (RunningInstalled || Current.Length == 0) return false;
        try
        {
            // An older copy is running: ask it to step aside so the file can be replaced.
            if (Mutex.TryOpenExisting(MutexName, out var running))
            {
                if (SameFile(Current, Exe))
                {
                    running.Dispose();
                    Signal(ShowEventName);
                    return true;
                }
                Signal(UpdateEventName);
                try { running.WaitOne(TimeSpan.FromSeconds(15)); } catch (AbandonedMutexException) { }
                try { running.ReleaseMutex(); } catch (ApplicationException) { }
                running.Dispose();
            }
            Directory.CreateDirectory(Dir);
            for (int i = 0; ; i++)
            {
                try { File.Copy(Current, Exe, true); break; }
                catch (IOException) when (i < 20) { Thread.Sleep(250); }
            }
            Process.Start(new ProcessStartInfo(Exe) { UseShellExecute = false, Arguments = string.Join(" ", args.Select(Quote)) });
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            return false; // could not install: just run from where we are
        }
    }

    private static bool SameFile(string a, string b)
    {
        try
        {
            var fa = new FileInfo(a);
            var fb = new FileInfo(b);
            if (!fb.Exists || fa.Length != fb.Length) return false;
            return FileVersionInfo.GetVersionInfo(a).FileVersion == FileVersionInfo.GetVersionInfo(b).FileVersion
                   && fa.LastWriteTimeUtc == fb.LastWriteTimeUtc;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    public static void Signal(string name)
    {
        try
        {
            using var ev = EventWaitHandle.OpenExisting(name);
            ev.Set();
        }
        catch (Exception e) when (e is WaitHandleCannotBeOpenedException or UnauthorizedAccessException) { }
    }

    private static string Quote(string a) => a.Contains(' ') ? "\"" + a + "\"" : a;

    private static string Target => RunningInstalled ? Exe : Current;

    /// <summary>Autostart + watchdog. Cheap enough to call every few minutes.</summary>
    public static bool Register()
    {
        bool ok = true;
        string cmd = $"\"{Target}\" --background";
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (k.GetValue("Ogen") as string != cmd) k.SetValue("Ogen", cmd);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException) { ok = false; }

        if (!TaskOk()) ok &= CreateTask();
        return ok;
    }

    /// <summary>
    /// Created from XML so the task also runs on battery (schtasks' defaults skip laptops on battery)
    /// and never piles up instances. A second launch exits at once: the single-instance mutex.
    /// </summary>
    private static bool CreateTask()
    {
        string start = DateTime.Now.AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);
        string xml = $"""
            <?xml version="1.0" encoding="UTF-16"?>
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <RegistrationInfo><Description>Keeps Ogen running</Description></RegistrationInfo>
              <Triggers>
                <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
                <TimeTrigger>
                  <StartBoundary>{start}</StartBoundary>
                  <Enabled>true</Enabled>
                  <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
                </TimeTrigger>
              </Triggers>
              <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
              <Settings>
                <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
                <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
                <AllowHardTerminate>true</AllowHardTerminate>
                <StartWhenAvailable>true</StartWhenAvailable>
                <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
                <AllowStartOnDemand>true</AllowStartOnDemand>
                <Enabled>true</Enabled>
                <Hidden>true</Hidden>
                <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
                <Priority>7</Priority>
              </Settings>
              <Actions Context="Author">
                <Exec><Command>{System.Security.SecurityElement.Escape(Target)}</Command><Arguments>--background</Arguments></Exec>
              </Actions>
            </Task>
            """;
        string file = Path.Combine(Path.GetTempPath(), "ogen-task.xml");
        try
        {
            File.WriteAllText(file, xml, System.Text.Encoding.Unicode);
            return Schtasks($"/Create /TN {TaskName} /XML \"{file}\" /F") == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        finally { try { File.Delete(file); } catch (IOException) { } }
    }

    private static bool TaskOk()
    {
        var (code, xml) = SchtasksOut($"/Query /TN {TaskName} /XML");
        return code == 0 && xml.Contains(Target, StringComparison.OrdinalIgnoreCase)
               && !xml.Contains("<Enabled>false</Enabled>", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Only called when nothing is guarded: stop the watchdog from relaunching us.</summary>
    public static void DisableWatchdog() => Schtasks($"/Change /TN {TaskName} /DISABLE");

    /// <summary>Remove every trace. Only offered while nothing is guarded.</summary>
    public static void Uninstall()
    {
        Schtasks($"/Delete /TN {TaskName} /F");
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            k.DeleteValue("Ogen", false);
            Registry.CurrentUser.DeleteSubKeyTree(@"Software\Ogen", false);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
        // the running exe can't delete itself: a short-lived cmd does it after we exit
        string del = $"/c timeout /t 3 /nobreak >nul & rmdir /s /q \"{Store.DataDir}\" & rmdir /s /q \"{Dir}\"";
        try
        {
            Process.Start(new ProcessStartInfo("cmd.exe", del) { CreateNoWindow = true, UseShellExecute = false });
        }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private static int Schtasks(string args) => SchtasksOut(args).code;

    private static (int code, string output) SchtasksOut(string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("schtasks.exe", args)
            {
                CreateNoWindow = true, UseShellExecute = false,
                RedirectStandardOutput = true, RedirectStandardError = true,
            });
            if (p == null) return (-1, "");
            string o = p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            if (!p.WaitForExit(10_000)) { try { p.Kill(); } catch (InvalidOperationException) { } return (-1, o); }
            return (p.ExitCode, o);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return (-1, "");
        }
    }
}
