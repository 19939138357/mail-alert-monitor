using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class Program
{
    private const string ScriptName = "Monitor-WindowKeywords.ps1";

    private static int Main()
    {
        string fallbackLog = Path.Combine(
            AppDomain.CurrentDomain.BaseDirectory,
            "one_click_monitor_launcher_error.log");

        try
        {
            string project = FindProjectDirectory();
            string script = Path.Combine(project, ScriptName);
            string launcherLog = Path.Combine(project, "monitor_launcher.log");

            Log(launcherLog, "Launcher started.");
            // The script owns single-instance enforcement. Do not kill a running
            // monitor (which loses delivery state) or focus an unrelated Edge window.
            StartMonitor(project, script, launcherLog);
            Log(launcherLog, "Launcher finished.");
            return 0;
        }
        catch (Exception ex)
        {
            Log(fallbackLog, "ERROR: " + ex);
            return 1;
        }
    }

    private static string FindProjectDirectory()
    {
        string local = AppDomain.CurrentDomain.BaseDirectory;
        if (File.Exists(Path.Combine(local, ScriptName))) return local;
        DirectoryInfo parent = Directory.GetParent(local.TrimEnd(Path.DirectorySeparatorChar));
        if (parent != null && File.Exists(Path.Combine(parent.FullName, ScriptName))) return parent.FullName;
        throw new FileNotFoundException("Place the launcher next to or one folder below " + ScriptName);
    }

    private static void StopOldMonitors(string launcherLog)
    {
        string ps =
            "$ProgressPreference='SilentlyContinue'; " +
            "$me=$PID; " +
            "$old=Get-CimInstance Win32_Process | Where-Object { " +
            "$_.ProcessId -ne $me -and " +
            "$_.CommandLine -like '*powershell.exe*' -and " +
            "$_.CommandLine -like '*Monitor-WindowKeywords.ps1*' " +
            "}; " +
            "foreach ($p in $old) { " +
            "Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; " +
            "Write-Output ('Stopped old monitor PID=' + $p.ProcessId) " +
            "}";

        RunPowerShellHidden(ps, launcherLog);
    }

    private static void BringEdgeToFront(string launcherLog)
    {
        try
        {
            List<WindowInfo> windows = new List<WindowInfo>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd))
                {
                    return true;
                }

                int length = GetWindowTextLength(hWnd);
                if (length <= 0)
                {
                    return true;
                }

                StringBuilder titleBuilder = new StringBuilder(length + 1);
                GetWindowText(hWnd, titleBuilder, titleBuilder.Capacity);
                string title = titleBuilder.ToString();
                if (string.IsNullOrWhiteSpace(title))
                {
                    return true;
                }

                uint processId;
                GetWindowThreadProcessId(hWnd, out processId);
                Process process;
                try
                {
                    process = Process.GetProcessById((int)processId);
                }
                catch
                {
                    return true;
                }

                if (string.Equals(process.ProcessName, "msedge", StringComparison.OrdinalIgnoreCase))
                {
                    windows.Add(new WindowInfo { Handle = hWnd, Title = title });
                }

                return true;
            }, IntPtr.Zero);

            if (windows.Count == 0)
            {
                Log(launcherLog, "No Edge window found to bring forward.");
                return;
            }

            WindowInfo target = windows[0];
            foreach (WindowInfo window in windows)
            {
                string title = window.Title ?? string.Empty;
                if (title.IndexOf("administrator@192.0.2.11", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("Foxmail", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("example", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    target = window;
                    break;
                }
            }

            ShowWindow(target.Handle, 9);
            SetForegroundWindow(target.Handle);
            Log(launcherLog, "Brought Edge window forward: " + target.Title);
        }
        catch (Exception ex)
        {
            Log(launcherLog, "BringEdgeToFront failed: " + ex.Message);
        }
    }

    private static void StartMonitor(string project, string script, string launcherLog)
    {
        if (!File.Exists(script))
        {
            throw new FileNotFoundException("Monitor script not found", script);
        }

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = GetPowerShellPath();
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script);
        psi.WorkingDirectory = project;
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Normal;

        Process process = Process.Start(psi);
        if (process == null)
        {
            throw new InvalidOperationException("Failed to start monitor process.");
        }

        Log(launcherLog, "Started monitor PID=" + process.Id);
    }

    private static void RunPowerShellHidden(string script, string launcherLog)
    {
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = GetPowerShellPath();
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        using (Process process = Process.Start(psi))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Failed to run cleanup PowerShell.");
            }

            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            if (!process.WaitForExit(15000))
            {
                try { process.Kill(); } catch { }
                Log(launcherLog, "Cleanup timed out.");
                return;
            }

            if (!string.IsNullOrWhiteSpace(output))
            {
                Log(launcherLog, output.Trim());
            }
            if (!string.IsNullOrWhiteSpace(error))
            {
                Log(launcherLog, "Cleanup stderr: " + error.Trim());
            }
        }
    }

    private static string GetPowerShellPath()
    {
        string windir = Environment.GetEnvironmentVariable("WINDIR");
        if (string.IsNullOrWhiteSpace(windir))
        {
            windir = @"C:\Windows";
        }

        return Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void Log(string path, string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine;
            File.AppendAllText(path, line, Encoding.UTF8);
        }
        catch
        {
        }
    }

    private sealed class WindowInfo
    {
        public IntPtr Handle;
        public string Title;
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
}
