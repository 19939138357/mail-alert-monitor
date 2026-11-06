package cn.mailmonitor.handset;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Activity-scoped DNS-SD browser. Old Android releases allow only one pending resolve. */
final class MacDiscovery {
    interface Listener { void changed(List<LocalComputer> computers, boolean available); }
    private static final String TYPE = "_mailmonctl._tcp.";
    private final NsdManager nsd;
    private final Handler main;
    private final Listener listener;
    private Browse active;

    MacDiscovery(NsdManager nsd, Handler main, Listener listener) {
        this.nsd = nsd;
        this.main = main;
        this.listener = listener;
    }

    void start() {
        if (active != null) return;
        active = new Browse();
        try { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, active); }
        catch (RuntimeException unavailable) { active = null; listener.changed(new ArrayList<>(), false); }
    }

    void stop() {
        Browse old = active;
        active = null;
        if (old != null) {
            try { nsd.stopServiceDiscovery(old); } catch (RuntimeException ignored) { }
        }
    }

    private final class Browse implements NsdManager.DiscoveryListener {
        final Map<String, NsdServiceInfo> seen = new LinkedHashMap<>();
        final Map<String, LocalComputer> resolved = new LinkedHashMap<>();
        final ArrayDeque<NsdServiceInfo> queue = new ArrayDeque<>();
        boolean resolving;
        boolean retryBusyResolver;

        void emit() {
            Map<String, LocalComputer> byEndpoint = new LinkedHashMap<>();
            for (LocalComputer entry : resolved.values()) byEndpoint.put(entry.endpoint(), entry);
            listener.changed(new ArrayList<>(byEndpoint.values()), true);
        }

        void resolveNext() {
            if (active != this || resolving || queue.isEmpty()) return;
            NsdServiceInfo info = queue.removeFirst();
            resolving = true;
            NsdManager.ResolveListener result = new NsdManager.ResolveListener() {
                @Override public void onResolveFailed(NsdServiceInfo ignored, int code) {
                    if (code != NsdManager.FAILURE_ALREADY_ACTIVE) { complete(null); return; }
                    main.postDelayed(() -> {
                        if (active != Browse.this) return;
                        // Resolve requests may briefly outlive the previous discovery when the user returns.
                        if (!retryBusyResolver && seen.get(info.getServiceName()) == info) {
                            retryBusyResolver = true;
                            queue.addFirst(info);
                        } else {
                            retryBusyResolver = false;
                        }
                        resolving = false;
                        resolveNext();
                    }, 500);
                }
                @Override public void onServiceResolved(NsdServiceInfo record) { complete(record); }
                void complete(NsdServiceInfo record) {
                    main.post(() -> {
                        if (active != Browse.this) return;
                        resolving = false;
                        retryBusyResolver = false;
                        if (record != null && seen.get(info.getServiceName()) == info) {
                            byte[] rawIP = record.getAttributes().get("ip");
                            InetAddress host = record.getHost();
                            String address = rawIP == null ? null : new String(rawIP, StandardCharsets.US_ASCII);
                            if (!LocalComputer.privateIPv4(address) && host != null) address = host.getHostAddress();
                            if (LocalComputer.privateIPv4(address) && record.getPort() == LocalComputer.PORT) {
                                String key = info.getServiceName();
                                String label = key.replaceAll("[\\p{Cc}\\p{Cf}]", "").trim();
                                if (label.length() > 64) label = label.substring(0, 64);
                                resolved.put(key, new LocalComputer(label, address, record.getPort()));
                                emit();
                            }
                        }
                        resolveNext();
                    });
                }
            };
            try { nsd.resolveService(info, result); }
            catch (RuntimeException unavailable) { result.onResolveFailed(info, 0); }
        }

        @Override public void onServiceFound(NsdServiceInfo info) {
            main.post(() -> {
                String key = info.getServiceName();
                if (active != this || key == null || seen.containsKey(key) || seen.size() >= 32) return;
                seen.put(key, info);
                queue.add(info);
                resolveNext();
            });
        }
        @Override public void onServiceLost(NsdServiceInfo info) {
            main.post(() -> {
                if (active != this) return;
                String key = info.getServiceName();
                NsdServiceInfo removed = seen.remove(key);
                if (removed != null) queue.remove(removed);
                if (resolved.remove(key) != null) emit();
            });
        }
        @Override public void onStartDiscoveryFailed(String type, int error) {
            main.post(() -> {
                if (active != this) return;
                stop();
                listener.changed(new ArrayList<>(), false);
            });
        }
        @Override public void onDiscoveryStarted(String type) { }
        @Override public void onStopDiscoveryFailed(String type, int error) { }
        @Override public void onDiscoveryStopped(String type) { }
    }
}
