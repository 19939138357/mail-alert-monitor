package cn.mailmonitor.handset;

import java.net.URI;
import java.net.URLDecoder;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.HashMap;
import java.util.Map;
import javax.net.ssl.X509TrustManager;

/** A user-supplied pairing link binds one origin, certificate and bearer together. */
final class Pairing {
    final URI origin;
    final String key;
    private final byte[] pin;

    private Pairing(URI origin, String key, byte[] pin) {
        this.origin = origin;
        this.key = key;
        this.pin = pin;
    }

    static Pairing parse(String raw) throws Exception {
        if (raw == null || raw.length() > 1800) throw invalid();
        URI link = new URI(raw.trim());
        if (!"mailmonitor".equals(link.getScheme()) || !"pair".equals(link.getRawAuthority()) ||
                !"".equals(link.getRawPath()) || link.getRawFragment() != null || link.getRawQuery() == null)
            throw invalid();
        Map<String, String> fields = new HashMap<>();
        for (String part : link.getRawQuery().split("&", -1)) {
            int eq = part.indexOf('=');
            if (eq < 1) throw invalid();
            String name = part.substring(0, eq);
            String value = URLDecoder.decode(part.substring(eq + 1), "UTF-8");
            if (fields.put(name, value) != null) throw invalid();
        }
        if (fields.size() != 3 || !fields.containsKey("url") || !fields.containsKey("key") ||
                !fields.containsKey("pin")) throw invalid();
        URI base = new URI(fields.get("url"));
        String path = base.getRawPath();
        if (!"https".equals(base.getScheme()) || base.getHost() == null || base.getRawUserInfo() != null ||
                base.getRawQuery() != null || base.getRawFragment() != null ||
                !(path.isEmpty() || "/".equals(path)) || base.getPort() == 0 || base.getPort() > 65535 ||
                base.getRawAuthority().endsWith(":") || base.getRawAuthority().contains("%")) throw invalid();
        String key = fields.get("key");
        String hex = fields.get("pin");
        if (!key.matches("[a-zA-Z0-9_-]{32,160}") || !hex.matches("[a-f0-9]{64}")) throw invalid();
        byte[] pin = new byte[32];
        for (int i = 0; i < pin.length; i++) pin[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        return new Pairing(base.resolve("/"), key, pin);
    }

    boolean matchesPin(byte[] expected) { return MessageDigest.isEqual(pin, expected); }

    X509TrustManager trustManager() { return trustFingerprint(pin); }

    static X509TrustManager trustFingerprint(byte[] pin) {
        return new X509TrustManager() {
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                throw new CertificateException("client certificates unsupported");
            }
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                if (chain == null || chain.length == 0) throw new CertificateException("missing certificate");
                chain[0].checkValidity();
                try {
                    byte[] actual = MessageDigest.getInstance("SHA-256").digest(chain[0].getEncoded());
                    if (!MessageDigest.isEqual(pin, actual)) throw new CertificateException("unpaired certificate");
                } catch (java.security.NoSuchAlgorithmException e) {
                    throw new CertificateException(e);
                }
            }
        };
    }

    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("配对链接格式有误，请从电脑重新复制完整链接。");
    }
}
