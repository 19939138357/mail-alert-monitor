package org.example.mailalertalarm;

import android.app.Notification;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import java.util.ArrayList;
import java.util.List;

public final class AlertListener extends NotificationListenerService {
    private static volatile AlertListener connected;
    private AlertPolicy.Tracker tracker;
    public static boolean ready() { return connected != null; }

    @Override public void onCreate() {
        super.onCreate();
        tracker = new AlertPolicy.Tracker(LocalState.prefs(this).getString("seen_event_hashes", ""), System.currentTimeMillis());
    }
    @Override public void onListenerConnected() {
        super.onListenerConnected();
        connected = this;
        baseline();
    }
    @Override public void onListenerDisconnected() {
        connected = null;
        LocalState.note(this, "通知监听暂时断开；请打开助手检查通知访问权限。");
        super.onListenerDisconnected();
    }
    @Override public void onDestroy() {
        if (connected == this) connected = null;
        super.onDestroy();
    }
    public static void refreshBaseline() { AlertListener listener = connected; if (listener != null) listener.baseline(); }
    private void baseline() {
        try {
            StatusBarNotification[] existing = getActiveNotifications();
            if (existing != null) for (StatusBarNotification item : existing) inspect(item, false);
        } catch (RuntimeException denied) { LocalState.note(this, "无法读取通知，请重新检查通知访问权限。"); }
    }
    @Override public void onNotificationPosted(StatusBarNotification item) {
        if (connected != this || item == null) return;
        boolean eligibleTime = item.getPostTime() >= LocalState.prefs(this).getLong("armed_at", Long.MAX_VALUE);
        try { inspect(item, eligibleTime && LocalState.enabled(this) && AlarmService.running()); }
        catch (RuntimeException unavailable) { LocalState.note(this, "无法解析本次通知，请检查原应用并测试通知内容显示设置。"); }
    }
    @Override public void onNotificationRemoved(StatusBarNotification item) {
        if (item != null) tracker.removed(item.getPackageName(), item.getKey());
    }
    private void inspect(StatusBarNotification item, boolean trigger) {
        // Filter the application before reading any notification text.
        if (item == null || !AlertPolicy.allowedPackage(item.getPackageName(), true, true, true)) return;
        Notification notification = item.getNotification();
        if (notification == null) return;
        boolean summary = (notification.flags & Notification.FLAG_GROUP_SUMMARY) != 0;
        if (summary) return;
        List<String> fields = new ArrayList<String>();
        Bundle extras = notification.extras;
        if (extras != null) {
            add(fields, extras.getCharSequence(Notification.EXTRA_TITLE));
            add(fields, extras.getCharSequence(Notification.EXTRA_TEXT));
            add(fields, extras.getCharSequence(Notification.EXTRA_BIG_TEXT));
            CharSequence[] lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES);
            if (lines != null) for (CharSequence line : lines) add(fields, line);
        }
        AlertPolicy.Candidate candidate = new AlertPolicy.Candidate(item.getPackageName(), item.getKey(), summary, fields);
        long before = tracker.revision();
        boolean ring = tracker.inspect(candidate, trigger ? LocalState.qq(this) : true, trigger ? LocalState.ding(this) : true, trigger ? LocalState.wechat(this) : true, trigger, System.currentTimeMillis());
        if (tracker.revision() != before) LocalState.prefs(this).edit().putString("seen_event_hashes", tracker.snapshot()).apply();
        if (ring) AlarmService.alert(item.getPackageName());
        // 'fields' and the original body are never written, logged, or passed to the alarm screen.
    }
    private static void add(List<String> fields, CharSequence value) { if (value != null) fields.add(value.toString()); }
}
