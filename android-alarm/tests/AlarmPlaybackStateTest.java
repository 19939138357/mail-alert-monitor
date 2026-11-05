package org.example.mailalertalarm;

public final class AlarmPlaybackStateTest {
    private static int checks;
    private static void check(boolean condition, String name) { checks++; if (!condition) throw new AssertionError(name); }
    public static void main(String[] args) {
        AlarmPlaybackState state = new AlarmPlaybackState();
        check(!state.mayRequest(0), "disabled by default");
        check(!state.gained(), "unexpected gain while off ignored");
        state.start();
        check(state.mayRequest(100), "first focus attempt allowed");
        check(state.waiting() && !state.mayPlay(), "denied or delayed focus does not end alarm");
        check(!state.mayRequest(101), "duplicate callback cannot retry immediately");
        check(!state.mayRequest(15099), "retry interval respected");
        check(state.mayRequest(15100), "retry after fifteen seconds allowed");
        check(state.gained() && state.mayPlay(), "delayed gain allows player creation and playback");
        check(!state.mayRequest(999999), "no focus polling while already focused");
        state.lost();
        check(state.waiting() && !state.mayPlay(), "transient or permanent loss pauses and schedules retry");
        check(state.mayRequest(1000000), "permanent loss can recover with bounded retry");
        check(state.gained(), "regained focus can resume existing player");
        state.stop();
        check(!state.waiting() && !state.mayPlay(), "acknowledgement ends playback state");
        check(!state.gained(), "late gain after acknowledgement cannot restart alarm");
        check(!state.mayRequest(Long.MAX_VALUE - 1), "late timer after stop cannot request focus");
        state.start();
        check(state.mayRequest(2000000), "new independent alarm can start");
        state.stop(); state.lost();
        check(!state.gained() && !state.mayPlay(), "loss and gain after disable remain inactive");
        for (int cycle = 0; cycle < 100; cycle++) {
            state.start();
            check(state.mayRequest(cycle * 100000L), "new lifecycle first request");
            state.stop();
            check(!state.mayRequest(cycle * 100000L + 15000L) && !state.gained(), "queued callbacks after shutdown rejected");
        }
        System.out.println("PASS: " + checks + " audio-focus lifecycle assertions; no sound played.");
    }
}
