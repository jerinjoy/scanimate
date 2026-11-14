import XCTest
@testable import Scanimate

final class MDNSHostnameResolverTests: XCTestCase {

    // MARK: - IPv4 to reverse name

    func testReverseLookupNameReversesOctets() {
        XCTAssertEqual(
            MDNSHostnameResolver.reverseLookupName(forIPv4: "192.168.1.66"),
            "66.1.168.192.in-addr.arpa."
        )
        XCTAssertEqual(
            MDNSHostnameResolver.reverseLookupName(forIPv4: "10.0.0.5"),
            "5.0.0.10.in-addr.arpa."
        )
    }

    func testReverseLookupNameNilForNonIPv4Host() {
        XCTAssertNil(MDNSHostnameResolver.reverseLookupName(forIPv4: "samsung-m2070.local"))
        XCTAssertNil(MDNSHostnameResolver.reverseLookupName(forIPv4: "192.168.1"))
        XCTAssertNil(MDNSHostnameResolver.reverseLookupName(forIPv4: "192.168.1.256"))
        XCTAssertNil(MDNSHostnameResolver.reverseLookupName(forIPv4: "fe80::1"))
        XCTAssertNil(MDNSHostnameResolver.reverseLookupName(forIPv4: ""))
    }

    // MARK: - PTR rdata decoding

    private func rdata(_ labels: [String], terminated: Bool = true) -> Data {
        var data = Data()
        for label in labels {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: Array(label.utf8))
        }
        if terminated { data.append(0) }
        return data
    }

    func testDecodePTRRdataJoinsLabelsWithDots() {
        XCTAssertEqual(
            MDNSHostnameResolver.decodePTRRdata(rdata(["Fullyautomatix", "local"])),
            "Fullyautomatix.local"
        )
    }

    func testDecodePTRRdataWithoutRootLabel() {
        XCTAssertEqual(
            MDNSHostnameResolver.decodePTRRdata(rdata(["scanner", "lan"], terminated: false)),
            "scanner.lan"
        )
    }

    func testDecodePTRRdataNilForEmptyOrRootOnly() {
        XCTAssertNil(MDNSHostnameResolver.decodePTRRdata(Data()))
        XCTAssertNil(MDNSHostnameResolver.decodePTRRdata(Data([0])))
    }

    func testDecodePTRRdataNilForTruncatedLabel() {
        // Length byte claims 10 bytes but only 3 follow.
        XCTAssertNil(MDNSHostnameResolver.decodePTRRdata(Data([10, 0x61, 0x62, 0x63])))
    }

    func testDecodePTRRdataNilForCompressionPointer() {
        XCTAssertNil(MDNSHostnameResolver.decodePTRRdata(Data([0xC0, 0x0C])))
    }

    // MARK: - .local stripping

    func testDisplayNameStripsTrailingDotAndLocal() {
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "Fullyautomatix.local."), "Fullyautomatix")
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "Fullyautomatix.local"), "Fullyautomatix")
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "Fullyautomatix.LOCAL."), "Fullyautomatix")
    }

    func testDisplayNameKeepsOtherDomainsAndInnerLocal() {
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "scanner.lan."), "scanner.lan")
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "my.local.scanner"), "my.local.scanner")
        XCTAssertEqual(MDNSHostnameResolver.displayName(fromHostname: "Fullyautomatix"), "Fullyautomatix")
    }

    func testDisplayNameNilWhenNothingLeft() {
        XCTAssertNil(MDNSHostnameResolver.displayName(fromHostname: ""))
        XCTAssertNil(MDNSHostnameResolver.displayName(fromHostname: "."))
        XCTAssertNil(MDNSHostnameResolver.displayName(fromHostname: ".local."))
    }

    // MARK: - Resolver behaviour that needs no network

    func testNonIPv4HostReturnsNilWithoutQuery() async {
        let resolver = MDNSHostnameResolver(timeout: 30)
        let start = Date()
        let name = await resolver.resolveHostname(for: "samsung-m2070.local")
        XCTAssertNil(name)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "a non-IPv4 host must not start a query")
    }

    // MARK: - Chained resolver

    func testChainReturnsFirstResolvedName() async {
        let chain = ChainedHostnameResolver([
            MockHostnameResolver(result: "first"),
            MockHostnameResolver(result: "second"),
        ])
        let name = await chain.resolveHostname(for: "192.168.1.66")
        XCTAssertEqual(name, "first")
    }

    func testChainFallsThroughWhenEarlierResolverFails() async {
        let chain = ChainedHostnameResolver([
            MockHostnameResolver(result: nil),
            MockHostnameResolver(result: "fallback"),
        ])
        let name = await chain.resolveHostname(for: "192.168.1.66")
        XCTAssertEqual(name, "fallback")
    }

    func testChainReturnsNilWhenAllResolversFail() async {
        let chain = ChainedHostnameResolver([
            MockHostnameResolver(result: nil),
            MockHostnameResolver(result: nil),
        ])
        let name = await chain.resolveHostname(for: "192.168.1.66")
        XCTAssertNil(name)
    }
}
