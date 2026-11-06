package cn.mailmonitor.handset;

final class LocalComputer {
    static final int PORT = 48763;
    final String name, address;
    final int port;

    LocalComputer(String name, String address, int port) {
        this.name = name;
        this.address = address;
        this.port = port;
    }

    static boolean privateIPv4(String address) {
        if (address == null || address.length() > 15) return false;
        String[] parts = address.split("\\.", -1);
        if (parts.length != 4) return false;
        int[] n = new int[4];
        for (int i = 0; i < parts.length; i++) {
            String part = parts[i];
            if (!part.matches("0|[1-9][0-9]{0,2}")) return false;
            n[i] = Integer.parseInt(part);
            if (n[i] > 255) return false;
        }
        return n[0] == 10 || n[0] == 172 && n[1] >= 16 && n[1] < 32
                || n[0] == 192 && n[1] == 168 || n[0] == 100 && n[1] >= 64 && n[1] < 128;
    }

    String endpoint() { return address + ":" + port; }
}
