package org.example.mailalertalarm;

/** Clock-injected state gate: delayed callbacks cannot resurrect an acknowledged alarm. */
public final class AlarmPlaybackState {
    public static final long RETRY_MILLIS = 15000L;
    private boolean active, focused;
    private long nextRequest;
    public void start() { active = true; focused = false; nextRequest = 0L; }
    public void stop() { active = false; focused = false; nextRequest = Long.MAX_VALUE; }
    public boolean mayRequest(long elapsedMillis) {
        if (!active || focused || elapsedMillis < nextRequest) return false;
        nextRequest = elapsedMillis + RETRY_MILLIS;
        return true;
    }
    public boolean gained() { if (!active) return false; focused = true; return true; }
    public void lost() { focused = false; }
    public boolean waiting() { return active && !focused; }
    public boolean mayPlay() { return active && focused; }
}
