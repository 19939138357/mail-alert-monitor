package cn.mailmonitor.handset;

import android.content.Context;
import android.graphics.*;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.ViewConfiguration;

/** Fit-center and zoom share the exact destination rectangle used by tap mapping. */
final class FoxmailView extends View {
    interface TapHandler { void onTap(String id, float x, float y); }
    private MonitorApi.Frame frame;
    private final TapHandler handler;
    private final ScaleGestureDetector scale;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final RectF dest = new RectF();
    private final int slop;
    private float zoom=1, dx,dy, firstX,firstY,lastX,lastY;
    private boolean dragged;
    private String downFrame;

    FoxmailView(Context c, TapHandler handler) {
        super(c);
        this.handler=handler;
        slop=ViewConfiguration.get(c).getScaledTouchSlop();
        setContentDescription("Foxmail 邮箱画面。双指缩放，轻点操作。");
        setBackgroundColor(0xff132e35);
        setClickable(true);
        scale=new ScaleGestureDetector(c,new ScaleGestureDetector.SimpleOnScaleGestureListener(){
            @Override public boolean onScale(ScaleGestureDetector g) {
                float next=Math.max(1f,Math.min(5f,zoom*g.getScaleFactor()));
                float ratio=next/zoom, fx=g.getFocusX()-getWidth()/2f,fy=g.getFocusY()-getHeight()/2f;
                dx=fx+(dx-fx)*ratio; dy=fy+(dy-fy)*ratio; zoom=next;
                dragged=true; invalidate(); return true;
            }
        });
        scale.setQuickScaleEnabled(false);
    }

    void setFrame(MonitorApi.Frame value) {
        if (frame != null && value != null && (frame.bitmap.getWidth()!=value.bitmap.getWidth() ||
                frame.bitmap.getHeight()!=value.bitmap.getHeight())) {zoom=1; dx=0; dy=0;}
        frame=value; downFrame=null; invalidate();
    }

    private void updateBounds() {
        if(frame==null){dest.setEmpty();return;}
        int w=frame.bitmap.getWidth(),h=frame.bitmap.getHeight();
        float fit=Math.min((float)getWidth()/w,(float)getHeight()/h)*zoom;
        float dw=w*fit, dh=h*fit;
        float mx=Math.max(0,(dw-getWidth())/2),my=Math.max(0,(dh-getHeight())/2);
        dx=Math.max(-mx,Math.min(mx,dx));dy=Math.max(-my,Math.min(my,dy));
        float l=(getWidth()-dw)/2+dx,t=(getHeight()-dh)/2+dy;
        dest.set(l,t,l+dw,t+dh);
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas); updateBounds();
        if(frame!=null)canvas.drawBitmap(frame.bitmap,null,dest,paint);
    }

    @Override public boolean onTouchEvent(MotionEvent e) {
        scale.onTouchEvent(e);
        float x=e.getX(),y=e.getY();
        switch(e.getActionMasked()){
            case MotionEvent.ACTION_DOWN:
                firstX=lastX=x;firstY=lastY=y;dragged=false;
                downFrame=frame==null?null:frame.id;return true;
            case MotionEvent.ACTION_POINTER_DOWN:
                dragged=true;return true;
            case MotionEvent.ACTION_MOVE:
                if(Math.hypot(x-firstX,y-firstY)>slop)dragged=true;
                if(dragged && e.getPointerCount()==1 && zoom>1) { dx+=x-lastX;dy+=y-lastY;invalidate(); }
                lastX=x;lastY=y;return true;
            case MotionEvent.ACTION_POINTER_UP:
                if(e.getPointerCount()>1) {
                    int keep=e.getActionIndex()==0?1:0;
                    lastX=e.getX(keep);lastY=e.getY(keep);
                }
                return true;
            case MotionEvent.ACTION_UP:
                updateBounds();
                if(!dragged && Math.hypot(x-firstX,y-firstY)<=slop && frame!=null &&
                        frame.id.equals(downFrame) && dest.contains(x,y)){
                    performClick(); handler.onTap(downFrame,(x-dest.left)/dest.width(),(y-dest.top)/dest.height());
                }
                downFrame=null;return true;
            case MotionEvent.ACTION_CANCEL:
                downFrame=null;return true;
            default:return true;
        }
    }

    @Override public boolean performClick(){super.performClick();return true;}
}
