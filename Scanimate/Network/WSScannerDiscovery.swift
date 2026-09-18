import Darwin
import Foundation

// MARK: - Protocol for testability

protocol ScannerDiscoveryProtocol: Sendable {
    /// Performs one probe round. Calls `onFound` for each discovered target.
    /// Returns when the probe is complete (or on task cancellation).
    func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async
    func stop() async
}

// MARK: - UDP transport abstraction (injectable for tests)

protocol WSDDiscoveryTransport: Sendable {
    /// Sends `probe` to the WS-Discovery multicast group and returns all UDP datagrams
    /// received within `timeout` seconds.
    func sendAndReceive(probe: Data, timeout: TimeInterval) async throws -> [Data]
}

// MARK: - Real UDP transport using POSIX sockets

actor UDPDiscoveryTransport: WSDDiscoveryTransport {
    func sendAndReceive(probe: Data, timeout: TimeInterval) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            // Run blocking socket I/O on a background thread so the actor isn't held.
            Thread.detachNewThread {
                let results = Self.socketProbe(probe: probe, timeout: timeout)
                continuation.resume(returning: results)
            }
        }
    }

    // Sends the probe via UDP multicast and collects responses until timeout.
    // Returns empty array on any socket error so callers degrade gracefully.
    nonisolated private static func socketProbe(probe: Data, timeout: TimeInterval) -> [Data] {
        let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sockfd >= 0 else { return [] }
        defer { close(sockfd) }

        // Allow address reuse and set multicast TTL.
        var optval = Int32(1)
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
        var ttl = UInt8(4)
        setsockopt(sockfd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Bind to INADDR_ANY on an ephemeral port so responses reach us.
        var localAddr = sockaddr_in()
        localAddr.sin_len = 0
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = 0
        localAddr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        // Send probe to WS-Discovery multicast group 239.255.255.250:3702.
        var destAddr = sockaddr_in()
        destAddr.sin_len = 0
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = UInt16(3702).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destAddr.sin_addr)
        probe.withUnsafeBytes { probeBytes in
            withUnsafePointer(to: &destAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(sockfd, probeBytes.baseAddress!, probe.count, 0,
                               sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Collect responses until timeout using poll(2).
        var results: [Data] = []
        var recvBuffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var pfd = pollfd(fd: sockfd, events: Int16(POLLIN), revents: 0)
            let pollMs = Int32(min(remaining * 1000, 100))
            guard poll(&pfd, 1, pollMs) > 0 else { continue }

            let n = recv(sockfd, &recvBuffer, recvBuffer.count, 0)
            if n > 0 {
                results.append(Data(recvBuffer[0..<n]))
            }
        }
        return results
    }
}

// MARK: - WSScannerDiscovery actor

actor WSScannerDiscovery: ScannerDiscoveryProtocol {

    static let nsDiscovery  = "http://schemas.xmlsoap.org/ws/2005/04/discovery"
    static let nsAddressing = "http://schemas.xmlsoap.org/ws/2004/08/addressing"
    static let nsDevProf    = "http://schemas.xmlsoap.org/ws/2006/02/devprof"
    static let discoveryTo  = "urn:schemas-xmlsoap-org:ws:2005:04:discovery"

    private let transport: any WSDDiscoveryTransport

    init(transport: any WSDDiscoveryTransport = UDPDiscoveryTransport()) {
        self.transport = transport
    }

    // MARK: - ScannerDiscoveryProtocol

    /// Sends one WS-Discovery Probe and delivers results via `onFound`.
    /// Blocks until the probe window closes (or task cancellation).
    func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async {
        guard !Task.isCancelled, let probeData = buildProbe() else { return }
        guard let datagrams = try? await transport.sendAndReceive(probe: probeData, timeout: 2.5) else { return }
        for datagram in datagrams {
            guard !Task.isCancelled else { break }
            if let target = parseProbeMatch(datagram) {
                onFound(target)
            }
        }
    }

    func stop() async {
        // Cancellation propagates from the calling Task via structured concurrency;
        // no internal state to clean up here.
    }

    // MARK: - Probe XML builder

    nonisolated private func buildProbe() -> Data? {
        let msgId    = "urn:uuid:\(UUID().uuidString.lowercased())"
        let clientId = "urn:uuid:\(UUID().uuidString.lowercased())"
        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
                       xmlns:wsa="\(WSScannerDiscovery.nsAddressing)"
                       xmlns:wsd="\(WSScannerDiscovery.nsDiscovery)">
          <soap:Header>
            <wsa:Action>\(WSScannerDiscovery.nsDiscovery)/Probe</wsa:Action>
            <wsa:MessageID>\(msgId)</wsa:MessageID>
            <wsa:From><wsa:Address>\(clientId)</wsa:Address></wsa:From>
            <wsa:To>\(WSScannerDiscovery.discoveryTo)</wsa:To>
            <wsa:ReplyTo><wsa:Address>\(clientId)</wsa:Address></wsa:ReplyTo>
          </soap:Header>
          <soap:Body>
            <wsd:Probe/>
          </soap:Body>
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }

    // MARK: - ProbeMatches parser

    nonisolated func parseProbeMatch(_ data: Data) -> ScannerTarget? {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement() else { return nil }

        let allElements = allDescendants(root)

        // Find a Hosted section advertising ScannerServiceType.
        for hosted in allElements where hosted.localName == "Hosted" {
            let types = allDescendants(hosted)
                .filter { $0.localName == "Types" }
                .compactMap { $0.stringValue }
            guard types.contains(where: { $0.contains("ScannerServiceType") }) else { continue }

            guard let address = allDescendants(hosted)
                .first(where: { $0.localName == "Address" })?.stringValue,
                  let host = hostFromURL(address) else { continue }

            // Best-effort: look for a friendly name anywhere in the ProbeMatch.
            let friendlyName = allElements
                .first { $0.localName == "FriendlyName" }
                .flatMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }

            return ScannerTarget(host: host, displayName: friendlyName, source: .discovered)
        }
        return nil
    }

    // MARK: - Helpers

    nonisolated private func hostFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    nonisolated private func allDescendants(_ element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = [element]
        for child in element.children ?? [] {
            if let el = child as? XMLElement {
                result.append(contentsOf: allDescendants(el))
            }
        }
        return result
    }
}
