//
//  BackupCrypto.swift
//  MyInventory
//
//  SCBK1 — Supplies-Check encrypted backup container (Phase-1 E2EE). The `.scbk`
//  file is the cross-platform, end-to-end-encrypted backup: Google Drive only
//  ever holds this ciphertext, never the inventory.
//
//  This is the iOS mirror of the Android `supplies-check` `src/crypto.ts`. The
//  byte-level contract is `docs/SCBK1_Format.md`; the golden vectors in
//  `docs/fixtures/scbk1-vectors.json` pin every crypto output so both apps
//  interoperate (BackupCryptoTests reproduces them).
//
//  We call libsodium's C API directly (via `Clibsodium`) rather than the Sodium
//  Swift wrapper, because the wrapper's AEAD always generates its OWN random
//  nonce. SCBK1 needs caller-supplied nonces: the envelope stores each nonce
//  explicitly, and the golden-vector test must reproduce exact ciphertexts from
//  fixed material.
//

import Foundation
import Clibsodium

enum BackupCrypto {

    // MARK: Fixed format parameters (docs/SCBK1_Format.md §2) — never device-tuned,
    // so ANY device (incl. the low-RAM Galaxy Tab A7 Lite) can decrypt.
    static let formatString = "SCBK1"
    static let kdfAlgorithm = "argon2id13"
    static let aeadName = "xchacha20poly1305-ietf"
    static let opsLimit = 3
    static let memLimit = 67_108_864            // 64 MiB

    static let saltBytes = 16
    static let nonceBytes = 24
    static let keyBytes = 32
    static let tagBytes = 16

    enum CryptoError: LocalizedError, Equatable {
        case sodiumUnavailable
        case kdfFailed
        case encryptionFailed
        case notABackup
        case wrongPassphrase
        case wrongRecoveryKey
        case corrupted

        var errorDescription: String? {
            switch self {
            case .sodiumUnavailable: return "Couldn’t start the encryption engine."
            case .kdfFailed:         return "Couldn’t derive the encryption key."
            case .encryptionFailed:  return "Couldn’t encrypt the backup."
            case .notABackup:        return "This file isn’t a MyInventory backup, or it’s an unsupported version."
            case .wrongPassphrase:   return "Wrong passphrase."
            case .wrongRecoveryKey:  return "Wrong recovery key."
            case .corrupted:         return "Backup is corrupted (failed integrity check)."
            }
        }
    }

    // MARK: Envelope (JSON, see §4). Binary fields are standard base64 (with `=`).
    struct Envelope: Codable {
        var format: String
        var kdf: KDF
        var aead: String
        var wrap: Wrap
        var payload: Box

        struct KDF: Codable {
            var algorithm: String
            var opslimit: Int
            var memlimit: Int
            var salt: String
        }
        struct Wrap: Codable {
            var passphrase: Box
            var recovery: Box
        }
        struct Box: Codable {
            var nonce: String
            var ciphertext: String
        }
    }

    /// The random material that seals a backup. Injectable so the golden-vector
    /// test can pin every output byte-for-byte; the app uses `.fresh()`.
    struct SealMaterial {
        var salt: [UInt8]                 // 16
        var dataKey: [UInt8]              // 32 — DK
        var recoveryKeyBytes: [UInt8]     // 32 — RK
        var payloadNonce: [UInt8]         // 24
        var wrapPassphraseNonce: [UInt8]  // 24
        var wrapRecoveryNonce: [UInt8]    // 24

        static func fresh() -> SealMaterial {
            SealMaterial(
                salt: BackupCrypto.randomBytes(saltBytes),
                dataKey: BackupCrypto.randomBytes(keyBytes),
                recoveryKeyBytes: BackupCrypto.randomBytes(keyBytes),
                payloadNonce: BackupCrypto.randomBytes(nonceBytes),
                wrapPassphraseNonce: BackupCrypto.randomBytes(nonceBytes),
                wrapRecoveryNonce: BackupCrypto.randomBytes(nonceBytes))
        }
    }

    // MARK: libsodium lifecycle — `sodium_init()` is idempotent and must run once
    // before any other call; <0 means the library failed to initialize.
    private static let initialized: Bool = { sodium_init() >= 0 }()

