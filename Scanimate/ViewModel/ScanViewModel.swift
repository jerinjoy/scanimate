import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Scanner target

    /// The target selected in the picker, or nil when "Other…" is active.
    @Published var selectedTarget: ScannerTarget? = nil
    /// Host text typed in the manual-entry field (used when selectedTarget is nil).
    @Published var manualHost: String = ""
    /// Targets discovered via WS-Discovery in the current session.
    @Published private(set) var discoveredTargets: [ScannerTarget] = []
    /// Manually entered targets that have been saved across sessions.
    @Published private(set) var savedTargets: [ScannerTarget] = []
    /// True while the background WS-Discovery probe is running.
    @Published private(set) var isDiscovering: Bool = false

    // MARK: - Scan settings

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
    private var discoveryTask: Task<Void, Never>?

    private var scannerFactory: @Sendable (String) -> any WSDScannerProtocol
    private var discoveryFactory: @Sendable () -> any ScannerDiscoveryProtocol

    // MARK: - Persistence keys

    private static let savedTargetsKey = "savedTargets"
    private static let lastUsedHostKey = "lastUsedHost"

    // MARK: - Derived host

    /// The host string to pass to the scanner factory. Non-nil only when a target is configured.
    var activeHost: String? {
        if let target = selectedTarget {
            let h = target.host.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : h
        }
        let h = manualHost.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

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

    init(
        scannerFactory: @escaping @Sendable (String) -> any WSDScannerProtocol = { WSDScanner(host: $0) },
        discoveryFactory: @escaping @Sendable () -> any ScannerDiscoveryProtocol = { WSScannerDiscovery() }
    ) {
        self.scannerFactory = scannerFactory
        self.discoveryFactory = discoveryFactory
        loadPersistedState()
    }

    // MARK: - Actions

    func startScan() {
        guard let host = resolveHost() else { return }
        overviewTask?.cancel()
        let scanner = scannerFactory(host)
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
        guard let host = resolveHost() else { return }
        let scanner = scannerFactory(host)

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
    }

    // MARK: - Target selection

    /// Sets selectedTarget by matching host string, or clears selection if host is nil.
    func selectTarget(byHost host: String?) {
        guard let host else {
            selectedTarget = nil
            return
        }
        selectedTarget = (discoveredTargets + savedTargets).first { $0.host == host }
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        let factory = discoveryFactory
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let discovery = factory()
            while !Task.isCancelled {
                self.isDiscovering = true
                await discovery.start { @Sendable [weak self] target in
                    Task { @MainActor [weak self] in
                        self?.handleDiscoveredTarget(target)
                    }
                }
                self.isDiscovering = false
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
            self.isDiscovering = false
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
    }

    private func handleDiscoveredTarget(_ target: ScannerTarget) {
        guard !discoveredTargets.contains(where: { $0.host == target.host }) else { return }
        discoveredTargets.append(target)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        // Load saved manual targets.
        if let data = UserDefaults.standard.data(forKey: Self.savedTargetsKey),
           let decoded = try? JSONDecoder().decode([ScannerTarget].self, from: data) {
            savedTargets = decoded
        }

        // Migrate legacy ipAddress key.
        let legacy = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
        if !legacy.isEmpty && !savedTargets.contains(where: { $0.host == legacy }) {
            let migrated = ScannerTarget(host: legacy, displayName: nil, source: .manual)
            savedTargets.append(migrated)
            persistSavedTargets()
        }

        // Restore last-used host.
        if let lastHost = UserDefaults.standard.string(forKey: Self.lastUsedHostKey), !lastHost.isEmpty {
            if let target = (discoveredTargets + savedTargets).first(where: { $0.host == lastHost }) {
                selectedTarget = target
            } else {
                // Not in any list yet — pre-fill the manual field.
                manualHost = lastHost
            }
        }
    }

    /// Resolves the active host, saves it to the appropriate list, and persists the
    /// last-used key. Returns nil if no host is configured.
    private func resolveHost() -> String? {
        guard let host = activeHost else { return nil }
        if let target = selectedTarget {
            // Promote discovered targets to savedTargets so they survive relaunch.
            if target.source == .discovered {
                saveTargetIfNeeded(ScannerTarget(host: target.host, displayName: target.displayName, source: .manual))
            }
        } else {
            saveTargetIfNeeded(ScannerTarget(host: host, displayName: nil, source: .manual))
        }
        persistLastUsedHost()
        return host
    }

    private func saveTargetIfNeeded(_ target: ScannerTarget) {
        guard !savedTargets.contains(where: { $0.host == target.host }) else { return }
        savedTargets.append(target)
        persistSavedTargets()
    }

    private func persistSavedTargets() {
        if let data = try? JSONEncoder().encode(savedTargets) {
            UserDefaults.standard.set(data, forKey: Self.savedTargetsKey)
        }
    }

    private func persistLastUsedHost() {
        UserDefaults.standard.set(activeHost, forKey: Self.lastUsedHostKey)
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
