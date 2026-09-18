import XCTest
@testable import Scanimate

// MARK: - Mock UDP transport

struct MockDiscoveryTransport: WSDDiscoveryTransport {
    let responses: [Data]
    let error: Error?

    init(responses: [Data] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func sendAndReceive(probe: Data, timeout: TimeInterval) async throws -> [Data] {
        if let error { throw error }
        return responses
    }
}

// MARK: - ProbeMatches XML fixtures

enum DiscoveryFixtures {
    static func probeMatchesResponse(
        host: String = "192.168.1.66",
        port: Int = 8018,
        includeScannerType: Bool = true,
        friendlyName: String? = nil
    ) -> Data {
        let serviceTypes = includeScannerType
            ? "scan:ScannerServiceType"
            : "print:PrinterServiceType"
        let friendlyNameXML = friendlyName.map {
            "<wsdp:FriendlyName xmlns:wsdp=\"http://schemas.xmlsoap.org/ws/2006/02/devprof\">\($0)</wsdp:FriendlyName>"
        } ?? ""
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope
            xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
            xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:devprof="http://schemas.xmlsoap.org/ws/2006/02/devprof">
          <soap:Header>
            <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>
          </soap:Header>
          <soap:Body>
            <wsd:ProbeMatches>
              <wsd:ProbeMatch>
                <wsa:EndpointReference>
                  <wsa:Address>urn:uuid:device-uuid-123</wsa:Address>
                </wsa:EndpointReference>
                \(friendlyNameXML)
                <devprof:Hosted>
                  <wsa:EndpointReference>
                    <wsa:Address>http://\(host):\(port)/wsd/scan</wsa:Address>
                  </wsa:EndpointReference>
                  <devprof:Types>\(serviceTypes)</devprof:Types>
                  <devprof:ServiceId>urn:uuid:service-uuid-456</devprof:ServiceId>
                </devprof:Hosted>
              </wsd:ProbeMatch>
            </wsd:ProbeMatches>
          </soap:Body>
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }

    static func malformedResponse() -> Data {
        Data("this is not xml at all <<<".utf8)
    }

    static func emptyEnvelopeResponse() -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
          <soap:Body/>
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }

    static func hostnameProbeMatchResponse(hostname: String = "samsung-m2070.local") -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope
            xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
            xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:devprof="http://schemas.xmlsoap.org/ws/2006/02/devprof">
          <soap:Body>
            <wsd:ProbeMatches>
              <wsd:ProbeMatch>
                <devprof:Hosted>
                  <wsa:EndpointReference>
                    <wsa:Address>http://\(hostname):8018/wsd/scan</wsa:Address>
                  </wsa:EndpointReference>
                  <devprof:Types>scan:ScannerServiceType</devprof:Types>
                </devprof:Hosted>
              </wsd:ProbeMatch>
            </wsd:ProbeMatches>
          </soap:Body>
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }
}

// MARK: - Tests

final class WSScannerDiscoveryTests: XCTestCase {

    // MARK: - parseProbeMatch

