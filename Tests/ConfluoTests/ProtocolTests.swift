import AudioToolbox
import CommonCrypto
import Foundation
import Security
import XCTest
@testable import Confluo

final class ProtocolTests: XCTestCase {
    func testParsesRequestAcrossChunks() throws {
        var buffer = Data("OPTIONS * RTSP/1.0\r\nCSeq: 3\r\nApple-Challenge: abc\r\n".utf8)
        XCTAssertNil(try RTSPParser.next(from: &buffer))
        buffer.append(Data("\r\nANNOUNCE rtsp://x RTSP/1.0\r\nCSeq: 4\r\nContent-Length: 5\r\n\r\nhel".utf8))
        let options = try XCTUnwrap(try RTSPParser.next(from: &buffer))
        XCTAssertEqual(options.method, "OPTIONS")
        XCTAssertEqual(options.cseq, "3")
        XCTAssertEqual(options.header("apple-challenge"), "abc")
        XCTAssertNil(try RTSPParser.next(from: &buffer))
        buffer.append(Data("lo".utf8))
        let announce = try XCTUnwrap(try RTSPParser.next(from: &buffer))
        XCTAssertEqual(announce.method, "ANNOUNCE")
        XCTAssertEqual(String(decoding: announce.body, as: UTF8.self), "hello")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testResponseSerialization() {
        var response = RTSPResponse()
        response.add("Audio-Latency", "11025")
        let text = String(decoding: response.serialized(cseq: "7"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("RTSP/1.0 200 OK\r\nCSeq: 7\r\n"))
        XCTAssertTrue(text.contains("Audio-Latency: 11025\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testParsesALACSessionDescription() {
        let sdp = """
        v=0\r
        o=iTunes 3413821438 0 IN IP4 192.168.1.10\r
        s=iTunes\r
        i=Gustavo’s iPhone\r
        c=IN IP4 192.168.1.10\r
        t=0 0\r
        m=audio 0 RTP/AVP 96\r
        a=rtpmap:96 AppleLossless\r
        a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r
        a=rsaaeskey:AAAA\r
        a=aesiv:AAECAwQFBgcICQoLDA0ODw\r
        a=min-latency:11025\r
        """
        let parsed = SessionDescription.parse(Data(sdp.utf8))
        XCTAssertEqual(parsed.codec, .alac(parameters: [352, 0, 16, 40, 10, 14, 2, 255, 0, 0, 44_100]))
        XCTAssertEqual(parsed.framesPerPacket, 352)
        XCTAssertEqual(parsed.sampleRate, 44_100)
        XCTAssertEqual(parsed.senderName, "Gustavo’s iPhone")
        XCTAssertEqual(parsed.initializationVector, Data(0..<16))
        XCTAssertEqual(parsed.minimumLatency, 11_025)
    }

    func testParsesPCMSessionDescription() {
        let parsed = SessionDescription.parse(Data("a=rtpmap:96 L16/44100/2\r\n".utf8))
        XCTAssertEqual(parsed.codec, .pcm16BigEndian(sampleRate: 44_100, channels: 2))
    }

    func testKnownDevicesAreDeduplicatedByName() throws {
        let json = """
        {"knownDevices":[
          {"id":"40AF8431FE49CAA8","name":"iPhone de Gustavo","lastSeen":100},
          {"id":"2DEC5AF42BB63DE5","name":"iPhone de Gustavo","lastSeen":300},
          {"id":"C6476AE4BD2EA4B7","name":"iphone de gustavo","lastSeen":200},
          {"id":"4C9B13CAB4AA0983","name":"iPad","lastSeen":50}
        ]}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.knownDevices.map(\.name), ["iPhone de Gustavo", "iPad"])
        XCTAssertEqual(settings.knownDevices.first?.id, "2DEC5AF42BB63DE5")
        XCTAssertEqual(settings.knownDevices.first?.lastSeen, Date(timeIntervalSinceReferenceDate: 300))
    }

    func testKnownDeviceVolumeIsOptionalAndPersisted() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"knownDevices":[{"id":"A","name":"iPhone","lastSeen":10}]}"#.utf8))
        XCTAssertNil(legacy.knownDevices.first?.volume)

        var settings = legacy
        settings.knownDevices[0].volume = 0.333
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.knownDevices.first?.volume, 0.333)
    }

    func testHotkeyValidation() {
        XCTAssertNil(Hotkey.validated(keyCode: 8, flags: [.command]))
        XCTAssertNotNil(Hotkey.validated(keyCode: 46, flags: [.control, .option]))
        XCTAssertNotNil(Hotkey.validated(keyCode: 122, flags: []))
        XCTAssertNil(Hotkey.validated(keyCode: 55, flags: [.command, .shift]))
    }

    func testTransportPortParsing() {
        let transport = "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=6001;timing_port=6002"
        XCTAssertEqual(RAOPSession.port(named: "control_port", in: transport), 6001)
        XCTAssertEqual(RAOPSession.port(named: "timing_port", in: transport), 6002)
        XCTAssertNil(RAOPSession.port(named: "server_port", in: transport))
    }

    func testSessionKeyDecryptionRoundTrip() throws {
        let privateKey = try XCTUnwrap(RAOPCrypto.privateKey)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let key = Data((0..<16).map { UInt8($0 * 7) })
        let encrypted = try XCTUnwrap(SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA1, key as CFData, nil) as Data?)
        XCTAssertEqual(try RAOPCrypto.decryptSessionKey(encrypted), key)
    }

    func testChallengeResponseVerifiesWithAirPortPublicKey() throws {
        let privateKey = try XCTUnwrap(RAOPCrypto.privateKey)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let challenge = Data((0..<16).map { UInt8($0) })
        let address = Data([192, 168, 0, 20])
        let hardware = Data([0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
        let response = try RAOPCrypto.challengeResponse(challenge: challenge, localAddress: address, hardwareAddress: hardware)
        XCTAssertFalse(response.contains("="))
        let signature = try XCTUnwrap(SessionDescription.decodeBase64(response))
        XCTAssertEqual(signature.count, 256)
        var message = challenge + address + hardware
        message.append(Data(count: 32 - message.count))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15Raw, message as CFData, signature as CFData, nil))
    }

    func testPartialBlockDecryption() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data((16..<32).map { UInt8($0) })
        let plain = (0..<45).map { UInt8($0 &* 3) }
        var encrypted = [UInt8](repeating: 0, count: 32)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, 16, ivBytes.baseAddress, plain, 32, &encrypted, 32, &moved)
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        let packet = encrypted + plain[32...]
        let decryptor = try AudioPacketDecryptor(key: key, iv: iv)
        var output = [UInt8](repeating: 0, count: packet.count)
        for _ in 0..<2 {
            let ok = packet.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { decryptor.decrypt(input, into: $0) }
            }
            XCTAssertTrue(ok)
            XCTAssertEqual(output, plain)
        }
    }

    func testDMAPMetadata() {
        func item(_ code: String, _ value: String) -> Data {
            let payload = Data(value.utf8)
            var data = Data(code.utf8)
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            return data + payload
        }
        let inner = item("minm", "Song") + item("asar", "Artist") + item("asal", "Album") + item("astn", "x")
        var container = Data("mlit".utf8)
        var length = UInt32(inner.count).bigEndian
        withUnsafeBytes(of: &length) { container.append(contentsOf: $0) }
        container.append(inner)
        XCTAssertEqual(DMAP.metadata(from: container), TrackMetadata(title: "Song", artist: "Artist", album: "Album"))
    }

    func testPCM16Decoding() {
        let decoder = PCM16Decoder(channels: 2)
        let bytes: [UInt8] = [0x40, 0x00, 0xC0, 0x00]
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { output.deallocate() }
        let frames = bytes.withUnsafeBytes { decoder.decode($0, into: output) }
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(output[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[1], -0.5, accuracy: 0.0001)
    }

    func testSettingsRoundTripAndDefaults() throws {
        var settings = AppSettings()
        settings.masterVolume = 0.42
        settings.hotkeys[.openMixer] = nil
        settings.knownDevices = [KnownDevice(id: "a", name: "iPhone", lastSeen: Date(timeIntervalSince1970: 100))]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.hardwareAddressData.count, 6)
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data("{\"masterVolume\":0.3}".utf8))
        XCTAssertEqual(partial.masterVolume, 0.3)
        XCTAssertEqual(partial.hotkeys, AppSettings.defaultHotkeys)
        XCTAssertTrue(partial.captureMacAudio)
        XCTAssertEqual(partial.latencyMode, .low)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"knownDevices\":[{\"id\":\"x\",\"name\":\"Old\",\"muted\":true,\"lastSeen\":0}],\"latencyMode\":\"bogus\"}".utf8))
        XCTAssertEqual(legacy.knownDevices.first?.name, "Old")
        XCTAssertEqual(legacy.latencyMode, .low)
    }
}
