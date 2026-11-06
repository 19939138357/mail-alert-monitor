using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class UnreadReview
{
    private static string Value(IDictionary<string,object> item,string name)
    {
        object value;
        return item != null && item.TryGetValue(name,out value) ? Convert.ToString(value) : "";
    }
    internal static void Show(Form owner,string root)
    {
        string path = Path.Combine(root,@"04_资料\私密配置\foxmail-unread.dpapi");
        if (!File.Exists(path)) { MessageBox.Show(owner,"当前没有未读正文处理记录。","待核对邮件"); return; }
        var queue = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        byte[] bytes;
        using (var source = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read | FileShare.Delete))
        using (var copy = new MemoryStream()) {
            source.CopyTo(copy);
            bytes = ProtectedData.Unprotect(copy.ToArray(),null,DataProtectionScope.CurrentUser);
        }
        var table = queue.Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(bytes));
        Array.Clear(bytes,0,bytes.Length);
        using (var dialog = new Form()) {
            dialog.Text = "待核对邮件";
            dialog.Font = new Font(DesktopTheme.UiFont,10);
            dialog.ClientSize = new Size(720,420);
            dialog.MinimumSize = new Size(540,320);
            dialog.StartPosition = FormStartPosition.CenterParent;
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(12) };
            layout.RowStyles.Add(new RowStyle(SizeType.Percent,50));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent,50));
            var list = new ListView { View = View.Details, Dock = DockStyle.Fill, FullRowSelect = true, MultiSelect = false, HideSelection = false };
            list.Columns.Add("状态",120); list.Columns.Add("邮件主题",340); list.Columns.Add("邮件时间",150);
            var details = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BackColor = Color.White, ScrollBars = ScrollBars.Vertical };
            foreach (IDictionary<string,object> entry in (IEnumerable)table["Items"]) {
                string state = Value(entry,"Status");
                if (state != "review" && state != "reading" && state != "sending" && state != "uncertain" && state != "rejected") continue;
                var mail = entry["Mail"] as IDictionary<string,object>;
                var header = mail ?? entry["Ticket"] as IDictionary<string,object>;
                string body = mail == null ? "正文尚未核对完整，请在邮箱中核对这封邮件。" : Value(mail,"Body");
                string status = state == "uncertain" || state == "sending" ? "核对手机收件" : state == "rejected" ? "检查通知设置" : "核对原邮件";
                var row = new ListViewItem(new[] {status,Value(header,"Subject"),Value(header,"Time")});
                row.Tag = Value(header,"Sender") + Environment.NewLine + Value(header,"Subject") + Environment.NewLine + Environment.NewLine + body;
                list.Items.Add(row);
            }
            list.SelectedIndexChanged += delegate { if (list.SelectedItems.Count > 0) details.Text = Convert.ToString(list.SelectedItems[0].Tag); };
            if (list.Items.Count > 0) { list.Items[0].Selected = true; details.Text = Convert.ToString(list.Items[0].Tag); }
            else details.Text = "当前没有待核对邮件。";
            layout.Controls.Add(list,0,0); layout.Controls.Add(details,0,1);
            dialog.Controls.Add(layout); dialog.ShowDialog(owner);
        }
    }
}
