package cn.mailmonitor.handset;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Proxy;
import java.nio.charset.StandardCharsets;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;

final class MonitorApi {
    static final class Frame {
        final Bitmap bitmap;
        final String id;
        Frame(Bitmap bitmap, String id) { this.bitmap = bitmap; this.id = id; }
    }

    private final Pairing pairing;
    private final SSLContext tls;

    MonitorApi(Pairing pairing) throws Exception {
        this.pairing = pairing;
        tls = SSLContext.getInstance("TLS");
        tls.init(null, new TrustManager[]{pairing.trustManager()}, null);
    }

    private HttpsURLConnection open(String path, JSONObject body) throws Exception {
        HttpsURLConnection c = (HttpsURLConnection)pairing.origin.resolve(path).toURL().openConnection(Proxy.NO_PROXY);
        try {
            c.setSSLSocketFactory(tls.getSocketFactory());
            // Keep the platform's HTTPS hostname verifier in addition to checking the paired DER fingerprint.
            c.setConnectTimeout(6000);
            c.setReadTimeout(25000);
            c.setUseCaches(false);
            c.setInstanceFollowRedirects(false);
            c.setRequestProperty("Authorization", "Bearer " + pairing.key);
            c.setRequestProperty("Cache-Control", "no-store");
            if (body != null) {
                byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
                c.setRequestMethod("POST");
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json");
                c.setFixedLengthStreamingMode(data.length);
                try (OutputStream out = c.getOutputStream()) { out.write(data); }
            }
            int code = c.getResponseCode();
            if (code == 401 || code == 403) throw new IOException("配对凭证已失效，请使用电脑上的新链接重新配对。");
            if (code < 200 || code >= 300) {
                String detail = null;
                try {
                    byte[] bytes = read(c.getErrorStream(), 8192);
                    detail = new JSONObject(new String(bytes, StandardCharsets.UTF_8)).optString("error", "");
                } catch (Exception ignored) { }
                if (detail == null || detail.trim().isEmpty() || detail.length() > 180)
                    detail = "电脑未能完成请求（" + code + "）。";
                throw new IOException(detail);
            }
            return c;
        } catch (Exception e) {
            c.disconnect();
            throw e;
        }
    }

    JSONObject status() throws Exception {
        HttpsURLConnection c = open("/v1/status", null);
        try {
            JSONObject status = new JSONObject(new String(read(c.getInputStream(), 1048576), StandardCharsets.UTF_8));
            status.getBoolean("running");
            status.getString("monitorState");
            status.getJSONArray("tickets");
            return status;
        } finally { c.disconnect(); }
    }

    String connect() throws Exception {
        byte[] bytes = action("/v1/connect", new JSONObject());
        String message = bytes.length > 0
                ? new JSONObject(new String(bytes, StandardCharsets.UTF_8)).optString("message", "") : "";
        return message.isEmpty() ? "连接请求已提交，正在读取状态。" : message;
    }

    void tap(String frameId, float x, float y) throws Exception {
        action("/v1/tap", new JSONObject().put("frameId", frameId).put("x", (double)x).put("y", (double)y));
    }

    private byte[] action(String path, JSONObject body) throws Exception {
        HttpsURLConnection c = open(path, body);
        try { return read(c.getInputStream(), 16384); }
        finally { c.disconnect(); }
    }

    Frame frame() throws Exception {
        HttpsURLConnection c = open("/v1/frame", null);
        try {
            String type = c.getContentType();
            String id = c.getHeaderField("X-Frame-Id");
            if (type == null || !type.split(";", 2)[0].trim().equalsIgnoreCase("image/jpeg") ||
                    id == null || id.trim().isEmpty() || id.length() > 128)
                throw new IOException("电脑返回的邮箱画面无效。");
            byte[] data = read(c.getInputStream(), 8 * 1024 * 1024);
            BitmapFactory.Options sizes = new BitmapFactory.Options();
            sizes.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(data, 0, data.length, sizes);
            if (sizes.outWidth < 1 || sizes.outHeight < 1 || (long)sizes.outWidth * sizes.outHeight > 24000000)
                throw new IOException("邮箱画面尺寸无效。");
            BitmapFactory.Options decode = new BitmapFactory.Options();
            while (Math.max(sizes.outWidth, sizes.outHeight) / Math.max(1,decode.inSampleSize) > 2300)
                decode.inSampleSize = 2 * Math.max(1,decode.inSampleSize);
            Bitmap bitmap = BitmapFactory.decodeByteArray(data, 0, data.length, decode);
            if (bitmap == null) throw new IOException("无法显示邮箱画面。");
            return new Frame(bitmap, id);
        } finally { c.disconnect(); }
    }

    private static byte[] read(InputStream input, int limit) throws IOException {
        if (input == null) return new byte[0];
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[8192];
            int n;
            while ((n = in.read(b)) != -1) {
                if (out.size() + n > limit) throw new IOException("电脑返回的数据过大。");
                out.write(b, 0, n);
            }
            return out.toByteArray();
        }
    }
}
