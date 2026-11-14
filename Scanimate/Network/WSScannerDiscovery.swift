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

// MARK: - Hostname resolver abstraction (injectable for tests)

protocol HostnameResolver: Sendable {
    /// Attempts a best-effort reverse-DNS lookup for `host`. Returns nil on
    /// failure, timeout, or when `host` isn't a resolvable IP address.
    func resolveHostname(for host: String) async -> String?
}

// MARK: - Real reverse-DNS resolver using POSIX getnameinfo

actor DNSHostnameResolver: HostnameResolver {
    func resolveHostname(for host: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.reverseLookup(host: host))
            }
        }
    }

    // Reverse-resolves an IPv4 address to a hostname. Returns nil on any failure,
    // including when `host` isn't an IP address at all (e.g. already a hostname).
    nonisolated private static func reverseLookup(host: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: hostBuffer)
        return name.isEmpty ? nil : name
    }
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
    private let hostnameResolver: any HostnameResolver
    private var resolutionTasks: [Task<Void, Never>] = []

    init(
        transport: any WSDDiscoveryTransport = UDPDiscoveryTransport(),
        hostnameResolver: any HostnameResolver = DNSHostnameResolver()
    ) {
        self.transport = transport
        self.hostnameResolver = hostnameResolver
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
                if target.displayName == nil {
                    resolveDisplayName(for: target, onFound: onFound)
                }
            }
        }
    }

    // Best-effort, asynchronous reverse-DNS resolution for a target with no
    // advertised FriendlyName. Runs independently of the probe loop so a
    // slow or failing resolver never blocks or delays delivery of targets.
    // The spawned task is unstructured (it must outlive `start()`'s return),
    // so it's tracked here and explicitly cancelled by `stop()`.
    private func resolveDisplayName(
        for target: ScannerTarget,
        onFound: @escaping @Sendable (ScannerTarget) -> Void
    ) {
        let resolver = hostnameResolver
        let host = target.host
        let task = Task {
            guard let resolvedName = await resolver.resolveHostname(for: host),
                  !resolvedName.isEmpty,
                  !Task.isCancelled else { return }
            onFound(ScannerTarget(host: host, displayName: resolvedName, source: .discovered))
        }
        resolutionTasks.append(task)
    }

    func stop() async {
        // Cancel any in-flight reverse-DNS lookups so a resolved name can't
        // arrive via `onFound` after the caller has stopped discovery.
        for task in resolutionTasks {
            task.cancel()
        }
        resolutionTasks.removeAll()
    }

    // MARK: - Probe XML builder

    nonisolated private func buildProbe() -> Data? {
        let msgId    = "urn:uuid:\(UUID().uuidString.lowercased())"
        let clientId = "urn:uuid:\(UUID().uuidString.lowercased())"
        // No wsa:ReplyTo: the SL-M2070 silently drops a Probe whose ReplyTo is
        // anything other than the anonymous role. Omitting it means "reply to
        // the datagram's source", which is what we want.
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

        // A plain WS-Discovery ProbeMatch (what the SL-M2070 actually sends) has
        // no Hosted section: the device advertises `wscn:ScanDeviceType` in
        // wsd:Types and its transport addresses in wsd:XAddrs.
        for match in allElements where match.localName == "ProbeMatch" {
            let children = (match.children ?? []).compactMap { $0 as? XMLElement }
            guard let types = children.first(where: { $0.localName == "Types" })?.stringValue,
                  types.contains("ScanDeviceType"),
                  let xAddrs = children.first(where: { $0.localName == "XAddrs" })?.stringValue,
                  let host = xAddrs.split(whereSeparator: \.isWhitespace)
                      .lazy.compactMap({ self.hostFromURL(String($0)) }).first
            else { continue }
            return ScannerTarget(host: host, displayName: nil, source: .discovered)
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
