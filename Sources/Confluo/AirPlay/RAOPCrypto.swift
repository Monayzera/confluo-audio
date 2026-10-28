import CommonCrypto
import Foundation
import Security

enum RAOPCryptoError: Error {
    case keyUnavailable
    case operationFailed(String)
}

enum RAOPCrypto {
    private static let airPortKeyBase64 = "MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfWBLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAaLlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jmlpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurcizaaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFua39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndMoPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0ZoMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hLAoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvAcJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gILAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY="

    static let privateKey: SecKey? = {
        guard let data = Data(base64Encoded: airPortKeyBase64) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }()

    static func challengeResponse(challenge: Data, localAddress: Data, hardwareAddress: Data) throws -> String {
        guard let privateKey else { throw RAOPCryptoError.keyUnavailable }
        guard challenge.count <= 16 else { throw RAOPCryptoError.operationFailed("challenge") }
        var message = Data()
        message.append(challenge)
        message.append(localAddress)
        message.append(hardwareAddress)
        if message.count < 32 {
            message.append(Data(count: 32 - message.count))
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15Raw, message as CFData, &error) as Data? else {
            throw RAOPCryptoError.operationFailed(error?.takeRetainedValue().localizedDescription ?? "sign")
        }
        return signature.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func decryptSessionKey(_ encrypted: Data) throws -> Data {
        guard let privateKey else { throw RAOPCryptoError.keyUnavailable }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, encrypted as CFData, &error) as Data? else {
            throw RAOPCryptoError.operationFailed(error?.takeRetainedValue().localizedDescription ?? "decrypt")
        }
        guard key.count == 16 else { throw RAOPCryptoError.operationFailed("key length \(key.count)") }
        return key
    }
}

final class AudioPacketDecryptor {
    private var cryptor: CCCryptorRef?
    private let iv: [UInt8]

    init(key: Data, iv: Data) throws {
        guard key.count == 16, iv.count == 16 else { throw RAOPCryptoError.operationFailed("aes parameters") }
        self.iv = [UInt8](iv)
        var created: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            self.iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, 16, ivBytes.baseAddress, &created)
            }
        }
        guard status == kCCSuccess, let created else { throw RAOPCryptoError.operationFailed("CCCryptorCreate \(status)") }
        cryptor = created
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    func decrypt(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Bool {
        guard let cryptor, output.count >= input.count, let source = input.baseAddress, let destination = output.baseAddress else { return false }
        let blockLength = input.count & ~0xF
        if blockLength > 0 {
            let resetStatus = iv.withUnsafeBytes { CCCryptorReset(cryptor, $0.baseAddress) }
            guard resetStatus == kCCSuccess else { return false }
            var moved = 0
            let status = CCCryptorUpdate(cryptor, source, blockLength, destination, output.count, &moved)
            guard status == kCCSuccess, moved == blockLength else { return false }
        }
        if input.count > blockLength {
            memcpy(destination + blockLength, source + blockLength, input.count - blockLength)
        }
        return true
    }
}
