package cn.mailmonitor.handset;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.net.Proxy;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import org.json.JSONObject;

/** JVM integration probe. The code arrives on stdin; neither credentials nor mail leave stdout. */
public final class CodePairProbe {
    public static void main(String[] args) {
        try {
            String code = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8)).readLine();
            String link = CodeExchange.pair(args[0], Integer.parseInt(args[1]), code);
            Pairing paired = Pairing.parse(link);
            SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(null, new TrustManager[]{paired.trustManager()}, null);
            HttpsURLConnection c = (HttpsURLConnection) paired.origin.resolve("v1/status").toURL().openConnection(Proxy.NO_PROXY);
            try {
                c.setSSLSocketFactory(tls.getSocketFactory());
                c.setConnectTimeout(4000);
                c.setReadTimeout(25000);
                c.setInstanceFollowRedirects(false);
                c.setRequestProperty("Authorization", "Bearer " + paired.key);
                if (c.getResponseCode() != 200) throw new Exception("status");
                try (InputStream in = c.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                    byte[] buf = new byte[4096]; int n;
                    while ((n=in.read(buf)) >= 0) {
                        if (out.size() + n > 1048576) throw new Exception("oversize");
                        out.write(buf, 0, n);
                    }
                    int tickets = new JSONObject(new String(out.toByteArray(), StandardCharsets.UTF_8)).getJSONArray("tickets").length();
                    System.out.println("Pinned status HTTP 200; ticket count=" + tickets);
                }
            } finally { c.disconnect(); }
        } catch (Exception e) {
            // Error messages from malformed JSON may contain raw response contents.
            System.err.println("Pairing probe failed (" + e.getClass().getSimpleName() + ")");
            System.exit(1);
        }
    }
}
