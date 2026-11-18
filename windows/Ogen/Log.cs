using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Ogen;

/// <summary>Plain-text diagnostics in %LOCALAPPDATA%\Ogen\log.txt (kept under ~1 MB).</summary>
internal static class Log
{
    private static readonly object Gate = new();
    public static string File => Path.Combine(Store.DataDir, "log.txt");

    public static void Write(string line)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Store.DataDir);
                var f = new FileInfo(File);
                if (f.Exists && f.Length > 1_000_000)
                    System.IO.File.Move(File, File + ".old", true);
                System.IO.File.AppendAllText(File, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{Environment.ProcessId}] {line}{Environment.NewLine}");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public static void Startup(string[] args) =>
        Write($"start v{typeof(Log).Assembly.GetName().Version} exe={Environment.ProcessPath} args=[{string.Join(" ", args)}] " +
              $"os={RuntimeInformation.OSDescription} arch={RuntimeInformation.OSArchitecture}/{RuntimeInformation.ProcessArchitecture}");
}
