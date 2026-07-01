//
//  BackupCryptoTests.swift
//  MyInventoryTests
//
//  SCBK1 conformance for the iOS crypto core. These reproduce the shared golden
//  vectors (docs/fixtures/scbk1-vectors.json) and decrypt the shared sample
//  (docs/fixtures/scbk1-sample.scbk) — both authored cross-platform with Node
//  (libsodium-wrappers-sumo) and mirrored by the Android tests. If iOS produces
//  the same KEK, recovery-key string, and ciphertexts from the same fixed inputs,
//  the two apps can decrypt each other's backups. The vectors are inlined (not
//  read from disk) so the test is hermetic.
//

import XCTest
@testable import MyInventory

final class BackupCryptoTests: XCTestCase {

    // MARK: Golden vector inputs (docs/fixtures/scbk1-vectors.json → inputs)
    private let passphrase = "correct horse battery staple"
    private let plaintextUtf8 = #"{"schemaVersion":2,"exportedAt":"2026-06-28T12:00:00Z","contexts":[{"uuid":"11111111-1111-4111-8111-111111111111","name":"Vehicle","sortOrder":0,"createdAt":"2026-06-01T00:00:00Z","modifiedAt":"2026-06-01T00:00:00Z","categories":[{"uuid":"22222222-2222-4222-8222-222222222222","name":"Uncategorized","sortOrder":0,"createdAt":"2026-06-01T00:00:00Z","modifiedAt":"2026-06-01T00:00:00Z","items":[{"uuid":"33333333-3333-4333-8333-333333333333","name":"4L water","intervalValue":1,"intervalUnit":"months","leadTimeDaysOverride":null,"quantity":2,"storageLocation":"trunk","notes":"Rotate monthly","createdAt":"2026-06-01T00:00:00Z","modifiedAt":"2026-06-10T00:00:00Z","checks":[{"uuid":"44444444-4444-4444-8444-444444444444","date":"2026-06-10","result":"ok","comment":null}]}]}]}]}"#

    private let saltB64 = "AAECAwQFBgcICQoLDA0ODw=="
    private let dataKeyB64 = "gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp8="
    private let recoveryKeyBytesB64 = "oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8="
    private let payloadNonceB64 = "EBESExQVFhcYGRobHB0eHyAhIiMkJSYn"
    private let wrapPassphraseNonceB64 = "MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZH"
    private let wrapRecoveryNonceB64 = "UFFSU1RVVldYWVpbXF1eX2BhYmNkZWZn"

    // MARK: Golden vector expected outputs (→ expected)
    private let kekB64 = "DRo8ZSPI8G5OCvnFFapbVEjP69aDjy1Sw9i2743cPC4="
    private let recoveryKeyString = "UCQ2-FI5E-UWTK-PKFJ-VKV2-ZLNO-V6YL-DMVT-WS23-NN5Y-XG5L-XPF5-X27Q"
    private let payloadCiphertextB64 = "Syn+AhZ/KgD033gJCOwj+vr7jsIb7FrP0TarBkG05KJAwawUi0ar3zs4TwfCbXz2PN/kc9UyQdDAJlV6TFKhve85+ZVrgfIZKy+6nHTLBRuendCj0I9hcz6TkH64xeChEm5wc1Bfc18h3n2VCXMaTy9NZ8yhUOMjbby/BxnPxWT3n40+KTs6X/h9xDdSeuLUsN/Z6ZsaVxJFFLbr34QXHeIhrMDMQarrX6TGgEA5a9Fx7VhJk2PLVopk3Dc5IrhgxsS/GZ1FSkoITMaOD7UoiMwfGJHpS/47V3QyAv4GK6ymAcxBKZKgP7c83qx3COLz6k+EVbzkAqOrKTqRjkESN0BvQuXUcunOi/Rch3/ZtEGe/u7X0HKmkHso5wOjMOwHJIo2THlijDdeqSlbpeuGaY/12UKa86tChXUU4SS3ER7rarnSkHzZCZJWmFa+m3ODda94xwvgjxxaW98fZHHBe5EcuaKF/mmnzy9r/6MUN4E1jZUFJmr6DygZRSQzjhPyvMlosfyNprzkzZPAu0BLtd03RavsG0cY/onO/Ak9YgrEpoDKgTIiLJzAhcTSKRkhIsBPWgSsvPQsBe7ShBNcC2nmSR3tYCzMojYNrnk3MNYg7b+HryH4w+9+BeGC8I8I5UrX9vdMSVRPR6P1awEDM3+5Rkf8Nt2X7s0Pm+vMsOgzLLWO1W3umQCoJoba1eZpfhUbSoq7AOU6Ge17qQ5R79l4HRm2VjFH9He/hoGvMaSzI3VmiEdKI2QEvpDzWj5FOo3dm8LI8E2SCwQDN/Ce+i/Zp2GeLgvtjEwvsxWC/EKO9vibp75lQ7aTyJHlorxZSLJ/toJmAIJoKtn61yANruem1X+IlfIY4oYCnVYmP+MqcRTf3HccaegymmXevRmkISfEZjEHs5oZyzuatIwTQr5xeRTOgoHr7JGPDPKDFXeGjxkPvARE1IqFziEa0zWH0Mc39WQhWj6EZ9RHxw5eguJ6Vl/Vf3AGfkf67U5CCOcmMPb15CZ1P+Mm8sraIlbXytRGOgU47iNwYWb5rqQmacFf+wtuLZ/+3AU="
    private let wrapPassphraseCiphertextB64 = "5xaGTXTTNt+2aAK1VyKZroFA5V8TYNclZbh2TURXPA+3ZTE8DQjkhc5uuI25NhJA"
    private let wrapRecoveryCiphertextB64 = "NkOOyJp2frVio8/qxewJeeXMkIfMaKJ6I3L/PeHZ+Y7AugnOlPRc+wGzNxzUw83e"