    private static func ensureInit() throws {
        guard initialized else { throw CryptoError.sodiumUnavailable }
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        buffer.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, count) }
        return buffer
    }

    // MARK: KDF — KEK = Argon2id(passphrase, salt) at the FIXED cost (§3).
    static func deriveKek(passphrase: String, salt: [UInt8]) throws -> [UInt8] {
        try ensureInit()
        let password = Array(passphrase.utf8)
        guard !password.isEmpty else { throw CryptoError.kdfFailed }
        var out = [UInt8](repeating: 0, count: keyBytes)
        let status = out.withUnsafeMutableBufferPointer { outBuf in
            password.withUnsafeBufferPointer { pwBuf in
                salt.withUnsafeBufferPointer { saltBuf in
                    pwBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pwBuf.count) { pwChars in
                        crypto_pwhash(
                            outBuf.baseAddress!, UInt64(keyBytes),
                            pwChars, UInt64(pwBuf.count),
                            saltBuf.baseAddress!,
                            UInt64(opsLimit), memLimit,
                            crypto_pwhash_alg_argon2id13())
                    }
                }
            }
        }
        guard status == 0 else { throw CryptoError.kdfFailed }
        return out
    }

    // MARK: AEAD (XChaCha20-Poly1305-IETF, additional data = null for all ops).
    static func aeadEncrypt(message: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try ensureInit()
        var cipher = [UInt8](repeating: 0, count: message.count + tagBytes)
        var cipherLen: UInt64 = 0
        let status = cipher.withUnsafeMutableBufferPointer { cipherBuf in
            message.withUnsafeBufferPointer { msgBuf in
                nonce.withUnsafeBufferPointer { nonceBuf in
                    key.withUnsafeBufferPointer { keyBuf in
                        crypto_aead_xchacha20poly1305_ietf_encrypt(
                            cipherBuf.baseAddress!, &cipherLen,
                            msgBuf.baseAddress!, UInt64(msgBuf.count),
                            nil, 0,                 // additional data = null
                            nil,                    // nsec (unused by this construction)
                            nonceBuf.baseAddress!,
                            keyBuf.baseAddress!)
                    }
                }
            }
        }
        guard status == 0 else { throw CryptoError.encryptionFailed }
        return Int(cipherLen) == cipher.count ? cipher : Array(cipher.prefix(Int(cipherLen)))
    }

    /// Decrypts/authenticates. Throws `.corrupted` on any AEAD failure; callers
    /// that know the key came from a passphrase/recovery key remap that to a
    /// friendlier "wrong key" message.
    static func aeadDecrypt(ciphertext: [UInt8], nonce: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try ensureInit()
        guard ciphertext.count >= tagBytes else { throw CryptoError.corrupted }
        var message = [UInt8](repeating: 0, count: ciphertext.count - tagBytes)
        var messageLen: UInt64 = 0
        let status = message.withUnsafeMutableBufferPointer { msgBuf in
            ciphertext.withUnsafeBufferPointer { cipherBuf in
                nonce.withUnsafeBufferPointer { nonceBuf in
                    key.withUnsafeBufferPointer { keyBuf in
                        crypto_aead_xchacha20poly1305_ietf_decrypt(
                            msgBuf.baseAddress!, &messageLen,
                            nil,                    // nsec
                            cipherBuf.baseAddress!, UInt64(cipherBuf.count),
                            nil, 0,                 // additional data = null
                            nonceBuf.baseAddress!,
                            keyBuf.baseAddress!)
                    }
                }
            }
        }
        guard status == 0 else { throw CryptoError.corrupted }
        return Int(messageLen) == message.count ? message : Array(message.prefix(Int(messageLen)))
    }

    // MARK: Seal / open

    /// Encrypts `plaintextUtf8` into an SCBK1 envelope. `material` is injectable
    /// for deterministic tests; the app omits it to use fresh randomness. Returns
    /// the envelope and the printable recovery key — show that ONCE at export.
    static func encryptBackup(plaintextUtf8: String,
                              passphrase: String,
                              material: SealMaterial = .fresh())
        throws -> (envelope: Envelope, recoveryKeyString: String) {
        try ensureInit()
        let kek = try deriveKek(passphrase: passphrase, salt: material.salt)
        let payloadCipher = try aeadEncrypt(message: Array(plaintextUtf8.utf8),
                                            nonce: material.payloadNonce, key: material.dataKey)
        let wrapPassCipher = try aeadEncrypt(message: material.dataKey,
                                             nonce: material.wrapPassphraseNonce, key: kek)
        let wrapRecCipher = try aeadEncrypt(message: material.dataKey,
                                            nonce: material.wrapRecoveryNonce, key: material.recoveryKeyBytes)
        let envelope = Envelope(
            format: formatString,
            kdf: .init(algorithm: kdfAlgorithm, opslimit: opsLimit, memlimit: memLimit,
                       salt: base64(material.salt)),
            aead: aeadName,
            wrap: .init(
                passphrase: .init(nonce: base64(material.wrapPassphraseNonce),
                                  ciphertext: base64(wrapPassCipher)),
                recovery: .init(nonce: base64(material.wrapRecoveryNonce),
                                ciphertext: base64(wrapRecCipher))),
            payload: .init(nonce: base64(material.payloadNonce),
                           ciphertext: base64(payloadCipher)))
        return (envelope, formatRecoveryKey(material.recoveryKeyBytes))
    }

    /// Pretty-printed `.scbk` bytes. Key order is not significant (readers parse
    /// by name) but sorted keys keep diffs/tests stable.
    static func serializeEnvelope(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func parseEnvelope(_ data: Data) throws -> Envelope {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw CryptoError.notABackup }
        guard envelope.format == formatString else { throw CryptoError.notABackup }
        return envelope
    }

    /// Unwrap the data key with the passphrase, then decrypt the payload.
    static func decryptWithPassphrase(_ envelope: Envelope, passphrase: String) throws -> String {
        let kek = try deriveKek(passphrase: passphrase, salt: try decodeBase64(envelope.kdf.salt))
        return try decryptPayload(envelope, wrap: envelope.wrap.passphrase, wrapKey: kek, unlock: .passphrase)
    }

    /// Unwrap the data key with the printable recovery key, then decrypt the payload.
    static func decryptWithRecoveryKey(_ envelope: Envelope, recoveryKey: String) throws -> String {
        let rk = base32Decode(recoveryKey)
        guard rk.count == keyBytes else { throw CryptoError.wrongRecoveryKey }
        return try decryptPayload(envelope, wrap: envelope.wrap.recovery, wrapKey: rk, unlock: .recovery)
    }

    private enum Unlock { case passphrase, recovery }

    private static func decryptPayload(_ envelope: Envelope,
                                       wrap: Envelope.Box,
                                       wrapKey: [UInt8],
                                       unlock: Unlock) throws -> String {
        let dataKey: [UInt8]
        do {
            dataKey = try aeadDecrypt(ciphertext: try decodeBase64(wrap.ciphertext),
                                      nonce: try decodeBase64(wrap.nonce), key: wrapKey)
        } catch {
            throw unlock == .passphrase ? CryptoError.wrongPassphrase : CryptoError.wrongRecoveryKey
        }
        let plaintext: [UInt8]
        do {
            plaintext = try aeadDecrypt(ciphertext: try decodeBase64(envelope.payload.ciphertext),
                                        nonce: try decodeBase64(envelope.payload.nonce), key: dataKey)
        } catch {
            throw CryptoError.corrupted
        }
        guard let string = String(bytes: plaintext, encoding: .utf8) else { throw CryptoError.corrupted }
        return string
    }

    // MARK: base64 (standard alphabet, `=` padding)
    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    static func decodeBase64(_ string: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: string) else { throw CryptoError.corrupted }
        return [UInt8](data)
    }

    // MARK: base32 (RFC 4648, uppercase, no padding) for the recovery key
    //
    // NOTE: unlike the JS mirror — where bitwise ops implicitly truncate the
    // accumulator to 32 bits — Swift's Int is 64-bit, so we MUST mask the
    // accumulator down to the leftover bits each step or it overflows (and traps)
    // on a 32-byte key.
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Encode(_ bytes: [UInt8]) -> String {
        var out = ""
        var bits = 0
        var value = 0
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(base32Alphabet[(value >> bits) & 31])
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(base32Alphabet[(value << (5 - bits)) & 31])
        }
        return out
    }

    /// Tolerant decode: uppercases, ignores any character outside `[A-Z2-7]`
    /// (so dashes/spaces/lowercase a user typed are fine).
    static func base32Decode(_ string: String) -> [UInt8] {
        var out = [UInt8]()
        var bits = 0
        var value = 0
        for character in string.uppercased() {
            guard let index = base32Alphabet.firstIndex(of: character) else { continue }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xff))
            }
            value &= (1 << bits) - 1
        }
        return out
    }

    /// 32 random bytes → grouped base32 string shown to the user to write down,
    /// e.g. `UCQ2-FI5E-…-X27Q`.
    static func formatRecoveryKey(_ bytes: [UInt8]) -> String {
        let encoded = base32Encode(bytes)
        var groups = [Substring]()
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 4, limitedBy: encoded.endIndex) ?? encoded.endIndex
            groups.append(encoded[index..<end])
            index = end
        }
        return groups.joined(separator: "-")
    }
}
