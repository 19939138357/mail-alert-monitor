using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

internal sealed class EdgeSystemLogin
{
    internal const string TargetUrl = "https://portal.example.com:9978/admin.php?controller=admin_index&action=login";
    private Process _process;
    private readonly object _gate = new object();

    public void Open(string projectRoot, Action<string> report)
    {
        lock (_gate)
        {
            if (_process != null && !_process.HasExited)
            {
                report("Edge 系统窗口已打开，请切换到该窗口。");
                return;
            }
            if (_process != null) { _process.Dispose(); _process = null; }
            string tools = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "browser");
            string runtime = Environment.GetEnvironmentVariable("MAILALERT_NODE");
            if (string.IsNullOrWhiteSpace(runtime)) runtime = "node.exe";
            string script = Path.Combine(tools, "edge-login.js");
            string vault = Path.Combine(projectRoot, @"04_资料\私密配置\system-login.dat");
            if (!File.Exists(script))
            {
                report("登录组件缺失，请检查程序目录。");
                return;
            }
            if (!File.Exists(vault))
            {
                report("登录账号尚未配置。");
                return;
            }

            byte[] plain = null;
            string payload = null;
            Dictionary<string, object> credential = null;
            try
            {
                plain = ProtectedData.Unprotect(File.ReadAllBytes(vault), null, DataProtectionScope.CurrentUser);
                payload = Encoding.UTF8.GetString(plain);
                credential = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(payload);
                if (!credential.ContainsKey("targetUrl") || Convert.ToString(credential["targetUrl"]) != TargetUrl ||
                    !credential.ContainsKey("username") || !credential.ContainsKey("password") ||
                    string.IsNullOrWhiteSpace(Convert.ToString(credential["username"])) ||
                    string.IsNullOrWhiteSpace(Convert.ToString(credential["password"])))
                    throw new InvalidDataException();

                var child = new Process();
                child.StartInfo = new ProcessStartInfo
                {
                    FileName = runtime,
                    Arguments = Quote(script) + " --project " + Quote(projectRoot),
                    WorkingDirectory = projectRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };
                child.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (string.IsNullOrEmpty(e.Data)) return;
                    try
                    {
                        var entry = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(e.Data);
                        object code;
                        if (!entry.TryGetValue("state", out code)) return;
                        // Display only application-owned fixed messages, never raw browser errors.
                        switch (Convert.ToString(code))
                        {
                            case "opening": report("正在打开 Edge 登录窗口…"); break;
                            case "ready": report("正在填写账号并提交登录…"); break;
                            case "submitted": report("登录已提交，请在 Edge 查看结果。"); break;
                            case "manual_required": report("请在 Edge 处理网站提示后继续。"); break;
                            case "credentials_required": report("网页需要补充验证，请在 Edge 完成。"); break;
                            case "already_signed_in": report("系统页面已打开，请在 Edge 继续使用。"); break;
                            case "form_not_found": report("登录表单未匹配，请在 Edge 检查页面。"); break;
                            case "blocked_origin": report("页面地址与配置不符，未填写账号口令。"); break;
                            case "failed": report("登录窗口启动或加载失败，请检查 Edge。"); break;
                            case "closed": report("Edge 系统窗口已关闭。"); break;
                        }
                    }
                    catch { }
                };
                child.ErrorDataReceived += delegate { /* Drain stderr without storing potentially sensitive errors. */ };
                child.EnableRaisingEvents = true;
                child.Exited += delegate { report("Edge 系统窗口已关闭，可重新打开。"); };
                if (!child.Start()) throw new InvalidOperationException();
                _process = child;
                child.BeginOutputReadLine();
                child.BeginErrorReadLine();
                // Secrets travel only through an anonymous pipe, never arguments, clipboard or files.
                child.StandardInput.WriteLine(payload);
                child.StandardInput.Flush();
                child.StandardInput.Close();
                report("正在打开 Edge 登录窗口…");
            }
            catch (CryptographicException) { report("当前 Windows 用户无法解密登录账号，请重新配置。"); }
            catch { report("一键登录暂时无法启动，请检查程序和账号配置。"); }
            finally
            {
                if (plain != null) Array.Clear(plain, 0, plain.Length);
                if (credential != null) credential.Clear();
                payload = null;
            }
        }
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
}