    // MARK: The shared sample .scbk (docs/fixtures/scbk1-sample.scbk), verbatim.
    private let sampleScbk = #"""
    {
      "format": "SCBK1",
      "kdf": {
        "algorithm": "argon2id13",
        "opslimit": 3,
        "memlimit": 67108864,
        "salt": "AAECAwQFBgcICQoLDA0ODw=="
      },
      "aead": "xchacha20poly1305-ietf",
      "wrap": {
        "passphrase": {
          "nonce": "MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZH",
          "ciphertext": "5xaGTXTTNt+2aAK1VyKZroFA5V8TYNclZbh2TURXPA+3ZTE8DQjkhc5uuI25NhJA"
        },
        "recovery": {
          "nonce": "UFFSU1RVVldYWVpbXF1eX2BhYmNkZWZn",
          "ciphertext": "NkOOyJp2frVio8/qxewJeeXMkIfMaKJ6I3L/PeHZ+Y7AugnOlPRc+wGzNxzUw83e"
        }
      },
      "payload": {
        "nonce": "EBESExQVFhcYGRobHB0eHyAhIiMkJSYn",
        "ciphertext": "Syn+AhZ/KgD033gJCOwj+vr7jsIb7FrP0TarBkG05KJAwawUi0ar3zs4TwfCbXz2PN/kc9UyQdDAJlV6TFKhve85+ZVrgfIZKy+6nHTLBRuendCj0I9hcz6TkH64xeChEm5wc1Bfc18h3n2VCXMaTy9NZ8yhUOMjbby/BxnPxWT3n40+KTs6X/h9xDdSeuLUsN/Z6ZsaVxJFFLbr34QXHeIhrMDMQarrX6TGgEA5a9Fx7VhJk2PLVopk3Dc5IrhgxsS/GZ1FSkoITMaOD7UoiMwfGJHpS/47V3QyAv4GK6ymAcxBKZKgP7c83qx3COLz6k+EVbzkAqOrKTqRjkESN0BvQuXUcunOi/Rch3/ZtEGe/u7X0HKmkHso5wOjMOwHJIo2THlijDdeqSlbpeuGaY/12UKa86tChXUU4SS3ER7rarnSkHzZCZJWmFa+m3ODda94xwvgjxxaW98fZHHBe5EcuaKF/mmnzy9r/6MUN4E1jZUFJmr6DygZRSQzjhPyvMlosfyNprzkzZPAu0BLtd03RavsG0cY/onO/Ak9YgrEpoDKgTIiLJzAhcTSKRkhIsBPWgSsvPQsBe7ShBNcC2nmSR3tYCzMojYNrnk3MNYg7b+HryH4w+9+BeGC8I8I5UrX9vdMSVRPR6P1awEDM3+5Rkf8Nt2X7s0Pm+vMsOgzLLWO1W3umQCoJoba1eZpfhUbSoq7AOU6Ge17qQ5R79l4HRm2VjFH9He/hoGvMaSzI3VmiEdKI2QEvpDzWj5FOo3dm8LI8E2SCwQDN/Ce+i/Zp2GeLgvtjEwvsxWC/EKO9vibp75lQ7aTyJHlorxZSLJ/toJmAIJoKtn61yANruem1X+IlfIY4oYCnVYmP+MqcRTf3HccaegymmXevRmkISfEZjEHs5oZyzuatIwTQr5xeRTOgoHr7JGPDPKDFXeGjxkPvARE1IqFziEa0zWH0Mc39WQhWj6EZ9RHxw5eguJ6Vl/Vf3AGfkf67U5CCOcmMPb15CZ1P+Mm8sraIlbXytRGOgU47iNwYWb5rqQmacFf+wtuLZ/+3AU="
      }
    }
    """#

    // MARK: Helpers
    private func bytes(_ base64: String) -> [UInt8] {
        guard let data = Data(base64Encoded: base64) else {
            XCTFail("bad base64 fixture: \(base64)")
            return []
        }
        return [UInt8](data)
    }

    private func vectorMaterial() -> BackupCrypto.SealMaterial {
        BackupCrypto.SealMaterial(
            salt: bytes(saltB64),
            dataKey: bytes(dataKeyB64),
            recoveryKeyBytes: bytes(recoveryKeyBytesB64),
            payloadNonce: bytes(payloadNonceB64),
            wrapPassphraseNonce: bytes(wrapPassphraseNonceB64),
            wrapRecoveryNonce: bytes(wrapRecoveryNonceB64))
    }

    // MARK: KDF / recovery-key encoding

    func testDeriveKekReproducesVector() throws {
        let kek = try BackupCrypto.deriveKek(passphrase: passphrase, salt: bytes(saltB64))
        XCTAssertEqual(BackupCrypto.base64(kek), kekB64)
    }

    func testFormatRecoveryKeyReproducesVector() {
        XCTAssertEqual(BackupCrypto.formatRecoveryKey(bytes(recoveryKeyBytesB64)), recoveryKeyString)
    }

    func testBase32RoundTrips() {
        // 32 bytes is the production size — the case that overflows a 64-bit
        // accumulator if the base32 codec doesn't mask the leftover bits.
        let original = bytes(recoveryKeyBytesB64)
        let decoded = BackupCrypto.base32Decode(BackupCrypto.formatRecoveryKey(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: Encryption reproduces the golden ciphertexts

    func testEncryptBackupReproducesGoldenVector() throws {
        let sealed = try BackupCrypto.encryptBackup(
            plaintextUtf8: plaintextUtf8, passphrase: passphrase, material: vectorMaterial())
        XCTAssertEqual(sealed.envelope.payload.ciphertext, payloadCiphertextB64)
        XCTAssertEqual(sealed.envelope.wrap.passphrase.ciphertext, wrapPassphraseCiphertextB64)
        XCTAssertEqual(sealed.envelope.wrap.recovery.ciphertext, wrapRecoveryCiphertextB64)
        XCTAssertEqual(sealed.recoveryKeyString, recoveryKeyString)
        // Envelope restates the fixed format params.
        XCTAssertEqual(sealed.envelope.format, "SCBK1")
        XCTAssertEqual(sealed.envelope.kdf.opslimit, 3)
        XCTAssertEqual(sealed.envelope.kdf.memlimit, 67_108_864)
    }

    // MARK: Decrypting the shared sample — either key recovers the plaintext

    func testDecryptSampleWithPassphrase() throws {
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        XCTAssertEqual(try BackupCrypto.decryptWithPassphrase(env, passphrase: passphrase), plaintextUtf8)
    }

    func testDecryptSampleWithRecoveryKey() throws {
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        XCTAssertEqual(try BackupCrypto.decryptWithRecoveryKey(env, recoveryKey: recoveryKeyString), plaintextUtf8)
    }

    func testRecoveryKeyAcceptsLowercaseAndSpacing() throws {
        // The spec says input is tolerant: lowercase + arbitrary grouping decode.
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        let messy = recoveryKeyString.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(try BackupCrypto.decryptWithRecoveryKey(env, recoveryKey: messy), plaintextUtf8)
    }

    // MARK: Negative cases

    func testWrongPassphraseThrows() throws {
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        XCTAssertThrowsError(try BackupCrypto.decryptWithPassphrase(env, passphrase: "not it")) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .wrongPassphrase)
        }
    }

    func testWrongRecoveryKeyThrows() throws {
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        // Right length, wrong bytes.
        let wrong = BackupCrypto.formatRecoveryKey([UInt8](repeating: 7, count: 32))
        XCTAssertThrowsError(try BackupCrypto.decryptWithRecoveryKey(env, recoveryKey: wrong)) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .wrongRecoveryKey)
        }
    }

    func testMalformedRecoveryKeyLengthThrows() throws {
        let env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        XCTAssertThrowsError(try BackupCrypto.decryptWithRecoveryKey(env, recoveryKey: "ABCD-EFGH")) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .wrongRecoveryKey)
        }
    }

    func testTamperedPayloadThrows() throws {
        var env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        var raw = try BackupCrypto.decodeBase64(env.payload.ciphertext)
        raw[0] ^= 0xFF
        env.payload.ciphertext = BackupCrypto.base64(raw)
        XCTAssertThrowsError(try BackupCrypto.decryptWithPassphrase(env, passphrase: passphrase)) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
    }

    func testParseRejectsNonBackup() {
        XCTAssertThrowsError(try BackupCrypto.parseEnvelope(Data(#"{"format":"NOPE"}"#.utf8))) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .notABackup)
        }
        XCTAssertThrowsError(try BackupCrypto.parseEnvelope(Data("not json at all".utf8))) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .notABackup)
        }
    }

    // MARK: Fail-closed on malformed fixed-length fields (guard a heap over-read)
    //
    // libsodium reads a FIXED number of bytes from the nonce/salt/key pointers. A
    // crafted `.scbk` can carry a shorter decoded value; without a length guard that
    // over-reads the heap. These pin that such input throws instead of touching OOB memory.

    func testAeadDecryptRejectsWrongLengthNonceAndKey() {
        let cipher = [UInt8](repeating: 0, count: 32)   // ≥ tagBytes, so it clears that guard
        let goodNonce = [UInt8](repeating: 0, count: BackupCrypto.nonceBytes)
        let goodKey = [UInt8](repeating: 0, count: BackupCrypto.keyBytes)
        XCTAssertThrowsError(try BackupCrypto.aeadDecrypt(ciphertext: cipher, nonce: [1, 2, 3], key: goodKey)) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
        XCTAssertThrowsError(try BackupCrypto.aeadDecrypt(ciphertext: cipher, nonce: goodNonce, key: [1, 2, 3])) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
    }

    func testDeriveKekRejectsWrongLengthSalt() {
        XCTAssertThrowsError(try BackupCrypto.deriveKek(passphrase: "pw", salt: [1, 2, 3])) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
    }

    func testShortPayloadNonceFailsClosed() throws {
        var env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        env.payload.nonce = BackupCrypto.base64([1, 2, 3])   // 3 bytes, not 24
        XCTAssertThrowsError(try BackupCrypto.decryptWithPassphrase(env, passphrase: passphrase)) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
    }

    func testShortKdfSaltFailsClosed() throws {
        var env = try BackupCrypto.parseEnvelope(Data(sampleScbk.utf8))
        env.kdf.salt = BackupCrypto.base64([1, 2, 3])   // 3 bytes, not 16
        XCTAssertThrowsError(try BackupCrypto.decryptWithPassphrase(env, passphrase: passphrase)) {
            XCTAssertEqual($0 as? BackupCrypto.CryptoError, .corrupted)
        }
    }

    // MARK: Full round-trip with fresh (random) material

    func testRoundTripWithFreshMaterial() throws {
        let sealed = try BackupCrypto.encryptBackup(plaintextUtf8: plaintextUtf8, passphrase: "hunter2")
        let data = try BackupCrypto.serializeEnvelope(sealed.envelope)
        let parsed = try BackupCrypto.parseEnvelope(data)
        XCTAssertEqual(try BackupCrypto.decryptWithPassphrase(parsed, passphrase: "hunter2"), plaintextUtf8)
        XCTAssertEqual(try BackupCrypto.decryptWithRecoveryKey(parsed, recoveryKey: sealed.recoveryKeyString),
                       plaintextUtf8)
        // Two fresh seals of the same plaintext must differ (random salt/nonces).
        let other = try BackupCrypto.encryptBackup(plaintextUtf8: plaintextUtf8, passphrase: "hunter2")
        XCTAssertNotEqual(other.envelope.payload.ciphertext, sealed.envelope.payload.ciphertext)
    }
}
