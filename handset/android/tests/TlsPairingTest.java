package cn.mailmonitor.handset;

import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.FileInputStream;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URLEncoder;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLException;
import javax.net.ssl.TrustManager;

/** Verifies the pairing implementation against a local TLS server and a disposable certificate. */
public final class TlsPairingTest {
    private static int query(String origin,String pin) throws Exception {
        Pairing p=Pairing.parse("mailmonitor://pair?url="+URLEncoder.encode(origin,"UTF-8")+
                "&pin="+pin+"&key=0123456789abcdef0123456789abcdef");
        SSLContext ctx=SSLContext.getInstance("TLS");
        ctx.init(null,new TrustManager[]{p.trustManager()},null);
        HttpsURLConnection c=(HttpsURLConnection)p.origin.resolve("/v1/status").toURL().openConnection(Proxy.NO_PROXY);
        c.setSSLSocketFactory(ctx.getSocketFactory());
        c.setInstanceFollowRedirects(false);
        c.setConnectTimeout(2000);c.setReadTimeout(2000);
        c.setRequestProperty("Authorization","Bearer "+p.key);
        try { return c.getResponseCode(); } finally { c.disconnect(); }
    }

    public static void main(String[] args) throws Exception {
        char[] password="fixture-only".toCharArray();
        KeyStore keys=KeyStore.getInstance("PKCS12");
        try(FileInputStream f=new FileInputStream(args[0])){keys.load(f,password);}
        StringBuilder pin=new StringBuilder();
        for(byte b:MessageDigest.getInstance("SHA-256").digest(keys.getCertificate("fixture").getEncoded()))
            pin.append(String.format("%02x",b & 0xff));
        KeyManagerFactory km=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        km.init(keys,password);
        SSLContext ctx=SSLContext.getInstance("TLS");ctx.init(km.getKeyManagers(),null,null);
        HttpsServer server=HttpsServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.setHttpsConfigurator(new HttpsConfigurator(ctx));
        AtomicInteger received=new AtomicInteger();
        server.createContext("/v1/status",e -> {
            if("Bearer 0123456789abcdef0123456789abcdef".equals(e.getRequestHeaders().getFirst("Authorization")))
                received.incrementAndGet();
            e.sendResponseHeaders(200,-1);e.close();
        });
        server.start();
        try {
            int port=server.getAddress().getPort();
            String exact="https://127.0.0.1:"+port;
            if(query(exact,pin.toString())!=200)throw new AssertionError("paired certificate rejected");
            String wrong=(pin.charAt(0)=='a'?"b":"a")+pin.substring(1);
            try {query(exact,wrong);throw new AssertionError("wrong pin accepted");} catch(SSLException expected) {}
            try {query("https://localhost:"+port,pin.toString());throw new AssertionError("wrong hostname accepted");}
            catch(SSLException expected) {}
            if(received.get()!=1)throw new AssertionError("bearer transferred before pin/hostname validation");
            System.out.println("Verified TLS: valid identity accepted; wrong pin and hostname rejected before bearer transfer.");
        } finally {server.stop(0);}
    }
}
