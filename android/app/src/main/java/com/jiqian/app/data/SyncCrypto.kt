package com.jiqian.app

import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * 端到端加密。
 *
 * 配对码 + 每次配对随机生成的盐 → PBKDF2-HMAC-SHA256（10 万轮）派生 256 位密钥，
 * 再用 AES-256-GCM 加密整份互通 JSON。云端 payload 只保存信封密文：
 * `{"v":2,"salt":<b64>,"iv":<b64>,"ct":<b64>}`（ct 末尾 16 字节为 GCM tag）。
 *
 * 与 iOS SyncCrypto.swift 完全一致（同一算法、同一信封格式）。
 */
object SyncCrypto {

    private const val ITERATIONS = 100_000
    private const val KEY_BITS = 256
    private const val TAG_BITS = 128
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12

    private val rnd = SecureRandom()

    // 100k 轮 PBKDF2 约几百毫秒，缓存最近一次派生结果，避免每次同步都重算
    private var cachedSalt: String? = null
    private var cachedKey: SecretKeySpec? = null

    private fun randomBytes(n: Int): ByteArray = ByteArray(n).also { rnd.nextBytes(it) }

    private fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun unb64(text: String): ByteArray = Base64.decode(text, Base64.NO_WRAP)

    /** 新建一个配对用的随机盐（首次推送或换配对码时生成） */
    fun newSalt(): String = b64(randomBytes(SALT_BYTES))

    @Synchronized
    private fun deriveKey(code: String, saltB64: String): SecretKeySpec? {
        cachedKey?.let { if (cachedSalt == saltB64) return it }
        return try {
            val spec = PBEKeySpec(code.toCharArray(), unb64(saltB64), ITERATIONS, KEY_BITS)
            val raw = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
            val key = SecretKeySpec(raw, "AES")
            cachedSalt = saltB64
            cachedKey = key
            key
        } catch (e: Exception) {
            AppLog.e("密钥派生失败：${e.message}")
            null
        }
    }

    /** 把明文互通 JSON 加密成信封对象（存入云端 payload 列） */
    fun encrypt(code: String, plain: String, saltB64: String): JSONObject? {
        val key = deriveKey(code, saltB64) ?: return null
        return try {
            val iv = randomBytes(IV_BYTES)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
            val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            JSONObject()
                .put("v", 2)
                .put("salt", saltB64)
                .put("iv", b64(iv))
                .put("ct", b64(ct))
        } catch (e: Exception) {
            AppLog.e("加密失败：${e.message}")
            null
        }
    }

    /** 信封对象解密回明文；不是信封或解密失败返回 null */
    fun decrypt(code: String, envelope: JSONObject): String? {
        val salt = envelope.optString("salt").ifEmpty { return null }
        val ivText = envelope.optString("iv").ifEmpty { return null }
        val ctText = envelope.optString("ct").ifEmpty { return null }
        val key = deriveKey(code, salt) ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, unb64(ivText)))
            String(cipher.doFinal(unb64(ctText)), Charsets.UTF_8)
        } catch (e: Exception) {
            AppLog.w("解密失败（配对码不匹配或数据损坏）：${e.message}")
            null
        }
    }
}
