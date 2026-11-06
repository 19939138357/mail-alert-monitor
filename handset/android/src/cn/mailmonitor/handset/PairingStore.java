package cn.mailmonitor.handset;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class PairingStore {
    private static final String ALIAS = "mailmonitor.pairing.v1";
    private final SharedPreferences prefs;

    PairingStore(Context context) { prefs = context.getSharedPreferences("connection", Context.MODE_PRIVATE); }

    private static SecretKey key(boolean create) throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        SecretKey existing = (SecretKey)store.getKey(ALIAS, null);
        if (existing != null || !create) return existing;
        KeyGenerator gen = KeyGenerator.getInstance("AES", "AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return gen.generateKey();
    }

    void save(String link) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, key(true));
        String sealed = Base64.encodeToString(c.doFinal(link.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
        if (!prefs.edit().putString("iv", Base64.encodeToString(c.getIV(), Base64.NO_WRAP))
                .putString("data", sealed).commit()) throw new java.io.IOException("保存配对失败");
    }

    Pairing load() throws Exception {
        String data = prefs.getString("data", null);
        if (data == null) return null;
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, key(false), new GCMParameterSpec(128,
                Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)));
        return Pairing.parse(new String(c.doFinal(Base64.decode(data, Base64.NO_WRAP)), StandardCharsets.UTF_8));
    }

    void clear() throws Exception {
        if (!prefs.edit().clear().commit()) throw new java.io.IOException("清除配对失败");
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        store.deleteEntry(ALIAS);
    }
}
