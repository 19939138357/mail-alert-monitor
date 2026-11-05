package org.example.mailalertalarm;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.widget.LinearLayout;

public final class AlarmActivity extends Activity {
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true); }
        LinearLayout page = MainActivity.page(this);
        MainActivity.text(page, "需要处理\n夜间告警", 36, Color.rgb(153, 49, 32));
        MainActivity.text(page, "闹铃和振动会持续到你点击“已处理”。告警详情请打开 QQ 邮箱或钉钉查看。", 20, Color.DKGRAY);
        MainActivity.text(page, "本助手不展示或保存通知正文。测试响铃也在这里停止。", 15, Color.DKGRAY);
        MainActivity.button(page, "已处理 · 停止响铃", view -> { AlarmService.acknowledge(this); finish(); });
        MainActivity.button(page, "关闭全部夜间守护", view -> { AlarmService.disable(this); finish(); });
    }
}
