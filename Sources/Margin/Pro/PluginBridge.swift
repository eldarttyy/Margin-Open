import CryptoKit
import Foundation
import MarginCore
import os
import Security

/// Talks to app plugins over loopback UDP: `name value` out, JSON reports back.
/// Both directions are bound to 127.0.0.1, so nothing leaves the Mac, and both
/// are signed with a key only this macOS account can read, so another program
/// can't drive a plugin or pretend to be one. The key itself is never sent.
final class PluginBridge {
    static let shared = PluginBridge()

    private static let pluginPort: UInt16 = 52010
    private static let reportPort: UInt16 = 52011
    /// A plugin reports at least once a second, so silence past this means it's gone.
    private static let staleAfter = 3.0

    private struct Latest {
        var report: PluginReport?
        var received = 0.0
    }

    private let latest = OSAllocatedUnfairLock(initialState: Latest())
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let key = SymmetricKey(data: Data(PluginBridge.loadKey().utf8))
    /// Only touched by the read source, one packet at a time.
    private var buffer = [UInt8](repeating: 0, count: 65_535)
    private var retryDelay = 3.0

    /// Called on the main queue when a plugin's mode changes.
    var onModeChange: ((String?) -> Void)?

    func start() {
        guard source == nil else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var address = Self.loopback(port: Self.reportPort)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            // Something still holds the port, such as a copy of Margin that's quitting.
            close(fd)
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 60)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
            return
        }
        socketFD = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        read.setEventHandler { [weak self] in self?.receive() }
        read.resume()
        source = read
    }

    /// Creates the key on first use, readable by this account alone.
    private static func loadKey() -> String {
        let files = FileManager.default
        let url = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Margin/bridge-key")
        if let saved = try? String(contentsOf: url, encoding: .utf8), saved.count == 64 {
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        return text
    }

    private static let signatureLength = 64

    private func signature(_ body: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: body, using: key).map { String(format: "%02x", $0) }.joined().utf8)
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// The check takes the same time however close a forged signature gets, so
    /// timing can't be used to guess one a character at a time.
    private func isSigned(_ hex: ArraySlice<UInt8>, _ body: Data) -> Bool {
        guard let signature = Self.bytes(hex: hex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: body, using: key)
    }

    private static func bytes(hex: ArraySlice<UInt8>) -> [UInt8]? {
        func digit(_ character: UInt8) -> UInt8? {
            switch character {
            case 0x30...0x39: return character - 0x30
            case 0x61...0x66: return character - 0x61 + 10
            default: return nil
            }
        }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index + 1 < hex.endIndex {
            guard let high = digit(hex[index]), let low = digit(hex[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private func receive() {
        let count = recv(socketFD, &buffer, buffer.count, 0)
        guard count > Self.signatureLength else { return }
        let body = Data(buffer[Self.signatureLength..<count])
        guard isSigned(buffer[..<Self.signatureLength], body), let report = PluginReport.decode(body) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = latest.withLock { state -> String? in
            let mode = state.report?.mode
            state.report = report
            state.received = now
            return mode
        }
        if previous != report.mode {
            DispatchQueue.main.async { self.onModeChange?(report.mode) }
        }
    }

    var isConnected: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return latest.withLock { $0.report != nil && now - $0.received < Self.staleAfter }
    }

    /// The mode the plugin last reported, for when its app comes to the front.
    var currentMode: String? {
        guard isConnected else { return nil }
        return latest.withLock { $0.report?.mode }
    }

    /// Every value the connected plugin can set, for choosing in Settings.
    var parameterNames: [String] {
        guard isConnected else { return [] }
        return latest.withLock { $0.report.map { $0.parameters.keys.sorted() } ?? [] }
    }

    func parameter(_ name: String) -> PluginParameter? {
        guard isConnected else { return nil }
        return latest.withLock { $0.report?.parameters[name] }
    }

    func send(_ name: String, _ value: Double) {
        send("\(name) \(value)")
    }

    func send(_ text: String) {
        guard socketFD >= 0 else { return }
        var address = Self.loopback(port: Self.pluginPort)
        let body = Data("\(Int(Date().timeIntervalSince1970 * 1000)) \(text)".utf8)
        let bytes = Array(signature(body) + Data(" ".utf8) + body)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
