package org.example.mailalertalarm;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

public final class MainActivity extends Activity {
    private TextView status;
    private final Handler handler = new Handler();
    private final Runnable refresh = new Runnable() { public void run() { renderStatus(); handler.postDelayed(this, 1500); }};
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout page = page(this);
        text(page, "夜间告警\n响铃助手", 30, Color.rgb(26, 49, 43));
        text(page, "只响应所选微信、QQ 邮箱或钉钉通知中的【夜间告警】。普通聊天和验证码不会触发持续闹铃。", 16, Color.DKGRAY);
        status = text(page, "", 15, Color.rgb(37, 106, 96));
        text(page, "1. 选择接收告警的应用", 20, Color.BLACK);
        CheckBox wechat = new CheckBox(this); wechat.setText("微信"); wechat.setTextSize(17); wechat.setChecked(LocalState.wechat(this)); page.addView(wechat);
        CheckBox qq = new CheckBox(this); qq.setText("QQ 邮箱"); qq.setTextSize(17); qq.setChecked(LocalState.qq(this)); page.addView(qq);
        CheckBox ding = new CheckBox(this); ding.setText("钉钉"); ding.setTextSize(17); ding.setChecked(LocalState.ding(this)); page.addView(ding);
        qq.setOnCheckedChangeListener((button, checked) -> changeSource("qq", checked));
        ding.setOnCheckedChangeListener((button, checked) -> changeSource("ding", checked));
        wechat.setOnCheckedChangeListener((button, checked) -> changeSource("wechat", checked));
        text(page, "更改应用会立即停止当前守护和闹铃，需要重新开启。", 13, Color.DKGRAY);
        text(page, "微信须开启通知详情，接收会话不可免打扰。若公众号只显示通用提醒、未显示【夜间告警】，助手不会响；需先激活正文显示并完成真实锁屏告警测试。", 14, Color.DKGRAY);
        text(page, "2. 完成手机设置", 20, Color.BLACK);
        button(page, "允许读取通知", view -> open(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)));
        button(page, "允许显示通知", view -> notificationPermission());
        button(page, "允许锁屏全屏提醒", view -> {
            if (Build.VERSION.SDK_INT >= 34) open(new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + getPackageName())));
            else toast("此版本由系统通知设置控制锁屏提醒。");
        });
        button(page, "闹钟音量与勿扰设置", view -> open(new Intent(Settings.ACTION_SOUND_SETTINGS)));
        button(page, "后台与省电设置", view -> open(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)));
        text(page, "在系统中允许闹钟打破勿扰，并将本助手和收件应用设为不受省电限制。国产手机还可能需要允许自启动、后台运行和锁屏通知。", 14, Color.DKGRAY);
        text(page, "3. 测试后开启守护", 20, Color.BLACK);
        button(page, "本机铃声测试", view -> {
            if (!LocalState.notifications(this)) { notificationPermission(); return; }
            if (start(new Intent(this, AlarmService.class).setAction(AlarmService.TEST))) startActivity(new Intent(this, AlarmActivity.class));
        });
        button(page, "开启夜间守护", view -> arm());
        button(page, "已处理 · 停止当前闹铃", view -> { AlarmService.acknowledge(this); renderStatus(); });
        button(page, "关闭夜间守护", view -> { AlarmService.disable(this); LocalState.note(this, "守护已关闭。"); renderStatus(); });
        text(page, "首次安装默认关闭。本应用不联网，不保存通知正文，只保存去重哈希和开关。重启手机、强行停止应用后，请打开助手重新开启。\n\n请先用真实告警在手机锁屏状态下验收；收件延迟、通知内容被隐藏、勿扰和厂商后台限制都会影响叫醒。", 14, Color.DKGRAY);
    }
    private void changeSource(String key, boolean selected) {
        AlarmService.disable(this);
        LocalState.prefs(this).edit().putBoolean(key, selected).apply();
        AlertListener.refreshBaseline();
        LocalState.note(this, "接收应用已更改，请重新开启守护。");
        renderStatus();
    }
    private void arm() {
        if (!LocalState.qq(this) && !LocalState.ding(this) && !LocalState.wechat(this)) { toast("请先至少选择一个接收应用。"); return; }
        if (!LocalState.listenerPermission(this)) { toast("请先允许读取通知。"); open(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); return; }
        if (!LocalState.notifications(this)) { notificationPermission(); return; }
        if (!AlertListener.ready()) { toast("通知监听器尚在连接，请稍候重新点击开启；必要时重新开关通知访问权限。"); return; }
        AlertListener.refreshBaseline();
        LocalState.prefs(this).edit().putLong("armed_at", System.currentTimeMillis()).putBoolean("enabled", true).apply();
        start(new Intent(this, AlarmService.class).setAction(AlarmService.ARM));
        renderStatus();
    }
    private boolean start(Intent service) {
        try { startForegroundService(service); return true; }
        catch (RuntimeException denied) { AlarmService.disable(this); toast("系统未允许启动，请检查通知权限与后台限制后重试。"); return false; }
    }
    private void notificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 10);
        else open(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()));
    }
    private void open(Intent intent) {
        try { startActivity(intent); }
        catch (RuntimeException unavailable) {
            try { startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))); }
            catch (RuntimeException missing) { toast("请到手机设置中查找本助手，手动开启相关权限。"); }
        }
    }
    private void toast(String text) { Toast.makeText(this, text, Toast.LENGTH_LONG).show(); }
    private void renderStatus() {
        if (status == null) return;
        String state = AlarmService.ringing() ? "正在持续响铃" : LocalState.enabled(this) && AlarmService.running() ? "夜间守护已开启" : "夜间守护未运行";
        AudioManager audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        int volume = audio == null ? 0 : audio.getStreamVolume(AudioManager.STREAM_ALARM);
        int maximum = audio == null ? 0 : audio.getStreamMaxVolume(AudioManager.STREAM_ALARM);
        PowerManager power = (PowerManager) getSystemService(POWER_SERVICE);
        String battery = power != null && power.isIgnoringBatteryOptimizations(getPackageName()) ? "已免省电优化" : "请检查省电限制";
        status.setText(state + "\n通知访问：" + (LocalState.listenerPermission(this) ? "已允许" : "未允许") +
            " · 监听连接：" + (AlertListener.ready() ? "已连接" : "未连接") +
            "\n通知显示：" + (LocalState.notifications(this) ? "已允许" : "未允许") +
            " · 全屏提醒：" + (LocalState.fullScreen(this) ? "系统允许" : "未允许") +
            "\n闹钟音量：" + volume + "/" + maximum + " · " + battery +
            "\n" + LocalState.prefs(this).getString("status", "完成设置后，先测试再开启。"));
    }
    @Override protected void onResume() { super.onResume(); handler.removeCallbacks(refresh); refresh.run(); }
    @Override protected void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    @Override protected void onDestroy() { handler.removeCallbacks(refresh); super.onDestroy(); }

    static LinearLayout page(Activity activity) {
        ScrollView scroll = new ScrollView(activity);
        scroll.setFillViewport(true); scroll.setBackgroundColor(Color.rgb(245, 247, 245));
        LinearLayout page = new LinearLayout(activity); page.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(24 * activity.getResources().getDisplayMetrics().density);
        page.setPadding(pad, pad, pad, pad); scroll.addView(page); activity.setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> { view.setPadding(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom()); return insets; });
        return page;
    }
    static TextView text(LinearLayout parent, String value, int size, int color) {
        TextView text = new TextView(parent.getContext()); text.setText(value); text.setTextSize(size); text.setTextColor(color); text.setPadding(0, 12, 0, 18); parent.addView(text); return text;
    }
    static Button button(LinearLayout parent, String value, View.OnClickListener action) {
        Button button = new Button(parent.getContext()); button.setText(value); button.setTextSize(16); button.setAllCaps(false); button.setMinHeight(56); button.setOnClickListener(action); parent.addView(button); return button;
    }
}
