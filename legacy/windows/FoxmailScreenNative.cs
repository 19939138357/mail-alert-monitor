using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading;

public static class FoxmailScreenNative {
    // Only scan the leading column of the calibrated list. Work in local pixels
    // so a blue toolbar or a wide selected row cannot be mistaken for a dot.
    public static Point[] Dots(Bitmap bitmap) {
        int w=Math.Min(bitmap.Width,Math.Max(40,(int)(bitmap.Width*0.22))), h=bitmap.Height;
        if (h>8000 || w*h>4000000) return new Point[0];
        var mask=new bool[w*h]; var queue=new int[w*h];
        BitmapData data=bitmap.LockBits(new Rectangle(0,0,w,h),ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
        try {
            var row=new byte[w*4];
            for(int y=0;y<h;y++) {
                Marshal.Copy(IntPtr.Add(data.Scan0,y*data.Stride),row,0,row.Length);
                for(int x=0;x<w;x++) {
                    int b=row[4*x],g=row[4*x+1],r=row[4*x+2];
                    mask[y*w+x]=b>145 && g>65 && r<170 && b-r>45 && g-r>12;
                }
            }
        } finally {bitmap.UnlockBits(data);}
        var result=new List<Point>();
        for(int i=0;i<mask.Length;i++) {
            if(!mask[i]) continue;
            int start=0,end=1,minX=w,minY=h,maxX=0,maxY=0;
            queue[0]=i; mask[i]=false;
            while(start<end) {
                int n=queue[start++],x=n%w,y=n/w;
                minX=Math.Min(minX,x);minY=Math.Min(minY,y);maxX=Math.Max(maxX,x);maxY=Math.Max(maxY,y);
                if(x>0) AddPixel(mask,queue,n-1,ref end);
                if(x<w-1) AddPixel(mask,queue,n+1,ref end);
                if(y>0) AddPixel(mask,queue,n-w,ref end);
                if(y<h-1) AddPixel(mask,queue,n+w,ref end);
            }
            int dw=maxX-minX+1,dh=maxY-minY+1;
            if(dw>=3 && dh>=3 && dw<=32 && dh<=32 && dw>=0.55*dh && dw<=1.8*dh && end>=5 && end>0.35*dw*dh && maxX<w-1)
                result.Add(new Point((minX+maxX)/2,(minY+maxY)/2));
        }
        return result.ToArray();
    }
    static void AddPixel(bool[] mask,int[] q,int i,ref int end) {
        if(mask[i]) { mask[i]=false;q[end++]=i; }
    }

    // Positive evidence for the classic remote Foxmail vertical scrollbar.
    // Require matching opposing arrowheads, a light neutral track and a thumb
    // that reaches the lower arrow button. An arbitrary cropped white margin
    // or a static screen after wheel input is never enough.
    static bool Neutral(Color c,int low,int high) {
        int min=Math.Min(c.R,Math.Min(c.G,c.B)),max=Math.Max(c.R,Math.Max(c.G,c.B));
        return min>=low && max<=high && max-min<=18;
    }
    static bool Arrow(Bitmap image,int x,int tip,int direction) {
        // At 100% scale the tip is one pixel wide. Allow 125-200% scaling.
        for(int scale=1;scale<=2;scale++) {
            int wideY=tip-direction*3*scale,midY=tip-direction*scale;
            if(wideY<0 || wideY>=image.Height || midY<0 || midY>=image.Height || x-6*scale<0 || x+6*scale>=image.Width) continue;
            if(Neutral(image.GetPixel(x,tip),12,160) && Neutral(image.GetPixel(x,midY),12,160) &&
               Neutral(image.GetPixel(x-2*scale,wideY),12,160) && Neutral(image.GetPixel(x+2*scale,wideY),12,160) &&
               Neutral(image.GetPixel(x-3*scale,tip),190,255) && Neutral(image.GetPixel(x+3*scale,tip),190,255) &&
               Neutral(image.GetPixel(x-5*scale,wideY),190,255) && Neutral(image.GetPixel(x+5*scale,wideY),190,255)) return true;
        }
        return false;
    }
    public static bool ScrollbarAtEnd(Bitmap image) {
        int w=image.Width,h=image.Height;
        if(w<100 || h<100) return false;
        for(int x=w-24;x<w-6;x++) for(int lower=h-24;lower<h-2;lower++) {
            if(!Arrow(image,x,lower,1)) continue;
            int upper=0;
            for(int y=2;y<h/2;y++) if(Arrow(image,x,y,-1)) {upper=y;break;}
            if(upper==0 || lower-upper<60) continue;
            // A real bottom thumb occupies the strip immediately above the
            // lower button. Verify its width, height, and lighter side gutter.
            for(int gap=6;gap<=17;gap++) {
                int end=lower-gap,run=0;
                for(int y=end;y>=upper+8;y--) {
                    Color l=image.GetPixel(x-3,y),r=image.GetPixel(x+3,y);
                    if(!Neutral(l,85,210) || !Neutral(r,85,210) || Math.Abs(l.R-r.R)>14) break;
                    run++;
                }
                if(run<14) continue;
                bool track=false;
                for(int y=end-run-1;y>upper+7;y--) {
                    if(Neutral(image.GetPixel(x,y),218,255)){track=true;break;}
                }
                // Without a distinct thumb and remaining track, its position is ambiguous.
                if(track && Neutral(image.GetPixel(x-8,end-5),211,255)) return true;
            }
        }
        return false;
    }
    [StructLayout(LayoutKind.Sequential)] struct LAST { public uint size,tick; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LAST input);
    public static long InputStamp() {
        var info=new LAST{size=(uint)Marshal.SizeOf(typeof(LAST))};
        return GetLastInputInfo(ref info) ? (long)info.tick : -1L;
    }
    [StructLayout(LayoutKind.Sequential)] struct XY {public int X,Y;}
    [StructLayout(LayoutKind.Sequential)] struct RECT {public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)] struct MOUSE { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type;public MOUSE mouse;}
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(XY point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd,uint flag);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out XY p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint count,INPUT[] events,int size);
    static bool Matches(IntPtr hwnd,int left,int top,int width,int height,XY p) {
        RECT r;
        return GetForegroundWindow()==hwnd && GetAncestor(WindowFromPoint(p),2)==hwnd && GetWindowRect(hwnd,out r) &&
            r.Left==left && r.Top==top && r.Right-r.Left==width && r.Bottom-r.Top==height;
    }
    public static bool Wheel(IntPtr hwnd,int left,int top,int width,int height,int x,int y,int delta) {
        var p=new XY{X=x,Y=y};XY old,current;
        if(!Matches(hwnd,left,top,width,height,p) || !GetCursorPos(out old) || !SetCursorPos(x,y)) return false;
        try {
            if(!Matches(hwnd,left,top,width,height,p)) return false;
            var input=new INPUT {mouse=new MOUSE{data=unchecked((uint)delta),flags=0x0800}};
            bool sent=SendInput(1,new INPUT[]{input},Marshal.SizeOf(typeof(INPUT)))==1;
            Thread.Sleep(90);
            return sent;
        } finally {
            if(GetCursorPos(out current) && current.X==x && current.Y==y) SetCursorPos(old.X,old.Y);
        }
    }
}
