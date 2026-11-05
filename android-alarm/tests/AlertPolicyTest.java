package org.example.mailalertalarm;

import java.util.Arrays;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

public final class AlertPolicyTest {
    private static int checks;
    private static void check(boolean condition, String name) {
        checks++;
        if (!condition) throw new AssertionError(name);
    }
    private static AlertPolicy.Candidate item(String pkg, String key, String... fields) {
        return new AlertPolicy.Candidate(pkg, key, false, Arrays.asList(fields));
    }
    private static String alert(String id) { return "【夜间告警】测试 [事件:" + id + "]"; }
    public static void main(String[] args) {
        long now = 1788800000000L;
        AlertPolicy.Tracker tracker = new AlertPolicy.Tracker("", now);
        check(!tracker.inspect(item(AlertPolicy.QQ, "1", "验证码：001234"), true, true, true, now), "ordinary OTP ignored");
        check(!tracker.inspect(item(AlertPolicy.QQ, "2", "夜间告警测试"), true, true, true, now), "exact prefix required");
        check(!tracker.inspect(item("com.tencent.mm", "3", alert("aaaaaaaa")), true, true, true, now), "other app rejected");
        check(!tracker.inspect(item(AlertPolicy.QQ + ".fake", "4", alert("aaaaaaaa")), true, true, true, now), "package suffix spoof rejected");
        check(!tracker.inspect(item(AlertPolicy.QQ, "5", alert("aaaaaaaa")), false, true, true, now), "unselected QQ ignored");
        check(!tracker.inspect(item(AlertPolicy.DING, "6", alert("aaaaaaaa")), true, false, true, now), "unselected DingTalk ignored");
        check(!tracker.inspect(new AlertPolicy.Candidate(AlertPolicy.QQ, "7", true, Arrays.asList(alert("aaaaaaaa"))), true, true, true, now), "group summaries ignored");
        check(tracker.inspect(item(AlertPolicy.QQ, "8", alert("aaaaaaaa")), true, false, true, now), "first explicit QQ alert rings");
        check(!tracker.inspect(item(AlertPolicy.QQ, "8", alert("aaaaaaaa"), "unread count changed"), true, false, true, now), "notification update does not ring");
        check(!tracker.inspect(item(AlertPolicy.QQ, "new-key", alert("aaaaaaaa")), true, false, true, now), "same event under new key does not ring");
        check(tracker.inspect(item(AlertPolicy.QQ, "8", alert("bbbbbbbb")), true, false, true, now), "new event reusing notification key rings");
        check(tracker.inspect(item(AlertPolicy.DING, "8", "安全关键字", alert("aaaaaaaa")), true, true, true, now), "DingTalk prefix need not be first field");
        check(tracker.inspect(item(AlertPolicy.QQ, "9", "标题", "普通摘要", "正文 " + alert("cccccccc")), true, false, true, now), "big text field can carry marker");
        check(tracker.inspect(item(AlertPolicy.QQ, "10", "标题", "预览", "第一行", alert("dddddddd")), true, false, true, now), "text lines can carry marker");
        check(tracker.inspect(item(AlertPolicy.QQ, "11", "【夜间告警】无事件标记"), true, false, true, now), "fallback first notification rings");
        check(!tracker.inspect(item(AlertPolicy.QQ, "11", "【夜间告警】展开正文变化"), true, false, true, now), "fallback update suppressed");
        tracker.removed(AlertPolicy.QQ, "11");
        check(tracker.inspect(item(AlertPolicy.QQ, "11", "【夜间告警】新的通知"), true, false, true, now), "fallback key freed only on source removal");

        AlertPolicy.Candidate old = item(AlertPolicy.QQ, "old", alert("oldalert1"));
        check(!tracker.inspect(old, true, true, false, now), "baseline never rings");
        check(!tracker.inspect(old, true, true, true, now), "baseline old event stays suppressed");
        check(!tracker.inspect(item(AlertPolicy.QQ, "old-fallback", "【夜间告警】旧通知"), true, true, false, now), "fallback baseline never rings");
        check(!tracker.inspect(item(AlertPolicy.QQ, "old-fallback", "【夜间告警】旧通知更新"), true, true, true, now), "fallback baseline update suppressed");
        String snapshot = tracker.snapshot();
        check(!snapshot.contains("夜间告警") && !snapshot.contains("oldalert1") && !snapshot.contains(AlertPolicy.QQ), "persisted state contains no body event ID or package");
        check(snapshot.matches("(?:[a-f0-9]{64}:[0-9]+\\n)*"), "only SHA256 plus timestamp persisted");
        AlertPolicy.Tracker restarted = new AlertPolicy.Tracker(snapshot, now);
        check(!restarted.inspect(old, true, true, true, now), "event dedup survives process restart");
        check(new AlertPolicy.Tracker("invalid\n123:foo\n", now).snapshot().isEmpty(), "malformed saved data ignored");
        check(new AlertPolicy.Tracker(snapshot, now + 8L * 86400000L).snapshot().isEmpty(), "event history expires after seven days");
        check(!tracker.inspect(null, true, true, true, now), "null notification safe");
        check(!tracker.inspect(new AlertPolicy.Candidate(AlertPolicy.QQ, null, false, null), true, true, true, now), "missing fields safe");

        Random random = new Random(90308L);
        for (int index = 0; index < 300; index++) {
            String id = String.format(java.util.Locale.ROOT, "%08x%08x", index, random.nextInt());
            String pkg = index % 2 == 0 ? AlertPolicy.QQ : AlertPolicy.DING;
            List<String> fields = new ArrayList<String>();
            fields.add("普通验证码 012345"); fields.add("安全关键词");
            fields.add(random.nextInt(fields.size() + 1), "姓名前缀 " + alert(id));
            AlertPolicy.Candidate candidate = new AlertPolicy.Candidate(pkg, "reused-key", false, fields);
            check(tracker.inspect(candidate, true, true, true, now + index), "seeded distinct alert rings");
            check(!tracker.inspect(candidate, true, true, true, now + index + 1), "seeded duplicate suppressed");
            AlertPolicy.Tracker replay = new AlertPolicy.Tracker(tracker.snapshot(), now + index);
            check(!replay.inspect(candidate, true, true, true, now + index), "seeded persistent duplicate suppressed");
        }
        for (int index = 0; index < 600; index++) tracker.inspect(item(AlertPolicy.QQ, "key", alert("bounded" + index)), true, true, false, now + index);
        check(tracker.snapshot().split("\n").length <= 512, "persistent history bounded");
        AlertPolicy.Tracker wechat = new AlertPolicy.Tracker("", now);
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"wx","普通聊天"),false,false,true,true,now),"ordinary WeChat chat does not ring");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"wx","验证码：001234"),false,false,true,true,now),"WeChat OTP does not ring");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"wx",alert("wechat01")),true,true,false,true,now),"disabled WeChat does not ring");
        check(!wechat.inspect(item(AlertPolicy.WECHAT+".fake","wx",alert("wechat01")),false,false,true,true,now),"fake WeChat package ignored");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"wx","收到一条新的消息，请查看详情"),false,false,true,true,now),"hidden preview cannot create a false alarm");
        check(wechat.inspect(item(AlertPolicy.WECHAT,"wx","PushPlus",alert("wechat01")),false,false,true,true,now),"WeChat message body marker rings");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"wx2",alert("wechat01")),false,false,true,true,now),"WeChat same event deduplicated across IDs");
        check(wechat.inspect(item(AlertPolicy.WECHAT,"wx",alert("wechat02")),false,false,true,true,now),"new WeChat alert with reused ID rings");
        AlertPolicy.Tracker restoredWeChat = new AlertPolicy.Tracker(wechat.snapshot(),now);
        check(!restoredWeChat.inspect(item(AlertPolicy.WECHAT,"wx",alert("wechat02")),false,false,true,true,now),"WeChat dedup survives restart");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"old",alert("wechat03")),false,false,true,false,now),"WeChat baseline does not ring");
        check(!wechat.inspect(item(AlertPolicy.WECHAT,"old",alert("wechat03")),false,false,true,true,now),"WeChat old notification stays baseline");
        check(!wechat.inspect(item(AlertPolicy.QQ,"qq",alert("wechat04")),false,false,true,true,now),"WeChat-only choice excludes QQ");
        check(!wechat.inspect(item(AlertPolicy.DING,"ding",alert("wechat05")),false,false,true,true,now),"WeChat-only choice excludes DingTalk");
        System.out.println("PASS: " + checks + " local alert policy assertions; no Android device or network used.");
    }
}
