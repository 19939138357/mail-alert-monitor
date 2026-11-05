package org.example.mailalertalarm;

import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.provider.Settings;

final class LocalState {
    static SharedPreferences prefs(Context context) { return context.getSharedPreferences("local_alarm_v1", Context.MODE_PRIVATE); }
    static boolean enabled(Context context) { return prefs(context).getBoolean("enabled", false); }
    static boolean qq(Context context) { return prefs(context).getBoolean("qq", false); }
    static boolean ding(Context context) { return prefs(context).getBoolean("ding", false); }
    static boolean wechat(Context context) { return prefs(context).getBoolean("wechat", true); }
    static boolean notifications(Context context) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (manager == null || !manager.areNotificationsEnabled()) return false;
        android.app.NotificationChannel guard = manager.getNotificationChannel(AlarmService.GUARD_CHANNEL);
        android.app.NotificationChannel alarm = manager.getNotificationChannel(AlarmService.ALARM_CHANNEL);
        return (guard == null || guard.getImportance() != NotificationManager.IMPORTANCE_NONE) &&
            (alarm == null || alarm.getImportance() != NotificationManager.IMPORTANCE_NONE);
    }
    static boolean listenerPermission(Context context) {
        String enabled = Settings.Secure.getString(context.getContentResolver(), "enabled_notification_listeners");
        ComponentName wanted = new ComponentName(context, AlertListener.class);
        if (enabled != null) for (String item : enabled.split(":")) if (wanted.equals(ComponentName.unflattenFromString(item))) return true;
        return false;
    }
    static boolean fullScreen(Context context) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        return Build.VERSION.SDK_INT < 34 || (manager != null && manager.canUseFullScreenIntent());
    }
    static void note(Context context, String safeStatus) { prefs(context).edit().putString("status", safeStatus).apply(); }
    private LocalState() { }
}
