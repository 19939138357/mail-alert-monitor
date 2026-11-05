package org.example.mailalertalarm;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.VibrationEffect;
import android.os.Vibrator;

public final class AlarmService extends Service {
    public static final String ARM = "org.example.mailalertalarm.ARM";
    public static final String TEST = "org.example.mailalertalarm.TEST";
    public static final String ACK = "org.example.mailalertalarm.ACK";
    static final String GUARD_CHANNEL = "night_guard_v1", ALARM_CHANNEL = "night_alarm_v1";
    private static final int GUARD_ID = 41001, ALARM_ID = 41002;
    private static volatile AlarmService instance;
    private final Handler handler = new Handler(android.os.Looper.getMainLooper());
    private MediaPlayer player;
    private Vibrator vibrator;
    private PowerManager.WakeLock wakeLock;
    private AudioManager audio;
    private AudioFocusRequest focus;
    private final AlarmPlaybackState playback = new AlarmPlaybackState();
    private int audioSession;
    private boolean ringing;

    public static boolean running() { return instance != null; }
    public static boolean ringing() { return instance != null && instance.ringing; }
    public static void alert(final String packageName) {
        final AlarmService service = instance;
        if (service != null) service.handler.post(new Runnable() { public void run() {
            if (instance == service && LocalState.enabled(service) &&
                AlertPolicy.allowedPackage(packageName, LocalState.qq(service), LocalState.ding(service), LocalState.wechat(service))) {
                try { service.beginAlarm(packageName, false); }
                catch (RuntimeException denied) { service.failClosed("系统未允许告警响铃，请打开助手检查通知和后台设置。"); }
            }
        }});
    }
    public static void disable(Context context) {
        LocalState.prefs(context).edit().putBoolean("enabled", false).putBoolean("ringing", false).remove("ring_source").apply();
        AlarmService service = instance;
        if (service != null) { service.stopAlarm(); service.stopForeground(STOP_FOREGROUND_REMOVE); service.stopSelf(); }
        context.stopService(new Intent(context, AlarmService.class));
        LocalState.note(context, "夜间守护已关闭。");
    }
    public static void acknowledge(Context context) {
        LocalState.prefs(context).edit().putBoolean("ringing", false).remove("ring_source").apply();
        AlarmService service = instance;
        if (service != null) {
            service.stopAlarm();
            if (LocalState.enabled(context)) service.foreground(false);
            else { service.stopForeground(STOP_FOREGROUND_REMOVE); service.stopSelf(); }
        }
        LocalState.note(context, LocalState.enabled(context) ? "当前告警已处理，夜间守护继续。" : "当前闹铃已停止，夜间守护未开启。");
    }

