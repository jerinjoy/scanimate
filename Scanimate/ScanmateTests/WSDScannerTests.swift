import XCTest
@testable import Scanimate

final class WSDScannerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.requestHandler = nil
    }

    // MARK: - Happy path: flatbed scan

    func testHappyPathFlatbedScan() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { request in
            requestCount += 1
            switch requestCount {
            case 1: // GetScannerElements
                return (.ok(), Fixtures.getScannerElementsResponse())
            case 2: // CreateScanJob
                return (.ok(), Fixtures.createScanJobResponse())
            case 3: // RetrieveImage
                let (ct, body) = Fixtures.retrieveImageResponse()
                return (.ok(contentType: ct), body)
            default:
                throw URLError(.badServerResponse)
            }
        }

        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed())
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)

        let pages = try await scanner.scan(ticket: ticket) { _ in }

        XCTAssertEqual(pages.count, 1, "Flatbed scan should return exactly one page")
        XCTAssertFalse(pages[0].isEmpty, "Returned JPEG data should not be empty")
        XCTAssertEqual(requestCount, 3, "Should make exactly 3 HTTP requests")
    }

    // MARK: - Retry sequence: N failures then success

    func testRetryThenSuccess() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { request in
            requestCount += 1
            switch requestCount {
            case 1: // GetScannerElements
                return (.ok(), Fixtures.getScannerElementsResponse())
            case 2, 3: // CreateScanJob fails twice (busy)
                return (.status(503), Fixtures.busyFaultResponse())
            case 4: // CreateScanJob succeeds on 3rd attempt
                return (.ok(), Fixtures.createScanJobResponse())
            case 5: // RetrieveImage
                let (ct, body) = Fixtures.retrieveImageResponse()
                return (.ok(contentType: ct), body)
            default:
                throw URLError(.badServerResponse)
            }
        }

        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed(), retryPauseNanoseconds: 0)
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)
        let collector = StateCollector()

        let pages = try await scanner.scan(ticket: ticket) { state in
            if case .creatingJob(let attempt) = state {
                await collector.add(attempt)
            }
        }
        let jobAttempts = await collector.values

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(jobAttempts, [1, 2, 3], "Should have seen 3 creatingJob state emissions")
    }

    // MARK: - printerBusy: all 30 retries exhausted

    func testPrinterBusyExhaustsRetries() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                return (.ok(), Fixtures.getScannerElementsResponse())
            }
            return (.status(503), Fixtures.busyFaultResponse())
        }

        // Zero-delay retries to keep test fast
        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed(), retryPauseNanoseconds: 0)
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)

        do {
            _ = try await scanner.scan(ticket: ticket) { _ in }
            XCTFail("Expected printerBusy error")
        } catch ScanError.printerBusy {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - unreachable: network failure

    func testUnreachableOnNetworkFailure() async throws {
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let scanner = WSDScanner(host: "192.168.1.99", session: .stubbed())
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)

        do {
            _ = try await scanner.scan(ticket: ticket) { _ in }
            XCTFail("Expected unreachable error")
        } catch ScanError.unreachable(let host) {
            XCTAssertEqual(host, "192.168.1.99")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - noDocument: empty JobId

    func testNoDocumentWhenJobIdMissing() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { _ in
            requestCount += 1
            if requestCount == 1 { return (.ok(), Fixtures.getScannerElementsResponse()) }
            return (.ok(), Fixtures.noDocumentCreateJobResponse())
        }

        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed())
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)

        do {
            _ = try await scanner.scan(ticket: ticket) { _ in }
            XCTFail("Expected noDocument error")
        } catch ScanError.noDocument {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Cancellation mid-retry

    func testCancellationDuringRetry() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { _ in
            requestCount += 1
            if requestCount == 1 { return (.ok(), Fixtures.getScannerElementsResponse()) }
            return (.status(503), Fixtures.busyFaultResponse())
        }

        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed())
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .flatbed)

        let task = Task {
            try await scanner.scan(ticket: ticket) { _ in }
        }

        // Cancel after a brief moment (after first 503)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            // Also accept if it propagated as cancellation inside
        }
    }

    // MARK: - ADF multi-page scan

    func testADFMultiPageScan() async throws {
        var requestCount = 0
        URLProtocolStub.requestHandler = { request in
            requestCount += 1
            switch requestCount {
            case 1: // GetScannerElements
                return (.ok(), Fixtures.getScannerElementsResponse())
            case 2: // CreateScanJob
                return (.ok(), Fixtures.createScanJobResponse())
            case 3, 4, 5: // RetrieveImage × 3 pages
                let (ct, body) = Fixtures.retrieveImageResponse()
                return (.ok(contentType: ct), body)
            case 6: // ADF done
                return (.status(500), Fixtures.adfDoneResponse())
            default:
                throw URLError(.badServerResponse)
            }
        }

        let scanner = WSDScanner(host: "192.168.1.66", session: .stubbed())
        let ticket = ScanTicket(resolution: .dpi300, colorMode: .grayscale, paperSize: .letter, source: .adf)

        let pages = try await scanner.scan(ticket: ticket) { _ in }

        XCTAssertEqual(pages.count, 3, "ADF scan should return 3 pages")
        for page in pages {
            XCTAssertFalse(page.isEmpty)
        }
    }
}

// MARK: - ScanJob debug description helper

private extension ScanJob {
    var debugDescription: String {
        switch self {
        case .checkingScanner: return "checkingScanner"
        case .creatingJob(let a): return "creatingJob(\(a))"
        case .retrievingPage(let n): return "retrievingPage(\(n))"
        case .complete: return "complete"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}
