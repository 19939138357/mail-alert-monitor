package cn.mailmonitor.handset;

import java.io.FileInputStream;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;

public class PairingTest {
    private static final String KEY = "0123456789abcdef0123456789abcdef";
    private static int passed;

    private static String link(String url, String pin) throws Exception {
        return "mailmonitor://pair?url=" + URLEncoder.encode(url, "UTF-8") + "&key=" + KEY + "&pin=" + pin;
    }

    private static void refuses(String raw) {
        try { Pairing.parse(raw); } catch (Exception expected) { passed++; return; }
        throw new AssertionError("Accepted invalid test input");
    }

    private static void check(boolean ok) {
        if (!ok) throw new AssertionError();
        passed++;
    }

    public static void main(String[] args) throws Exception {
        X509Certificate cert;
        try (FileInputStream fixture = new FileInputStream(args[0])) {
            cert = (X509Certificate)CertificateFactory.getInstance("X509").generateCertificate(fixture);
        }
        StringBuilder hex = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()))
            hex.append(String.format("%02x", b & 0xff));
        String pin = hex.toString();
        String good = link("https://192.168.20.8:18444", pin);
        Pairing paired = Pairing.parse(good);
        check(paired.origin.toString().equals("https://192.168.20.8:18444/"));
        check(paired.key.equals(KEY));
        check(Pairing.parse(link("https://mymac.example.com",pin)).origin.getHost().equals("mymac.example.com"));
        check(Pairing.parse(link("https://[fd7a::1]:28443",pin)).origin.getPort()==28443);
        for (String base : new String[]{"http://192.168.20.8","file:///a","https://user@host","https://host/a",
                "https://host/?q=x","https://host/#x","https://:443","https://host:0","https://host:65536",
                "https://host:","https://host/%2F","https://host\\@evil.test","https://host/%0A"})
            refuses(link(base,pin));
        refuses(good+"&key="+KEY);
        refuses(good+"&other=x");
        refuses(good.replace("mailmonitor://pair?", "https://pair?"));
        refuses(good.replace("mailmonitor://pair?", "mailmonitor://pair/path?"));
        refuses(good.replace("mailmonitor://pair?", "mailmonitor://user@pair?"));
        refuses(good.replace(KEY, "abc"));
        refuses(good.replace(KEY,KEY+"%0a"));
        refuses(good.substring(0,good.length()-1));
        refuses(good+"#replacement");
        refuses(null);
        X509Certificate[] chain = {cert};
        paired.trustManager().checkServerTrusted(chain,"RSA");
        passed++;
        try {
            String different = (pin.charAt(0)=='0' ? "1":"0")+pin.substring(1);
            Pairing.parse(link("https://localhost",different)).trustManager().checkServerTrusted(chain,"RSA");
            throw new AssertionError("Wrong certificate pin accepted");
        } catch (CertificateException expected) { passed++; }
        try { paired.trustManager().checkServerTrusted(new X509Certificate[0],"RSA");throw new AssertionError(); }
        catch (CertificateException expected) { passed++; }
        System.out.println(passed+" pairing and certificate checks passed");
    }
}
