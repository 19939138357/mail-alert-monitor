package cn.mailmonitor.handset;

import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.math.BigInteger;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLException;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/** SRP-6a exchange over leaf-pinned TLS; the six digits never cross the network. */
final class CodeExchange {
    // RFC 5054 Appendix A, 2048-bit group and generator.
    private static final BigInteger N = new BigInteger(
            "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294" +
            "3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D" +
            "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB" +
            "D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74" +
            "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A" +
            "436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D" +
            "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73" +
            "03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6" +
            "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F" +
            "9E4AFF73", 16);
    private static final BigInteger G = BigInteger.valueOf(2);
    private static final int WIDTH = 256;
    private static final SecureRandom RANDOM = new SecureRandom();

    static String pair(String ipv4, int port, String code) throws Exception {
        if (!LocalComputer.privateIPv4(ipv4) || port < 1 || port > 65535)
            throw new IOException("请选择可访问的 Mac 私人网络地址");
        if (code == null || !code.matches("[0-9]{6}"))
            throw new IOException("请输入 Mac 显示的六位数字");
        URI origin = URI.create("https://" + ipv4 + ":" + port + "/");
        byte[] pin = probe(ipv4, port);
        SSLContext tls = context(Pairing.trustFingerprint(pin));
        BigInteger a = new BigInteger(256, RANDOM).setBit(255);
        BigInteger publicA = G.modPow(a, N);
        JSONObject challenge = post(tls, origin.resolve("/v1/pair/start"),
                new JSONObject().put("A", hex(pad(publicA))));

        String id = challenge.getString("id");
        if (!id.matches("[0-9a-f]{32}")) throw invalidReply();
        byte[] salt = decode(challenge.getString("salt"), 16);
        BigInteger publicB = positive(decode(challenge.getString("B"), WIDTH));
        if (publicB.signum() == 0 || publicB.compareTo(N) >= 0) throw invalidReply();

        String identityAndCode = "mailmonitor-v1/" + hex(pin) + ":" + code;
        BigInteger x = positive(hash(salt, hash(identityAndCode.getBytes(StandardCharsets.US_ASCII))));
        BigInteger k = positive(hashNumbers(N, G));
        BigInteger u = positive(hashNumbers(publicA, publicB));
        if (u.signum() == 0) throw invalidReply();
        BigInteger base = publicB.subtract(k.multiply(G.modPow(x, N))).mod(N);
        if (base.signum() == 0) throw invalidReply();
        BigInteger shared = base.modPow(a.add(u.multiply(x)), N);
        byte[] clientProof = hashNumbers(publicA, publicB, shared);
        byte[] serverProof = hashNumbers(publicA, positive(clientProof), shared);
        JSONObject result = post(tls, origin.resolve("/v1/pair/finish"),
                new JSONObject().put("id", id).put("proof", hex(clientProof)));

        if (!MessageDigest.isEqual(serverProof, decode(result.getString("proof"), 32)))
            throw new IOException("电脑配对验证失败，请核对所选设备");
        String link = result.getString("link");
        Pairing paired = Pairing.parse(link);
        if (!paired.origin.equals(origin) || !paired.matchesPin(pin)) throw invalidReply();
        return link;
    }

    private static final class Probe implements X509TrustManager {
        X509Certificate leaf;
        @Override public void checkServerTrusted(X509Certificate[] chain, String type) throws CertificateException {
            if (chain != null && chain.length > 0) leaf = chain[0];
            throw new CertificateException("certificate probe only");
        }
        @Override public void checkClientTrusted(X509Certificate[] chain, String type) throws CertificateException {
            throw new CertificateException("client certificates unsupported");
        }
        @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
    }

    private static byte[] probe(String host, int port) throws Exception {
        Probe probe = new Probe();
        try (SSLSocket s = (SSLSocket) context(probe).getSocketFactory().createSocket()) {
            s.connect(new InetSocketAddress(host, port), 4500);
            s.setSoTimeout(4500);
            try { s.startHandshake(); }
            catch (SSLException failure) {
                if (probe.leaf == null) throw failure;
                probe.leaf.checkValidity();
                return hash(probe.leaf.getEncoded());
            }
        }
        throw invalidReply();
    }

    private static SSLContext context(X509TrustManager trust) throws Exception {
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[]{trust}, null);
        return ctx;
    }

    private static JSONObject post(SSLContext tls, URI url, JSONObject payload) throws Exception {
        HttpsURLConnection c = (HttpsURLConnection) url.toURL().openConnection(Proxy.NO_PROXY);
        try {
            c.setSSLSocketFactory(tls.getSocketFactory());
            // Keep the platform's hostname verifier, including exact IP SAN matching.
            c.setInstanceFollowRedirects(false);
            c.setUseCaches(false);
            c.setConnectTimeout(4500);
            c.setReadTimeout(8000);
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/json");
            byte[] bytes = payload.toString().getBytes(StandardCharsets.UTF_8);
            c.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream out = c.getOutputStream()) { out.write(bytes); }
            int status = c.getResponseCode();
            if (status == 403) throw new IOException("六位配对码不正确，请核对 Mac 上的数字");
            if (status == 410 || status == 429)
                throw new IOException("此码已使用、过期或尝试次数已用完，请在 Mac 上换一个码");
            if (status != 200) throw new IOException("电脑未能完成六位配对（" + status + "），请确认 Mac 已更新");
            try (InputStream in = c.getInputStream(); ByteArrayOutputStream buffer = new ByteArrayOutputStream()) {
                byte[] part = new byte[1024]; int count;
                while ((count = in.read(part)) >= 0) {
                    if (buffer.size() + count > 8192) throw invalidReply();
                    buffer.write(part, 0, count);
                }
                return new JSONObject(new String(buffer.toByteArray(), StandardCharsets.UTF_8));
            }
        } finally { c.disconnect(); }
    }

    private static IOException invalidReply() { return new IOException("电脑返回了无效的配对信息"); }

    private static byte[] hash(byte[]... parts) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        for (byte[] part : parts) digest.update(part);
        return digest.digest();
    }

    private static BigInteger positive(byte[] bytes) { return new BigInteger(1, bytes); }

    private static byte[] pad(BigInteger n) {
        byte[] value = n.toByteArray();
        int offset = value.length > 1 && value[0] == 0 ? 1 : 0;
        int length = value.length - offset;
        if (n.signum() < 0 || length > WIDTH) throw new IllegalArgumentException("number outside group");
        byte[] result = new byte[WIDTH];
        System.arraycopy(value, offset, result, WIDTH - length, length);
        return result;
    }

    private static byte[] hashNumbers(BigInteger... values) throws Exception {
        byte[][] parts = new byte[values.length][];
        for (int i = 0; i < values.length; i++) parts[i] = pad(values[i]);
        return hash(parts);
    }

    private static byte[] decode(String hex, int size) throws IOException {
        if (hex.length() != size * 2 || !hex.matches("[0-9a-f]+")) throw invalidReply();
        byte[] data = new byte[size];
        for (int i = 0; i < size; i++) data[i] = (byte) Integer.parseInt(hex.substring(2*i, 2*i+2), 16);
        return data;
    }

    private static String hex(byte[] data) {
        char[] digits = "0123456789abcdef".toCharArray();
        StringBuilder result = new StringBuilder(2 * data.length);
        for (byte b : data) result.append(digits[(b & 255) >>> 4]).append(digits[b & 15]);
        return result.toString();
    }
}
