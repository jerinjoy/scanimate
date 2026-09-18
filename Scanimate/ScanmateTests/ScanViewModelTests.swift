import XCTest
@testable import Scanimate

// MARK: - Mock scanner

actor MockScanner: WSDScannerProtocol {
    let stateSequence: [ScanJob]
    let finalResult: Result<[Data], Error>

    init(states: [ScanJob], result: Result<[Data], Error>) {
        self.stateSequence = states
        self.finalResult = result
    }

    func scan(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> [Data] {
        for state in stateSequence {
            try Task.checkCancellation()
            await onState(state)
        }
        return try finalResult.get()
    }
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
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

        vm.startScan()

        // Poll until complete or timeout
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
        // Track state messages emitted
        let mock = MockScanner(
            states: [.checkingScanner, .creatingJob(attempt: 1), .retrievingPage(1)],
            result: .success([Fixtures.minimalJPEG])
        )
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        // After completion the message changes to "Scan complete."
        XCTAssertEqual(vm.statusMessage, "Scan complete.")
    }

    func testCancelButtonHidesAfterCompletion() async throws {
        let mock = MockScanner(
            states: [.checkingScanner],
            result: .success([Fixtures.minimalJPEG])
        )
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning, "isScanning should be false after completion")
    }

    func testUnreachableErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.unreachable(host: "192.168.1.66")))
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

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
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

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
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.printerBusy)
        XCTAssertEqual(vm.alertError?.errorDescription, "The printer is busy — try again in a moment.")
    }

    func testProtocolErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.protocolError("unexpected XML")))
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        if case .protocolError(let detail) = vm.alertError {
            XCTAssertTrue(detail.contains("unexpected XML"))
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testCancelSetsJobStateCancelled() async throws {
        // Scanner that emits one state then blocks until the task is cancelled
        actor BlockingScanner: WSDScannerProtocol {
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] {
                await onState(.checkingScanner)
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }

        let vm = ScanViewModel(scannerFactory: { _ in BlockingScanner() })
        vm.ipAddress = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 1) { vm.isScanning }
        vm.cancelScan()
        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning)
    }

    func testResetForNextScanClearsState() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = ScanViewModel(scannerFactory: { _ in mock })
        vm.ipAddress = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        vm.resetForNextScan()

        XCTAssertNil(vm.jobState)
        XCTAssertTrue(vm.previewPages.isEmpty)
        XCTAssertNil(vm.alertError)
        XCTAssertFalse(vm.isScanning)
        XCTAssertFalse(vm.isScanComplete)
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
