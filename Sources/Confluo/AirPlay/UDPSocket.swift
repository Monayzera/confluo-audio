import Darwin
import Foundation
import Network

struct SocketAddress {
    var storage = sockaddr_in6()

    init?(host: NWEndpoint.Host, port: UInt16) {
        storage.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        storage.sin6_family = sa_family_t(AF_INET6)
        storage.sin6_port = port.bigEndian
        switch host {
        case .ipv4(let address):
            let raw = [UInt8](address.rawValue)
            guard raw.count == 4 else { return nil }
            let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + raw
            withUnsafeMutableBytes(of: &storage.sin6_addr) { $0.copyBytes(from: mapped) }
        case .ipv6(let address):
            let raw = [UInt8](address.rawValue)
            guard raw.count == 16 else { return nil }
            withUnsafeMutableBytes(of: &storage.sin6_addr) { $0.copyBytes(from: raw) }
            if let interface = address.interface {
                storage.sin6_scope_id = UInt32(interface.index)
            }
        default:
            return nil
        }
    }
}

final class UDPSocket {
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private var closed = false

    init(queue: DispatchQueue, handler: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        descriptor = fd
        port = UInt16(bigEndian: address.sin6_port)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(handler)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
    }

    deinit {
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }

    func send(_ bytes: [UInt8], to address: SocketAddress) {
        guard !closed else { return }
        var destination = address.storage
        _ = bytes.withUnsafeBytes { payload in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, payload.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    private func drain(_ handler: (UnsafeRawBufferPointer) -> Void) {
        guard !closed else { return }
        while true {
            let received = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if received <= 0 {
                return
            }
            buffer.withUnsafeBytes { handler(UnsafeRawBufferPointer(rebasing: $0.prefix(received))) }
        }
    }
}
