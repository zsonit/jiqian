import Foundation
import CryptoKit
import CommonCrypto
import Security

// MARK: - 端到端加密
//
// 配对码 + 每次配对随机生成的盐 → PBKDF2-HMAC-SHA256（10 万轮）派生 256 位密钥，
// 再用 AES-256-GCM 加密整份互通 JSON。云端 payload 只保存信封密文：
// {"v":2,"salt":<b64>,"iv":<b64>,"ct":<b64>}（ct 末尾 16 字节为 GCM tag）。
//
// 即使数据库整库泄露、或无关设备拿到公开 key，也读不出任何孕期记录——
// 没有配对码就派生不出密钥。与安卓 SyncCrypto.kt 完全一致（同一算法、同一信封格式），
// 亦与萌宝成长的实现逐字节一致。

enum SyncCrypto {

    private static let iterations = 100_000
    private static let saltBytes = 16

    private static let lock = NSLock()
    private static var cachedSalt: String?
    private static var cachedKey: SymmetricKey?

    // MARK: 盐

    static func newSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: 密钥派生

    private static func deriveKey(code: String, salt: String) -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if cachedSalt == salt, let k = cachedKey { return k }
        guard let saltData = Data(base64Encoded: salt) else { return nil }

        var derived = [UInt8](repeating: 0, count: 32)
        let status: Int32 = saltData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            guard let saltPtr = raw.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return derived.withUnsafeMutableBufferPointer { out -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    code, code.utf8.count,
                    saltPtr, saltData.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    out.baseAddress, out.count
                )
            }
        }
        guard status == kCCSuccess else {
            AppLog.e("Sync", "密钥派生失败：\(status)")
            return nil
        }
        let key = SymmetricKey(data: Data(derived))
        cachedSalt = salt
        cachedKey = key
        return key
    }

    // MARK: 加解密

    /// 明文互通 JSON → 信封字典（存入云端 payload 列）
    static func encrypt(code: String, plain: String, salt: String) -> [String: Any]? {
        guard let key = deriveKey(code: code, salt: salt),
              let data = plain.data(using: .utf8) else { return nil }
        var ivBytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes)
        let ivData = Data(ivBytes)
        do {
            let nonce = try AES.GCM.Nonce(data: ivData)
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
            var ct = sealed.ciphertext
            ct.append(sealed.tag)
            return [
                "v": 2,
                "salt": salt,
                "iv": ivData.base64EncodedString(),
                "ct": ct.base64EncodedString(),
            ]
        } catch {
            AppLog.e("Sync", "加密失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 信封字典 → 明文；不是信封或解密失败返回 nil
    static func decrypt(code: String, envelope: [String: Any]) -> String? {
        guard let salt = envelope["salt"] as? String,
              let ivText = envelope["iv"] as? String,
              let ctText = envelope["ct"] as? String,
              let key = deriveKey(code: code, salt: salt),
              let ivData = Data(base64Encoded: ivText),
              let ct = Data(base64Encoded: ctText),
              ct.count > 16,
              let nonce = try? AES.GCM.Nonce(data: ivData)
        else { return nil }

        let body = ct.prefix(ct.count - 16)
        let tag = ct.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag)
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            AppLog.w("Sync", "解密失败（配对码不匹配或数据损坏）")
            return nil
        }
    }
}