    @Override public void onCreate() {
        super.onCreate();
        instance = this;
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        NotificationChannel guard = new NotificationChannel(GUARD_CHANNEL, "守护状态", NotificationManager.IMPORTANCE_LOW);
        guard.setSound(null, null);
        NotificationChannel alarm = new NotificationChannel(ALARM_CHANNEL, "夜间告警与处理按钮", NotificationManager.IMPORTANCE_HIGH);
        alarm.setDescription("声音由持续闹铃播放；点已处理才停止。锁屏画面需另开全屏通知权限。");
        alarm.setSound(null, null);
        alarm.enableVibration(false);
        if (manager != null) { manager.createNotificationChannel(guard); manager.createNotificationChannel(alarm); }
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ARM : intent.getAction();
        if (ACK.equals(action)) { acknowledge(this); return LocalState.enabled(this) ? START_STICKY : START_NOT_STICKY; }
        if (!LocalState.notifications(this)) { failClosed("通知权限未开启，请打开助手完成设置。"); return START_NOT_STICKY; }
        if (!TEST.equals(action) && !LocalState.enabled(this)) { stopSelf(); return START_NOT_STICKY; }
        try {
            foreground(ringing);
            if (TEST.equals(action)) beginAlarm("test", true);
            else {
                LocalState.note(this, "夜间守护已开启，等待新的告警通知。");
                if (LocalState.prefs(this).getBoolean("ringing", false)) {
                    String source = LocalState.prefs(this).getString("ring_source", "");
                    if (AlertPolicy.allowedPackage(source, LocalState.qq(this), LocalState.ding(this), LocalState.wechat(this))) beginAlarm(source, false);
                }
            }
        } catch (RuntimeException denied) {
            failClosed("系统未允许启动守护服务，请在助手前台重新开启并检查后台限制。");
            return START_NOT_STICKY;
        }
        return LocalState.enabled(this) ? START_STICKY : START_NOT_STICKY;
    }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void foreground(boolean withPlayback) {
        Notification notification = new Notification.Builder(this, GUARD_CHANNEL)
            .setSmallIcon(R.drawable.ic_alarm).setContentTitle("夜间告警响铃助手")
            .setContentText(withPlayback ? "告警响铃中 · 点开处理" : "守护已开启 · 仅响应指定夜间告警")
            .setOngoing(true).setOnlyAlertOnce(true).setContentIntent(screen(MainActivity.class, 1)).build();
        if (Build.VERSION.SDK_INT >= 34) {
            int type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE;
            if (withPlayback) type |= ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK;
            startForeground(GUARD_ID, notification, type);
        } else startForeground(GUARD_ID, notification);
    }
    private PendingIntent screen(Class<?> activity, int code) {
        return PendingIntent.getActivity(this, code, new Intent(this, activity).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }
    private void beginAlarm(String source, boolean isTest) {
        if (ringing) return;
        if (!LocalState.notifications(this)) { failClosed("通知权限已关闭，守护已停止，请重新设置。"); return; }
        ringing = true;
        if (!isTest) LocalState.prefs(this).edit().putBoolean("ringing", true).putString("ring_source", source).putLong("last_alarm_at", System.currentTimeMillis()).apply();
        foreground(true);
        String safeTitle = isTest ? "本机铃声测试" : (AlertPolicy.WECHAT.equals(source) ? "微信夜间告警" : (AlertPolicy.QQ.equals(source) ? "QQ 邮箱夜间告警" : "钉钉夜间告警"));
        LocalState.note(this, safeTitle + "，持续响铃直到点击已处理。");
        PendingIntent handled = PendingIntent.getService(this, 3, new Intent(this, AlarmService.class).setAction(ACK), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder alarm = new Notification.Builder(this, ALARM_CHANNEL).setSmallIcon(R.drawable.ic_alarm)
            .setContentTitle(safeTitle).setContentText("请检查原应用中的告警。点“已处理”停止声音与振动。")
            .setVisibility(Notification.VISIBILITY_PRIVATE).setCategory(Notification.CATEGORY_ALARM)
            .setOngoing(true).setContentIntent(screen(AlarmActivity.class, 2))
            .addAction(new Notification.Action.Builder(null, "已处理 · 停止响铃", handled).build());
        if (LocalState.fullScreen(this)) alarm.setFullScreenIntent(screen(AlarmActivity.class, 2), true);
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager != null) manager.notify(ALARM_ID, alarm.build());
        startAudio();
        startVibration();
        keepAwake.run();
    }
    private final Runnable keepAwake = new Runnable() { public void run() {
        if (!ringing) return;
        try {
            if (wakeLock == null) {
                PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
                if (power != null) { wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NotificationAlarm:ActiveAlarm"); wakeLock.setReferenceCounted(false); }
            }
            if (wakeLock != null) wakeLock.acquire(120000L);
        } catch (RuntimeException denied) { LocalState.note(AlarmService.this, "闹铃中；系统限制了保持唤醒，请检查后台设置。"); }
        handler.postDelayed(this, 60000L);
    }};
    private void startAudio() {
        final int session = ++audioSession;
        AudioAttributes attributes = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build();
        try {
            playback.start();
            focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE).setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(new AudioManager.OnAudioFocusChangeListener() { public void onAudioFocusChange(int change) {
                    if (!ringing || session != audioSession) return;
                    if (change == AudioManager.AUDIOFOCUS_GAIN) {
                        if (playback.gained()) { handler.removeCallbacks(audioRetry); playFocusedAudio(); }
                    } else if (change < 0) {
                        playback.lost();
                        try { if (player != null && player.isPlaying()) player.pause(); } catch (RuntimeException ignored) { }
                        LocalState.note(AlarmService.this, "通话或其它声音暂时抑制了闹铃；振动继续，每15秒尝试恢复，直到点击已处理。");
                        scheduleAudioRetry();
                    }
                }}).build();
            audioRetry.run();
        } catch (Exception unavailable) {
            stopAudio();
            LocalState.note(this, "声音初始化失败，振动继续；请打开助手重做铃声测试。");
        }
    }
    private final Runnable audioRetry = new Runnable() { public void run() {
        if (!ringing || !playback.waiting()) return;
        if (playback.mayRequest(android.os.SystemClock.elapsedRealtime())) {
            try {
                if (audio != null && focus != null && audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    if (playback.gained()) playFocusedAudio();
                } else LocalState.note(AlarmService.this, "系统暂未授予声音焦点；振动继续，每15秒尝试恢复，直到点击已处理。");
            } catch (RuntimeException denied) { LocalState.note(AlarmService.this, "系统暂时限制闹铃声音；振动继续，稍后重试。"); }
        }
        if (ringing && playback.waiting()) scheduleAudioRetry();
    }};
    private void scheduleAudioRetry() {
        handler.removeCallbacks(audioRetry);
        if (ringing && playback.waiting()) handler.postDelayed(audioRetry, AlarmPlaybackState.RETRY_MILLIS);
    }
    private void playFocusedAudio() {
        if (!ringing || !playback.mayPlay()) return;
        try {
            if (player == null) {
                player = new MediaPlayer();
                player.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
                try (AssetFileDescriptor file = getResources().openRawResourceFd(R.raw.night_alarm)) {
                    player.setDataSource(file.getFileDescriptor(), file.getStartOffset(), file.getLength());
                }
                player.setLooping(true);
                player.prepare();
            }
            if (!player.isPlaying()) player.start();
        } catch (Exception unavailable) {
            stopAudio();
            LocalState.note(this, "铃声播放失败，振动继续；请打开助手重做铃声测试。");
        }
    }
    private void startVibration() {
        try {
            vibrator = (Vibrator) getSystemService(VIBRATOR_SERVICE);
            if (vibrator != null && vibrator.hasVibrator()) vibrator.vibrate(VibrationEffect.createWaveform(new long[]{0, 800, 300, 800, 500}, 0), new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());
        } catch (RuntimeException denied) { LocalState.note(this, "系统限制了振动，请检查声音与振动设置。"); }
    }
    private void stopAudio() {
        audioSession++;
        playback.stop();
        handler.removeCallbacks(audioRetry);
        if (player != null) { try { player.stop(); } catch (RuntimeException ignored) { } player.release(); player = null; }
        if (audio != null && focus != null) { try { audio.abandonAudioFocusRequest(focus); } catch (RuntimeException ignored) { } focus = null; }
    }
    private void stopAlarm() {
        ringing = false;
        handler.removeCallbacks(keepAwake);
        stopAudio();
        if (vibrator != null) { try { vibrator.cancel(); } catch (RuntimeException ignored) { } vibrator = null; }
        if (wakeLock != null) { try { if (wakeLock.isHeld()) wakeLock.release(); } catch (RuntimeException ignored) { } wakeLock = null; }
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager != null) manager.cancel(ALARM_ID);
    }
    private void failClosed(String message) {
        LocalState.note(this, message);
        LocalState.prefs(this).edit().putBoolean("enabled", false).putBoolean("ringing", false).remove("ring_source").apply();
        stopAlarm(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf();
    }
    @Override public void onDestroy() {
        stopAlarm();
        if (instance == this) instance = null;
        // An acknowledged/disabled alarm was already cleared. A system-killed active
        // armed alarm may resume through START_STICKY; a manual test is never saved.
        super.onDestroy();
    }
}
