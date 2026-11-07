using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class MonitorSettings
{
    private static string JoinValues(Dictionary<string, object> config, string key)
    {
        object value;
        if (!config.TryGetValue(key, out value) || !(value is IEnumerable)) return "";
        if (value is string) return (string)value;
        return string.Join("，", ((IEnumerable)value).Cast<object>().Select(Convert.ToString));
    }

    private static string[] Values(string text)
    {
        return text.Split(new[] { ',', '，' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(item => item.Trim()).Where(item => item.Length > 0).Distinct().ToArray();
    }

    internal static void Show(IWin32Window owner, string path)
    {
        var serializer = new JavaScriptSerializer();
        string snapshot = File.ReadAllText(path, Encoding.UTF8);
        var data = serializer.Deserialize<Dictionary<string, object>>(snapshot);
        using (var form = new Form())
        {
            form.Text = "监控设置";
            form.AutoScaleMode = AutoScaleMode.Dpi;
            form.Font = new Font(DesktopTheme.UiFont, 10);
            form.ClientSize = new Size(570, 518);
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox = false;
            form.MinimizeBox = false;
            form.StartPosition = FormStartPosition.CenterParent;
            form.BackColor = DesktopTheme.Surface;
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 8, ColumnCount = 2, Padding = new Padding(22) };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            form.Controls.Add(grid);
            var hint = new Label { Text = "用窗口标题或进程名定位邮箱。多个值用逗号分隔。", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = DesktopTheme.Muted };
            grid.Controls.Add(hint, 0, 0);
            grid.SetColumnSpan(hint, 2);
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            bool oldAuto = data.ContainsKey("mailConfirmationAutoOpenEnabled") && Convert.ToBoolean(data["mailConfirmationAutoOpenEnabled"]);
            bool oldUnread = data.ContainsKey("foxmailUnreadEnabled") && Convert.ToBoolean(data["foxmailUnreadEnabled"]);
            var mode = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Top, AccessibleName = "识别模式" };
            mode.Items.AddRange(new object[] { "屏幕关键词", "抽查邮件确认码", "Foxmail 未读邮件正文" });
            mode.SelectedIndex = oldUnread ? 2 : oldAuto ? 1 : 0;
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
            grid.Controls.Add(new Label { Text = "识别模式", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 1);
            grid.Controls.Add(mode, 1, 1);
            var editors = new List<TextBox>();
            string[] keys = { "windowTitleContains", "processNameContains", "keywords" };
            string[] labels = { "窗口标题包含", "进程名包含", "提醒关键词" };
            for (int i = 0; i < keys.Length; i++)
            {
                grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
                grid.Controls.Add(new Label { Text = labels[i], AutoSize = true, Anchor = AnchorStyles.Left }, 0, i + 2);
                var editor = new TextBox { Text = JoinValues(data, keys[i]), Dock = DockStyle.Top, AccessibleName = labels[i] };
                grid.Controls.Add(editor, 1, i + 2);
                editors.Add(editor);
            }
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 41));
            grid.Controls.Add(new Label { Text = "扫描间隔（秒）", Anchor = AnchorStyles.Left, AutoSize = true }, 0, 5);
            var interval = new NumericUpDown { Minimum = 1, Maximum = 3600, Width = 100, AccessibleName = "扫描间隔（秒）" };
            Action updateMode = delegate {
                string key = mode.SelectedIndex == 1 ? "mailConfirmationListCheckIntervalSeconds" : "intervalSeconds";
                interval.Maximum = mode.SelectedIndex == 2 ? 60 : mode.SelectedIndex == 1 ? 300 : 3600;
                object value;
                if (data.TryGetValue(key, out value)) interval.Value = Math.Min(interval.Maximum, Math.Max(interval.Minimum, Convert.ToDecimal(value)));
                editors[2].Enabled = mode.SelectedIndex == 0;
                editors[1].Enabled = mode.SelectedIndex == 0;
                hint.Text = mode.SelectedIndex == 2 ? "请展开邮件头，框选列表及右侧正文（含滚动条）。远程画面缺少可核对的滚动条时，邮件将保留待核对。"
                    : mode.SelectedIndex == 1 ? "请填写邮箱窗口标题，并在配置文件中指定抽查邮件发件人。"
                    : "用窗口标题或进程名定位邮箱。多个值用逗号分隔。";
            };
            mode.SelectedIndexChanged += delegate { updateMode(); };
            updateMode();
            grid.Controls.Add(interval, 1, 5);
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            grid.Controls.Add(new Label { Text = "正文识别", Anchor = AnchorStyles.Left, AutoSize = true }, 0, 6);
            var engines = new FlowLayoutPanel { Dock = DockStyle.Fill };
            var engine = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 190, AccessibleName = "正文识别引擎" };
            engine.Items.AddRange(new object[] { "系统本机识别", "小米 MiMo 本地 · 免费" });
            engine.SelectedIndex = data.ContainsKey("foxmailBodyOcr") && Convert.ToString(data["foxmailBodyOcr"]) == "mimo-local" ? 1 : 0;
            var launch = new Button { Text = "安装或启动模型", AutoSize = true };
            launch.Click += delegate {
                try {
                    string script = Path.Combine(Path.GetDirectoryName(path), "Start-MiMo.ps1");
                    Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"") { UseShellExecute = true });
                } catch (Exception) { MessageBox.Show(form, "请完整解压新版程序，并重新打开模型工具。", "模型启动"); }
            };
            Action updateEngine = delegate { engine.Enabled = mode.SelectedIndex == 2; };
            mode.SelectedIndexChanged += delegate { updateEngine(); };
            updateEngine();
            engines.Controls.Add(engine); engines.Controls.Add(launch); grid.Controls.Add(engines, 1, 6);
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            var calibrate = new Button { Text = "框选邮箱区域", AutoSize = true };
            calibrate.Enabled = mode.SelectedIndex != 0;
            mode.SelectedIndexChanged += delegate { calibrate.Enabled = mode.SelectedIndex != 0; };
            calibrate.Click += delegate { MailRegions.Select(form, Values(editors[0].Text), data); };
            var save = new Button { Text = "保存", AutoSize = true, ForeColor = DesktopTheme.Accent };
            var cancel = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel };
            buttons.Controls.Add(save);
            buttons.Controls.Add(cancel);
            buttons.Controls.Add(calibrate);
            grid.Controls.Add(buttons, 0, 7);
            grid.SetColumnSpan(buttons, 2);
            form.AcceptButton = save;
            form.CancelButton = cancel;
            save.Click += delegate
            {
                bool hasTitle = Values(editors[0].Text).Length > 0;
                if (mode.SelectedIndex == 0 ? ((!hasTitle && Values(editors[1].Text).Length == 0) || Values(editors[2].Text).Length == 0) : !hasTitle)
                {
                    MessageBox.Show(form, mode.SelectedIndex == 0 ? "请填写窗口标题或进程名，并至少设置一个关键词。" : "请填写邮箱窗口的独有标题。", form.Text);
                    return;
                }
                string staged = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    if (!string.Equals(snapshot, File.ReadAllText(path, Encoding.UTF8), StringComparison.Ordinal))
                        throw new IOException("配置已在其他窗口修改，请重新打开设置。");
                    for (int i = 0; i < keys.Length; i++) data[keys[i]] = Values(editors[i].Text);
                    data["mailConfirmationAutoOpenEnabled"] = mode.SelectedIndex == 1;
                    data["foxmailUnreadEnabled"] = mode.SelectedIndex == 2;
                    data["foxmailBodyOcr"] = engine.SelectedIndex == 1 ? "mimo-local" : "system";
                    string intervalKey = mode.SelectedIndex == 1 ? "mailConfirmationListCheckIntervalSeconds" : "intervalSeconds";
                    data[intervalKey] = (int)interval.Value;
                    File.WriteAllText(staged, serializer.Serialize(data), new UTF8Encoding(false));
                    File.Replace(staged, path, null);
                    form.DialogResult = DialogResult.OK;
                }
                catch (Exception error) { MessageBox.Show(form, error.Message, "未保存"); }
                finally { if (File.Exists(staged)) File.Delete(staged); }
            };
            form.ShowDialog(owner);
        }
    }
}
