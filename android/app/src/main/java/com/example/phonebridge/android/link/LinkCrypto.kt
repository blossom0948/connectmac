package com.example.phonebridge.android.link

import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object LinkCrypto {
    private val random = SecureRandom()

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    fun fromB64(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)

    fun hmac(key: ByteArray, value: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(value.toByteArray(Charsets.UTF_8))
    }

    fun deriveSessionKey(secret: ByteArray, challenge: ByteArray): ByteArray {
        val saltMac = Mac.getInstance("HmacSHA256")
        saltMac.init(SecretKeySpec(challenge, "HmacSHA256"))
        val pseudoRandomKey = saltMac.doFinal(secret)
        val info = "PhoneBridge/aes-gcm/v1".toByteArray(Charsets.UTF_8)
        val expand = Mac.getInstance("HmacSHA256")
        expand.init(SecretKeySpec(pseudoRandomKey, "HmacSHA256"))
        expand.update(info)
        expand.update(1.toByte())
        return expand.doFinal().copyOf(32)
    }

    fun seal(key: ByteArray, payload: JSONObject): JSONObject {
        val nonce = randomBytes(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        val encrypted = cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("type", "secure")
            .put("nonce", b64(nonce))
            .put("ciphertext", b64(encrypted))
    }

    fun open(key: ByteArray, wrapper: JSONObject): JSONObject {
        val nonce = fromB64(wrapper.getString("nonce"))
        val encrypted = fromB64(wrapper.getString("ciphertext"))
        require(nonce.size == 12 && encrypted.size >= 16)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return JSONObject(String(cipher.doFinal(encrypted), Charsets.UTF_8))
    }
}
