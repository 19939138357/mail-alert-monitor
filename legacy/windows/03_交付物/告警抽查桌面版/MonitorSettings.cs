using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
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
            form.ClientSize = new Size(510, 348);
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox = false;
            form.MinimizeBox = false;
            form.StartPosition = FormStartPosition.CenterParent;
            form.BackColor = DesktopTheme.Surface;
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 6, ColumnCount = 2, Padding = new Padding(22) };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 105));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            form.Controls.Add(grid);
            var hint = new Label { Text = "用窗口标题或进程名定位邮箱。多个值用逗号分隔。", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = DesktopTheme.Muted };
            grid.Controls.Add(hint, 0, 0);
            grid.SetColumnSpan(hint, 2);
            grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            var editors = new List<TextBox>();
            string[] keys = { "windowTitleContains", "processNameContains", "keywords" };
            string[] labels = { "窗口标题包含", "进程名包含", "提醒关键词" };
            for (int i = 0; i < keys.Length; i++)
            {
                grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
                grid.Controls.Add(new Label { Text = labels[i], AutoSize = true, Anchor = AnchorStyles.Left }, 0, i + 1);
                var editor = new TextBox { Text = JoinValues(data, keys[i]), Dock = DockStyle.Top, AccessibleName = labels[i] };
                grid.Controls.Add(editor, 1, i + 1);
                editors.Add(editor);
            }
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 41));
            grid.Controls.Add(new Label { Text = "扫描间隔（秒）", Anchor = AnchorStyles.Left, AutoSize = true }, 0, 4);
            bool autoOpen = data.ContainsKey("mailConfirmationAutoOpenEnabled") && Convert.ToBoolean(data["mailConfirmationAutoOpenEnabled"]);
            string intervalKey = autoOpen ? "mailConfirmationListCheckIntervalSeconds" : "intervalSeconds";
            var interval = new NumericUpDown { Minimum = 1, Maximum = 3600, Width = 100, AccessibleName = "扫描间隔（秒）" };
            object current;
            if (data.TryGetValue(intervalKey, out current)) interval.Value = Math.Min(interval.Maximum, Math.Max(interval.Minimum, Convert.ToDecimal(current)));
            grid.Controls.Add(interval, 1, 4);
            grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
            var save = new Button { Text = "保存", AutoSize = true, ForeColor = DesktopTheme.Accent };
            var cancel = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel };
            buttons.Controls.Add(save);
            buttons.Controls.Add(cancel);
            grid.Controls.Add(buttons, 0, 5);
            grid.SetColumnSpan(buttons, 2);
            form.AcceptButton = save;
            form.CancelButton = cancel;
            save.Click += delegate
            {
                if (Values(editors[0].Text).Length + Values(editors[1].Text).Length == 0 || Values(editors[2].Text).Length == 0)
                {
                    MessageBox.Show(form, "请填写窗口标题或进程名，并至少设置一个提醒关键词。", form.Text);
                    return;
                }
                string staged = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    if (!string.Equals(snapshot, File.ReadAllText(path, Encoding.UTF8), StringComparison.Ordinal))
                        throw new IOException("配置已在其他窗口修改，请重新打开设置。");
                    for (int i = 0; i < keys.Length; i++) data[keys[i]] = Values(editors[i].Text);
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
