import XCTest
@testable import Scanimate

// MARK: - Mock scanner

actor MockScanner: WSDScannerProtocol {
    let stateSequence: [ScanJob]
    let finalResult: Result<[Data], Error>
    let overviewResult: Result<Data, Error>
    private(set) var capturedTicket: ScanTicket?

    init(
        states: [ScanJob],
        result: Result<[Data], Error>,
        overviewResult: Result<Data, Error> = .success(Fixtures.minimalJPEG)
    ) {
        self.stateSequence = states
        self.finalResult = result
        self.overviewResult = overviewResult
    }

    func scan(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> [Data] {
        capturedTicket = ticket
        for state in stateSequence {
            try Task.checkCancellation()
            await onState(state)
        }
        return try finalResult.get()
    }

    func overview() async throws -> Data {
        return try overviewResult.get()
    }
}

// MARK: - Mock discovery

actor MockDiscovery: ScannerDiscoveryProtocol {
    private let canned: [ScannerTarget]

    init(targets: [ScannerTarget] = []) {
        self.canned = targets
    }

    func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async {
        for target in canned {
            onFound(target)
        }
    }

    func stop() async {}
}

// MARK: - Helpers

@MainActor
private func makeVM(
    mock: MockScanner,
    discoveryTargets: [ScannerTarget] = []
) -> ScanViewModel {
    ScanViewModel(
        scannerFactory: { _ in mock },
        discoveryFactory: { MockDiscovery(targets: discoveryTargets) }
    )
}

// MARK: - Tests

@MainActor
final class ScanViewModelTests: XCTestCase {

    func testHappyPathSetsCompleteState() async throws {
        let jpeg = Fixtures.minimalJPEG
        let mock = MockScanner(
            states: [.checkingScanner, .creatingJob(attempt: 1), .retrievingPage(1)],
            result: .success([jpeg])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()

        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        if case .complete(let pages) = vm.jobState {
            XCTAssertEqual(pages.count, 1)
        } else {
            XCTFail("Expected complete state, got \(String(describing: vm.jobState))")
        }
        XCTAssertNil(vm.alertError)
        XCTAssertFalse(vm.isScanning)
    }

    func testProgressMessageDuringScanning() async throws {
        let mock = MockScanner(
            states: [.checkingScanner, .creatingJob(attempt: 1), .retrievingPage(1)],
            result: .success([Fixtures.minimalJPEG])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        XCTAssertEqual(vm.statusMessage, "Scan complete.")
    }

    func testCancelButtonHidesAfterCompletion() async throws {
        let mock = MockScanner(
            states: [.checkingScanner],
            result: .success([Fixtures.minimalJPEG])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning, "isScanning should be false after completion")
    }

    func testUnreachableErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.unreachable(host: "192.168.1.66")))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.unreachable(host: "192.168.1.66"))
        XCTAssertEqual(
            vm.alertError?.errorDescription,
            "Cannot reach 192.168.1.66 — is the printer on and connected to the network?"
        )
    }

    func testNoDocumentErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.noDocument))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.noDocument)
        XCTAssertEqual(
            vm.alertError?.errorDescription,
            "No document detected — place a page on the glass or load the ADF and try again."
        )
    }

    func testPrinterBusyErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.printerBusy))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.printerBusy)
        XCTAssertEqual(vm.alertError?.errorDescription, "The printer is busy — try again in a moment.")
    }

    func testProtocolErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.protocolError("unexpected XML")))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        if case .protocolError(let detail) = vm.alertError {
            XCTAssertTrue(detail.contains("unexpected XML"))
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testCancelSetsJobStateCancelled() async throws {
        actor BlockingScanner: WSDScannerProtocol {
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] {
                await onState(.checkingScanner)
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
            func overview() async throws -> Data { Data() }
        }

        let vm = ScanViewModel(scannerFactory: { _ in BlockingScanner() })
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 1) { vm.isScanning }
        vm.cancelScan()
        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning)
    }

    func testResetForNextScanClearsState() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        vm.resetForNextScan()

        XCTAssertNil(vm.jobState)
        XCTAssertTrue(vm.previewPages.isEmpty)
        XCTAssertNil(vm.alertError)
        XCTAssertFalse(vm.isScanning)
        XCTAssertFalse(vm.isScanComplete)
    }

    // MARK: - Overview tests

    func testStartOverviewSetsIsOverviewing() async throws {
        actor DelayedOverviewScanner: WSDScannerProtocol {
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] { [] }
            func overview() async throws -> Data {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Data()
            }
        }

        let vm = ScanViewModel(scannerFactory: { _ in DelayedOverviewScanner() })
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 1) { vm.isOverviewing }
        XCTAssertTrue(vm.isOverviewing)

        vm.overviewTask?.cancel()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing }
        XCTAssertFalse(vm.isOverviewing)
    }

    func testStartOverviewPopulatesOverviewImage() async throws {
        let jpeg = Fixtures.minimalJPEG
        let mock = MockScanner(
            states: [],
            result: .success([]),
            overviewResult: .success(jpeg)
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing && vm.overviewImage != nil }

        XCTAssertEqual(vm.overviewImage, jpeg)
        XCTAssertFalse(vm.isOverviewing)
    }

    func testStartOverviewResetsSelectedRegion() async throws {
        let mock = MockScanner(
            states: [],
            result: .success([]),
            overviewResult: .success(Fixtures.minimalJPEG)
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.selectedRegion = ScanRegion(xOffset: 100, yOffset: 100, width: 5000, height: 5000)

        vm.startOverview()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing }

        XCTAssertNil(vm.selectedRegion)
    }

    func testStartScanPassesSelectedRegionToTicket() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        let region = ScanRegion(xOffset: 1000, yOffset: 2000, width: 5000, height: 6000)
        vm.selectedRegion = region

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        let captured = await mock.capturedTicket
        XCTAssertEqual(captured?.scanRegion, region)
    }

    func testOverviewErrorSetsAlertError() async throws {
        let mock = MockScanner(
            states: [],
            result: .success([]),
            overviewResult: .failure(ScanError.unreachable(host: "192.168.1.66"))
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.unreachable(host: "192.168.1.66"))
        XCTAssertFalse(vm.isOverviewing)
    }

    // MARK: - selectedTarget tests

    func testActiveHostFromSelectedTarget() {
        let vm = ScanViewModel()
        let target = ScannerTarget(host: "10.0.0.5", displayName: "Samsung M2070", source: .discovered)
        vm.selectedTarget = target
        XCTAssertEqual(vm.activeHost, "10.0.0.5")
    }

    func testActiveHostFromManualHostWhenNoTargetSelected() {
        let vm = ScanViewModel()
        vm.selectedTarget = nil
        vm.manualHost = "192.168.1.99"
        XCTAssertEqual(vm.activeHost, "192.168.1.99")
    }

    func testActiveHostNilWhenNeitherSet() {
        let vm = ScanViewModel()
        vm.selectedTarget = nil
        vm.manualHost = "   "
        XCTAssertNil(vm.activeHost)
    }

    func testScanUsesSelectedTargetHost() async throws {
        let capturedHost = CapturedHost()
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = ScanViewModel(
            scannerFactory: { host in Task { await capturedHost.set(host) }; return mock },
            discoveryFactory: { MockDiscovery() }
        )
        let target = ScannerTarget(host: "10.0.0.42", displayName: nil, source: .discovered)
        vm.selectedTarget = target

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        let host = await capturedHost.value
        XCTAssertEqual(host, "10.0.0.42")
    }

    // MARK: - Discovery integration tests

    func testStartDiscoverySetsIsDiscovering() async throws {
        struct SlowDiscovery: ScannerDiscoveryProtocol {
            func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            func stop() async {}
        }
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { SlowDiscovery() }
        )

        vm.startDiscovery()
        try await waitForCondition(timeout: 1) { vm.isDiscovering }
        XCTAssertTrue(vm.isDiscovering)

        vm.stopDiscovery()
        try await waitForCondition(timeout: 2) { !vm.isDiscovering }
        XCTAssertFalse(vm.isDiscovering)
    }

    func testIsDiscoveringDropsToFalseAfterProbeCompletes() async throws {
        // start() is truly async — isDiscovering must be false after each probe.
        let transport = MockDiscoveryTransport(responses: [])
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { WSScannerDiscovery(transport: transport) }
        )

        vm.startDiscovery()
        // Wait for at least one full probe cycle to complete.
        try await waitForCondition(timeout: 5) { !vm.isDiscovering }
        XCTAssertFalse(vm.isDiscovering)
    }

    func testDiscoveredTargetsPopulateFromDiscovery() async throws {
        let targets = [
            ScannerTarget(host: "10.0.0.1", displayName: "Scanner A", source: .discovered),
            ScannerTarget(host: "10.0.0.2", displayName: "Scanner B", source: .discovered),
        ]
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery(targets: targets) }
        )

        vm.startDiscovery()
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 2 }

        XCTAssertEqual(vm.discoveredTargets.count, 2)
        XCTAssertTrue(vm.discoveredTargets.contains { $0.host == "10.0.0.1" })
        XCTAssertTrue(vm.discoveredTargets.contains { $0.host == "10.0.0.2" })
    }

    func testDuplicateDiscoveredTargetsAreDeduped() async throws {
        let duplicate = ScannerTarget(host: "10.0.0.1", displayName: nil, source: .discovered)
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery(targets: [duplicate, duplicate]) }
        )

        vm.startDiscovery()
        // Wait until at least the first callback has been processed.
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 1 }
        // Yield briefly so any remaining pending callbacks (the duplicate) also run.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.discoveredTargets.count, 1)
    }

    // MARK: - Persistence tests

    func testSavedTargetRoundTripsThroughPersistence() async throws {
        let testHost = "192.168.99.99"

        UserDefaults.standard.removeObject(forKey: "savedTargets")
        UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        UserDefaults.standard.removeObject(forKey: "ipAddress")
        defer {
            UserDefaults.standard.removeObject(forKey: "savedTargets")
            UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        }

        // Scan with a manual host — resolveHost() should save it to UserDefaults.
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = testHost
        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }
        XCTAssertTrue(vm.savedTargets.contains { $0.host == testHost }, "Manual host should be in savedTargets after scan")

        // A fresh VM should restore the saved target from UserDefaults.
        let vm2 = makeVM(mock: MockScanner(states: [], result: .success([])))
        XCTAssertTrue(vm2.savedTargets.contains { $0.host == testHost }, "Saved targets should persist across VM instances")
        XCTAssertEqual(vm2.selectedTarget?.host, testHost, "Last-used target should be restored as selectedTarget")
    }

    // MARK: - Helpers

    private func waitForCondition(timeout: TimeInterval, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}

// MARK: - Thread-safe host capture

actor CapturedHost {
    private(set) var value: String?
    func set(_ host: String) { value = host }
}