    func testParsesHostFromValidProbeMatch() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let data = DiscoveryFixtures.probeMatchesResponse(host: "192.168.1.66")
        let target = discovery.parseProbeMatch(data)
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.host, "192.168.1.66")
        XCTAssertEqual(target?.source, .discovered)
    }

    func testParsesHostnameFromProbeMatch() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let data = DiscoveryFixtures.hostnameProbeMatchResponse(hostname: "samsung-m2070.local")
        let target = discovery.parseProbeMatch(data)
        XCTAssertEqual(target?.host, "samsung-m2070.local")
    }

    func testParsesFriendlyNameWhenPresent() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let data = DiscoveryFixtures.probeMatchesResponse(host: "192.168.1.66", friendlyName: "Samsung M2070")
        let target = discovery.parseProbeMatch(data)
        XCTAssertEqual(target?.displayName, "Samsung M2070")
    }

    func testDisplayNameNilWhenFriendlyNameAbsent() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let data = DiscoveryFixtures.probeMatchesResponse(host: "192.168.1.66")
        let target = discovery.parseProbeMatch(data)
        XCTAssertNil(target?.displayName)
    }

    func testIgnoresNonScannerProbeMatch() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let data = DiscoveryFixtures.probeMatchesResponse(includeScannerType: false)
        let target = discovery.parseProbeMatch(data)
        XCTAssertNil(target, "Non-scanner ProbeMatch should be silently ignored")
    }

    func testIgnoresMalformedXML() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let target = discovery.parseProbeMatch(DiscoveryFixtures.malformedResponse())
        XCTAssertNil(target)
    }

    func testIgnoresEmptyEnvelope() async throws {
        let discovery = WSScannerDiscovery(transport: MockDiscoveryTransport())
        let target = discovery.parseProbeMatch(DiscoveryFixtures.emptyEnvelopeResponse())
        XCTAssertNil(target)
    }

    // MARK: - start via mock transport

    func testStartDeliversDiscoveredTargetsViaCallback() async throws {
        let response = DiscoveryFixtures.probeMatchesResponse(host: "10.0.0.5")
        let transport = MockDiscoveryTransport(responses: [response])
        let discovery = WSScannerDiscovery(transport: transport)

        let collector = TargetCollector()
        await discovery.start { target in
            Task { await collector.add(target) }
        }
        // Yield to let the async onFound tasks run.
        try await waitFor(timeout: 1) { await collector.count >= 1 }

        let targets = await collector.targets
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.host, "10.0.0.5")
        XCTAssertEqual(targets.first?.source, .discovered)
    }

    func testStartDeliversMultipleTargetsFromMultipleResponses() async throws {
        let responses = [
            DiscoveryFixtures.probeMatchesResponse(host: "10.0.0.1"),
            DiscoveryFixtures.probeMatchesResponse(host: "10.0.0.2"),
        ]
        let transport = MockDiscoveryTransport(responses: responses)
        let discovery = WSScannerDiscovery(transport: transport)

        let collector = TargetCollector()
        await discovery.start { target in
            Task { await collector.add(target) }
        }
        // Yield to let the async onFound tasks run.
        try await waitFor(timeout: 1) { await collector.count >= 2 }

        let targets = await collector.targets
        XCTAssertEqual(targets.count, 2)
        XCTAssertTrue(targets.contains { $0.host == "10.0.0.1" })
        XCTAssertTrue(targets.contains { $0.host == "10.0.0.2" })
    }

    func testTransportErrorResultsInNoTargets() async throws {
        let transport = MockDiscoveryTransport(error: URLError(.networkConnectionLost))
        let discovery = WSScannerDiscovery(transport: transport)

        let collector = TargetCollector()
        await discovery.start { target in Task { await collector.add(target) } }

        let count = await collector.count
        XCTAssertEqual(count, 0)
    }

    func testStartBlocksUntilProbeCompletes() async throws {
        // start() must be truly async — it should block until the transport returns.
        var didComplete = false
        let transport = MockDiscoveryTransport(responses: [])
        let discovery = WSScannerDiscovery(transport: transport)
        await discovery.start { _ in }
        didComplete = true
        XCTAssertTrue(didComplete, "start() should return only after the probe completes")
    }

    func testCancellationViaTaskCancelInterruptsStart() async throws {
        // Transport that blocks until Task.sleep is cancelled.
        struct BlockingTransport: WSDDiscoveryTransport {
            func sendAndReceive(probe: Data, timeout: TimeInterval) async throws -> [Data] {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }
        let discovery = WSScannerDiscovery(transport: BlockingTransport())
        let task = Task { await discovery.start { _ in } }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        await task.value
        // Completing without timeout means cancellation worked.
    }
}

// MARK: - Thread-safe target collector for tests

actor TargetCollector {
    private(set) var targets: [ScannerTarget] = []
    var count: Int { targets.count }
    func add(_ target: ScannerTarget) { targets.append(target) }
}

// MARK: - Async polling helper

private func waitFor(timeout: TimeInterval, condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
