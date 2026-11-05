package org.example.mailalertalarm;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure local rules. Notification contents never enter persisted state. */
public final class AlertPolicy {
    public static final String QQ = "com.tencent.androidqqmail";
    public static final String DING = "com.alibaba.android.rimet";
    public static final String WECHAT = "com.tencent.mm";
    public static final String PREFIX = "【夜间告警】";
    private static final Pattern EVENT = Pattern.compile("\\[事件:([A-Za-z0-9_-]{8,64})\\]");
    private static final long RETENTION = 7L * 24 * 60 * 60 * 1000;
    private static final int MAX_EVENTS = 512;

    public static boolean allowedPackage(String name, boolean qq, boolean ding) {
        return allowedPackage(name, qq, ding, false);
    }
    public static boolean allowedPackage(String name, boolean qq, boolean ding, boolean wechat) {
        return (qq && QQ.equals(name)) || (ding && DING.equals(name)) || (wechat && WECHAT.equals(name));
    }

    public static String hash(String text) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder(64);
            for (byte b : bytes) out.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            return out.toString();
        } catch (Exception impossible) { throw new IllegalStateException("SHA-256 unavailable"); }
    }

    public static final class Candidate {
        public final String packageName, key;
        public final boolean summary;
        public final List<String> fields;
        public Candidate(String name, String key, boolean summary, List<String> fields) {
            this.packageName = name;
            this.key = key == null ? "" : key;
            this.summary = summary;
            this.fields = fields == null ? new ArrayList<String>() : fields;
        }
    }

    public static final class Tracker {
        private final LinkedHashMap<String, Long> seen = new LinkedHashMap<String, Long>();
        private final Set<String> activeFallbackKeys = new HashSet<String>();
        private long revision;

        public Tracker(String saved, long now) {
            if (saved != null) for (String line : saved.split("\n")) {
                String[] parts = line.split(":");
                if (parts.length != 2 || !parts[0].matches("[a-f0-9]{64}")) continue;
                try { seen.put(parts[0], Long.parseLong(parts[1])); } catch (NumberFormatException ignored) { }
            }
            prune(now);
        }

        public synchronized boolean inspect(Candidate candidate, boolean qq, boolean ding, boolean trigger, long now) {
            return inspect(candidate, qq, ding, false, trigger, now);
        }
        public synchronized boolean inspect(Candidate candidate, boolean qq, boolean ding, boolean wechat, boolean trigger, long now) {
            if (candidate == null || candidate.summary || !allowedPackage(candidate.packageName, qq, ding, wechat)) return false;
            boolean tagged = false;
            for (String field : candidate.fields) if (field != null && field.contains(PREFIX)) tagged = true;
            if (!tagged) return false;
            String eventId = null;
            for (String field : candidate.fields) if (field != null) {
                Matcher match = EVENT.matcher(field);
                if (match.find()) { eventId = match.group(1); break; }
            }
            prune(now);
            if (eventId != null) {
                String digest = hash(candidate.packageName + "\n" + eventId);
                boolean fresh = !seen.containsKey(digest);
                if (fresh) { seen.put(digest, now); revision++; prune(now); }
                return trigger && fresh;
            }
            // Without a unique event marker an updated notification is ambiguous.
            // Ring once until the original source notification is removed.
            boolean fresh = activeFallbackKeys.add(hash(candidate.packageName + "\n" + candidate.key));
            return trigger && fresh;
        }

        public synchronized void removed(String packageName, String key) {
            activeFallbackKeys.remove(hash(packageName + "\n" + key));
        }

        public synchronized long revision() { return revision; }
        public synchronized String snapshot() {
            StringBuilder out = new StringBuilder();
            for (Map.Entry<String, Long> entry : seen.entrySet()) out.append(entry.getKey()).append(':').append(entry.getValue()).append('\n');
            return out.toString();
        }
        private void prune(long now) {
            Iterator<Map.Entry<String, Long>> iterator = seen.entrySet().iterator();
            while (iterator.hasNext()) {
                Map.Entry<String, Long> entry = iterator.next();
                if (entry.getValue() < now - RETENTION || entry.getValue() > now + RETENTION) { iterator.remove(); revision++; }
            }
            while (seen.size() > MAX_EVENTS) { seen.remove(seen.keySet().iterator().next()); revision++; }
        }
    }
}
