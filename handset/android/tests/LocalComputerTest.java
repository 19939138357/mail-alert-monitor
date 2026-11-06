package cn.mailmonitor.handset;

public final class LocalComputerTest {
    public static void main(String[] args) {
        String[] accepted = {"10.0.0.1", "192.168.1.25", "172.16.0.1", "172.31.255.254", "100.64.0.1", "100.127.255.254"};
        String[] rejected = {"192.168.01.2", "0.0.0.0", "127.0.0.1", "::1", "100.63.255.255", "100.128.1.1", "100.64.0.256",
                             "172.15.2.1", "172.32.2.1", "8.8.8.8", "10.0.0.1:443", "192.168...", "192.168.3.4/m", "10.0.0.1\n", null};
        for (String a : accepted) if (!LocalComputer.privateIPv4(a)) throw new AssertionError("expected private address");
        for (String a : rejected) if (LocalComputer.privateIPv4(a)) throw new AssertionError("rejected address accepted");
        System.out.println((accepted.length + rejected.length) + " address checks passed");
    }
}
