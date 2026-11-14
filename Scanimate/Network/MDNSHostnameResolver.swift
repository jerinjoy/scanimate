import Darwin
import Foundation
import dnssd

// MARK: - Multicast-DNS reverse resolver

/// Resolves a Scanner's name with a multicast-DNS reverse (PTR) lookup.
///
/// A typical home router serves no PTR record for the Scanner, so unicast
/// reverse DNS (`DNSHostnameResolver`) finds nothing. The Scanner itself does
/// answer a PTR query for its own address when it is sent over multicast.
struct MDNSHostnameResolver: HostnameResolver {
    /// How long to wait for an answer before giving up.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 2.0) {
        self.timeout = timeout
    }

    func resolveHostname(for host: String) async -> String? {
        // A non-IPv4 host (e.g. a hostname typed manually) is never queried.
        guard let reverseName = Self.reverseLookupName(forIPv4: host) else { return nil }
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            // Run the blocking poll loop on a background thread, as UDPDiscoveryTransport does.
            Thread.detachNewThread {
                let hostname = Self.queryPTR(reverseName: reverseName, timeout: timeout)
                continuation.resume(returning: hostname.flatMap(Self.displayName(fromHostname:)))
            }
        }
    }

    // MARK: - Pure helpers

    /// Builds the reverse-lookup name for a dotted-quad IPv4 address:
    /// `192.168.1.66` becomes `66.1.168.192.in-addr.arpa.`. Returns nil when
    /// `host` isn't an IPv4 address.
    static func reverseLookupName(forIPv4 host: String) -> String? {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        let octets = withUnsafeBytes(of: &addr) { Array($0) }
        return octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa."
    }

    /// Decodes PTR rdata (a sequence of length-prefixed DNS labels ending in a
    /// zero-length root label) into a dotted name with no trailing dot.
    /// Returns nil for empty, truncated, or compressed rdata.
    static func decodePTRRdata(_ rdata: Data) -> String? {
        let bytes = [UInt8](rdata)
        var labels: [String] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { break }
            // A label is at most 63 bytes; the top two bits mark a compression
            // pointer, which DNSServiceQueryRecord never hands back.
            guard length <= 63, index + 1 + length <= bytes.count else { return nil }
            guard let label = String(bytes: bytes[(index + 1)..<(index + 1 + length)], encoding: .utf8) else {
                return nil
            }
            labels.append(label)
            index += 1 + length
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    /// Normalises a resolved hostname for display: drops a trailing dot and a
    /// trailing `.local`, so `Fullyautomatix.local.` becomes `Fullyautomatix`.
    /// Returns nil when nothing is left.
    static func displayName(fromHostname hostname: String) -> String? {
        var name = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".") { name.removeLast() }
        let suffix = ".local"
        if name.lowercased().hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name.isEmpty ? nil : name
    }

    // MARK: - DNS-SD query

    private final class QueryResult {
        var hostname: String?
        var finished = false
    }

    // Sends one forced-multicast PTR query and waits up to `timeout` for the
    // first answer. Returns nil on any error or timeout.
    private static func queryPTR(reverseName: String, timeout: TimeInterval) -> String? {
        let result = QueryResult()
        let context = Unmanaged.passUnretained(result).toOpaque()

        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, rdlen, rdata, _, context in
            guard let context else { return }
            let result = Unmanaged<QueryResult>.fromOpaque(context).takeUnretainedValue()
            guard errorCode == kDNSServiceErr_NoError else {
                result.finished = true
                return
            }
            guard flags & kDNSServiceFlagsAdd != 0, let rdata, rdlen > 0 else { return }
            if let name = MDNSHostnameResolver.decodePTRRdata(Data(bytes: rdata, count: Int(rdlen))) {
                result.hostname = name
                result.finished = true
            }
        }

        var serviceRef: DNSServiceRef?
        let error = DNSServiceQueryRecord(
            &serviceRef,
            kDNSServiceFlagsForceMulticast,
            0, // any interface
            reverseName,
            UInt16(kDNSServiceType_PTR),
            UInt16(kDNSServiceClass_IN),
            callback,
            context
        )
        guard error == kDNSServiceErr_NoError, let serviceRef else { return nil }
        defer { DNSServiceRefDeallocate(serviceRef) }

        let fd = DNSServiceRefSockFD(serviceRef)
        guard fd >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while !result.finished {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollMs = Int32(min(remaining * 1000, 100).rounded(.up))
            let ready = poll(&pfd, 1, pollMs)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }
            guard DNSServiceProcessResult(serviceRef) == kDNSServiceErr_NoError else { break }
        }
        return result.hostname
    }
}

// MARK: - Chained resolver

/// Tries each resolver in order and returns the first name found.
struct ChainedHostnameResolver: HostnameResolver {
    let resolvers: [any HostnameResolver]

    init(_ resolvers: [any HostnameResolver]) {
        self.resolvers = resolvers
    }

    func resolveHostname(for host: String) async -> String? {
        for resolver in resolvers {
            if let name = await resolver.resolveHostname(for: host), !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
