using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal sealed class MailRegions : Form
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeBounds { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out NativeBounds bounds);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr handle);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
    private delegate bool EnumCallback(IntPtr window, IntPtr unused);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumCallback callback, IntPtr unused);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle,StringBuilder text,int size);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle,out uint pid);
    private Rectangle list, body, drag;
    private Point origin;
    private bool drawing;
    private readonly Rectangle targetArea;

    private MailRegions(Rectangle target)
    {
        targetArea = target;
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = target; TopMost = true; ShowInTaskbar = false;
        BackColor = Color.FromArgb(22, 49, 61); Opacity = 0.58;
        Cursor = Cursors.Cross; DoubleBuffered = true;
        Text = "框选邮箱区域";
        KeyPreview = true;
        KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) DialogResult = DialogResult.Cancel; };
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        origin = e.Location; drag = Rectangle.Empty; drawing = true; Capture = true;
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e); if (!drawing) return;
        drag = Rectangle.Intersect(ClientRectangle, Rectangle.FromLTRB(Math.Min(origin.X,e.X),Math.Min(origin.Y,e.Y),Math.Max(origin.X,e.X),Math.Max(origin.Y,e.Y)));
        Invalidate();
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e); if (!drawing) return;
        drawing = false; Capture = false;
        if (drag.Width >= 80 && drag.Height >= 100) {
            if (list.IsEmpty) list = drag;
            else if (drag.Left >= list.Right - 2) { body = drag; DialogResult = DialogResult.OK; }
        }
        drag = Rectangle.Empty; Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using (var pen = new Pen(Color.White, 3)) {
            if (!list.IsEmpty) e.Graphics.DrawRectangle(pen,list);
            if (!drag.IsEmpty) e.Graphics.DrawRectangle(pen,drag);
        }
        string instruction = list.IsEmpty ? "拖框选中邮件列表（包含未读圆点、发件人、时间和主题）" : "拖框选中列表右侧的阅读窗（包含完整邮件头和正文）";
        TextRenderer.DrawText(e.Graphics, instruction + "   ·   Esc 取消", SystemFonts.MessageBoxFont,
            new Rectangle(0,0,ClientSize.Width,48), Color.White, Color.FromArgb(10,24,32), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }

    private Dictionary<string,double> Ratios(Rectangle r)
    {
        return new Dictionary<string,double> { {"leftRatio", (double)r.Left/targetArea.Width}, {"topRatio", (double)r.Top/targetArea.Height},
            {"rightRatio", (double)r.Right/targetArea.Width}, {"bottomRatio", (double)r.Bottom/targetArea.Height} };
    }

    internal static void Select(Form owner, string[] titles, Dictionary<string,object> data)
    {
        var matches = new List<IntPtr>();
        int self = Process.GetCurrentProcess().Id;
        EnumWindows(delegate(IntPtr handle, IntPtr unused) {
            uint pid;
            GetWindowThreadProcessId(handle,out pid);
            if (pid == self || !IsWindowVisible(handle) || IsIconic(handle)) return true;
            var text = new StringBuilder(1024);
            if (GetWindowText(handle,text,text.Capacity) > 0 && titles.Any(t => text.ToString().IndexOf(t,StringComparison.OrdinalIgnoreCase) >= 0))
                matches.Add(handle);
            return true;
        },IntPtr.Zero);
        if (matches.Count != 1) { MessageBox.Show(owner, "请打开并还原邮箱窗口，填写能唯一匹配它的窗口标题，再点框选。", "框选邮箱区域"); return; }
        IntPtr target = matches[0];
        if (!SetForegroundWindow(target) || GetForegroundWindow() != target) { MessageBox.Show(owner, "请先切换到邮箱，再回到监控设置重新框选。"); return; }
        NativeBounds bounds;
        if (!GetWindowRect(target,out bounds)) return;
        Rectangle area = Rectangle.Intersect(SystemInformation.VirtualScreen, Rectangle.FromLTRB(bounds.Left,bounds.Top,bounds.Right,bounds.Bottom));
        if (area.Width < 160 || area.Height < 100) return;
        using (var picker = new MailRegions(area)) {
            if (picker.ShowDialog() == DialogResult.OK) {
                data["mailConfirmationListCrop"] = picker.Ratios(picker.list);
                data["mailConfirmationBodyCrop"] = picker.Ratios(picker.body);
            }
        }
        owner.Activate();
    }
}
