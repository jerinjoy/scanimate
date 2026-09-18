import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Settings (persisted via @AppStorage equivalent)
    @Published var ipAddress: String = ""
    @Published var resolution: Resolution = .dpi300
    @Published var colorMode: ColorMode = .grayscale
    @Published var paperSize: PaperSize = .letter
    @Published var inputSource: InputSource = .flatbed

    // MARK: - Scan state
    @Published private(set) var jobState: ScanJob?
    @Published var alertError: ScanError?
    @Published private(set) var previewPages: [Data] = []

    // MARK: - Overview state
    @Published private(set) var isOverviewing: Bool = false
    @Published private(set) var overviewImage: Data? = nil
    @Published var selectedRegion: ScanRegion? = nil

    // MARK: - Internal
    private(set) var scanTask: Task<Void, Never>?
    private(set) var overviewTask: Task<Void, Never>?
    private var scannerFactory: @Sendable (String) -> any WSDScannerProtocol

    var isScanning: Bool {
        guard let state = jobState else { return false }
        switch state {
        case .checkingScanner, .creatingJob, .retrievingPage: return true
        default: return false
        }
    }

    var isScanComplete: Bool {
        if case .complete = jobState { return true }
        return false
    }

    var statusMessage: String {
        guard let state = jobState else { return "" }
        switch state {
        case .checkingScanner:
            return "Checking scanner…"
        case .creatingJob(let attempt):
            return "Waiting for printer (attempt \(attempt) of 30)…"
        case .retrievingPage(let n):
            return "Scanning page \(n)…"
        case .complete:
            return "Scan complete."
        case .failed:
            return "Scan failed."
        case .cancelled:
            return "Scan cancelled."
        }
    }

    // MARK: - Init

    init(scannerFactory: @escaping @Sendable (String) -> any WSDScannerProtocol = { WSDScanner(host: $0) }) {
        self.scannerFactory = scannerFactory
    }

    // MARK: - Actions

    func startScan() {
        guard !ipAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        overviewTask?.cancel()
        let scanner = scannerFactory(ipAddress.trimmingCharacters(in: .whitespaces))
        var ticket = ScanTicket(
            resolution: resolution,
            colorMode: colorMode,
            paperSize: paperSize,
            source: inputSource
        )
        ticket.scanRegion = selectedRegion

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pages = try await scanner.scan(ticket: ticket) { @MainActor [weak self] state in
                    self?.jobState = state
                }
                self.jobState = .complete(pages)
                self.previewPages = pages
            } catch is CancellationError {
                self.jobState = .cancelled
            } catch let error as ScanError {
                self.jobState = .failed(error)
                self.alertError = error
            } catch {
                let se = ScanError.protocolError(error.localizedDescription)
                self.jobState = .failed(se)
                self.alertError = se
            }
        }
    }

    func startOverview() {
        guard !ipAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let scanner = scannerFactory(ipAddress.trimmingCharacters(in: .whitespaces))

        selectedRegion = nil
        isOverviewing = true
        overviewImage = nil

        overviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await scanner.overview()
                self.overviewImage = data
                self.isOverviewing = false
            } catch is CancellationError {
                self.isOverviewing = false
            } catch let error as ScanError {
                self.isOverviewing = false
                self.alertError = error
            } catch {
                self.isOverviewing = false
                let se = ScanError.protocolError(error.localizedDescription)
                self.alertError = se
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func resetForNextScan() {
        scanTask = nil
        jobState = nil
        previewPages = []
        alertError = nil
        // selectedRegion and overviewImage persist across scans within a session
    }

    // MARK: - Save

    func save() {
        guard case .complete(let pages) = jobState, !pages.isEmpty else { return }
        let isADF = inputSource == .adf
        let dpiValue = Int(resolution.rawValue) ?? 300

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = isADF ? "Scan" : "Scan"

        let pdfType = UTType.pdf
        let pngType = UTType.png
        let tiffType = UTType.tiff

        if isADF {
            savePanel.allowedContentTypes = [pdfType, pngType, tiffType]
            savePanel.nameFieldStringValue = "Scan.pdf"
        } else {
            savePanel.allowedContentTypes = [pngType, tiffType]
            savePanel.nameFieldStringValue = "Scan.png"
        }

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            if isADF && url.pathExtension.lowercased() == "pdf" {
                try savePDF(pages: pages, to: url)
            } else {
                guard let first = pages.first else { return }
                try saveImage(jpeg: first, dpi: dpiValue, to: url)
            }
            resetForNextScan()
        } catch {
            alertError = .protocolError("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Export helpers

    private func saveImage(jpeg: Data, dpi: Int, to url: URL) throws {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.protocolError("Could not decode JPEG for export")
        }

        let ext = url.pathExtension.lowercased()
        let utType: CFString = ext == "tiff" || ext == "tif" ? "public.tiff" as CFString : "public.png" as CFString

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
            throw ScanError.protocolError("Could not create image destination")
        }

        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScanError.protocolError("Could not write image to disk")
        }
    }

    private func savePDF(pages: [Data], to url: URL) throws {
        let pdfDoc = PDFDocument()

        for (index, jpeg) in pages.enumerated() {
            guard let nsImage = NSImage(data: jpeg),
                  let page = PDFPage(image: nsImage) else {
                throw ScanError.protocolError("Could not create PDF page \(index + 1)")
            }
            pdfDoc.insert(page, at: pdfDoc.pageCount)
        }

        guard pdfDoc.write(to: url) else {
            throw ScanError.protocolError("Could not write PDF to disk")
        }
    }
}
