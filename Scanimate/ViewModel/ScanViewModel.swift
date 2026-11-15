import SwiftUI

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
    /// Discovered targets to list in the device picker: those whose host is not
    /// already a saved target, so a host in both lists appears once (under Saved).
    var unsavedDiscoveredTargets: [ScannerTarget] {
        discoveredTargets.filter { discovered in
            !savedTargets.contains { $0.host == discovered.host }
        }
    }
    /// True while the background WS-Discovery probe is running.
    @Published private(set) var isDiscovering: Bool = false

    // MARK: - Scan settings

    @Published var resolution: Resolution = .dpi300
    @Published var colorMode: ColorMode = .grayscale
    @Published var paperSize: PaperSize = .letter
    @Published var inputSource: InputSource = .flatbed {
        didSet { refreshDestinationPlan() }
    }

    // MARK: - Destination

    /// The Destination's name as typed, without an extension. Persisted.
    @Published var destinationName: String = Destination.defaultName {
        didSet {
            defaults.set(destinationName, forKey: Self.destinationNameKey)
            refreshDestinationPlan()
        }
    }
    /// The file type chosen for Platen scans. Persisted. An ADF ScanJob ignores
    /// it (see `fileType`), and it comes back when the source returns to the Platen.
    @Published var platenFileType: FileType = .png {
        didSet {
            defaults.set(platenFileType.rawValue, forKey: Self.destinationFileTypeKey)
            refreshDestinationPlan()
        }
    }
    /// The Destination's folder. Held for this launch only — never persisted —
    /// so it is nil, and Scan is disabled, until the user chooses one.
    @Published var destinationFolder: URL? {
        didSet { refreshDestinationPlan() }
    }
    /// "Add to existing PDF". Session-only — never persisted — so every launch
    /// starts with it off and cannot add to an old file by surprise. It only
    /// applies while the file type is PDF (see `destination`).
    @Published var appendToExistingPDF: Bool = false {
        didSet { refreshDestinationPlan() }
    }
    /// What the next write to the Destination will do. A preview: it is
    /// recomputed at the moment of the write.
    @Published private(set) var destinationPlan: DestinationPlan = .blocked(.noFolder)
    /// The outcome of writing the current ScanResult, or nil when there is none.
    @Published private(set) var saveStatus: SaveStatus?

    enum SaveStatus: Equatable {
        case saved(fileName: String, folderName: String)
        /// The pages were added to an existing PDF, which now holds `totalPageCount`.
        case appended(fileName: String, addedPageCount: Int, totalPageCount: Int)
        /// The write failed; the ScanResult is still in memory for a retry.
        case failed(String)
    }

    /// An ADF ScanJob produces several pages and only PDF can hold them.
    var isFileTypeForced: Bool { inputSource == .adf }

    /// The file type the Destination writes: PDF for the ADF, the user's
    /// choice for the Platen.
    var fileType: FileType {
        isFileTypeForced ? .pdf : platenFileType
    }

    /// Append can only apply to a PDF, so the checkbox is offered only then.
    var canAppendToExistingPDF: Bool { fileType == .pdf }

    var destination: Destination {
        Destination(
            name: destinationName,
            fileType: fileType,
            folder: destinationFolder,
            // The checkbox's value is ignored while it is hidden.
            append: appendToExistingPDF && canAppendToExistingPDF
        )
    }

    /// One sentence saying what the next scan will write, or why Scan is disabled.
    var destinationCaption: String { destinationPlan.caption }

    /// Recomputes `destinationPlan` from the Destination and the disk. Called
    /// when a Destination field changes, after each save, and when the app
    /// becomes active (files may have changed behind its back).
    func refreshDestinationPlan() {
        let writer = destinationWriter
        let plan = destination.plan(
            fileExists: { writer.fileExists(at: $0) },
            appendTarget: { writer.appendTarget(at: $0) }
        )
        if plan != destinationPlan { destinationPlan = plan }
    }

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
    private var activeDiscovery: (any ScannerDiscoveryProtocol)?

    private var scannerFactory: @Sendable (String) -> any WSDScannerProtocol
    private var discoveryFactory: @Sendable () -> any ScannerDiscoveryProtocol
    private let destinationWriter: any DestinationWriter
    /// Where the Destination's name and file type are persisted.
    private let defaults: UserDefaults

    // MARK: - Persistence keys

    private static let savedTargetsKey = "savedTargets"
    private static let lastUsedHostKey = "lastUsedHost"
    private static let destinationNameKey = "destinationName"
    private static let destinationFileTypeKey = "destinationFileType"

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

    /// True when the source is the Platen and the user has not drawn a
    /// ScanRegion yet. A Platen ScanJob needs one; an ADF ScanJob does not.
    var needsScanRegion: Bool {
        inputSource == .flatbed && selectedRegion == nil
    }

    /// The whole gate for starting a ScanJob. A ScanJob's ScanResult is
    /// written the moment it completes, so the Destination must be valid first.
    var canScan: Bool {
        !isScanning && !isOverviewing && activeHost != nil && !needsScanRegion
            && !destinationPlan.isBlocked
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
            switch saveStatus {
            case .saved(let fileName, let folderName):
                return "Saved \(fileName) to \(folderName)"
            case .appended(let fileName, let addedPageCount, let totalPageCount):
                return "Added \(DestinationPlan.pageCountText(addedPageCount)) to \(fileName)"
                    + " (\(DestinationPlan.pageCountText(totalPageCount)))"
            case .failed(let reason):
                return "Not saved. \(reason)"
            case nil:
                return "Scan complete."
            }
        case .failed:
            return "Scan failed."
        case .cancelled:
            return "Scan cancelled."
        }
    }

    // MARK: - Init

    init(
        scannerFactory: @escaping @Sendable (String) -> any WSDScannerProtocol = { WSDScanner(host: $0) },
        discoveryFactory: @escaping @Sendable () -> any ScannerDiscoveryProtocol = { WSScannerDiscovery() },
        destinationWriter: any DestinationWriter = FileDestinationWriter(),
        defaults: UserDefaults = .standard
    ) {
        self.scannerFactory = scannerFactory
        self.discoveryFactory = discoveryFactory
        self.destinationWriter = destinationWriter
        self.defaults = defaults
        // Property observers do not run during init, so nothing is written back.
        if let name = defaults.string(forKey: Self.destinationNameKey) {
            destinationName = name
        }
        if let raw = defaults.string(forKey: Self.destinationFileTypeKey),
           let type = FileType(rawValue: raw) {
            platenFileType = type
        }
        loadPersistedState()
        refreshDestinationPlan()
    }

    // MARK: - Actions

    func startScan() {
        guard canScan, let host = resolveHost() else { return }
        overviewTask?.cancel()
        let scanner = scannerFactory(host)
        var ticket = ScanTicket(
            resolution: resolution,
            colorMode: colorMode,
            paperSize: paperSize,
            source: inputSource
        )
        // A ScanRegion is a subset of the Platen; it means nothing to the ADF.
        if inputSource == .flatbed {
            ticket.scanRegion = selectedRegion
        }

        // Starting the next ScanJob lets go of the previous ScanResult.
        saveStatus = nil
        previewPages = []
        jobState = .checkingScanner

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pages = try await scanner.scan(ticket: ticket) { @MainActor [weak self] state in
                    self?.jobState = state
                }
                self.jobState = .complete(pages)
                self.previewPages = pages
                self.saveScanResult()
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

        // The ScanRegion is deliberately left alone: it persists across Overview
        // runs for the session and only changes when the user drags a new one.
        // The previous ScanResult's preview makes way for the Overview.
        resetForNextScan()
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
        saveStatus = nil
        alertError = nil
    }

    // MARK: - Target selection

    /// Sets selectedTarget by matching host string, or clears selection if host is nil.
    func selectTarget(byHost host: String?) {
        guard let host else {
            selectedTarget = nil
            return
        }
        // Saved first: a host in both lists is shown only under Saved in the picker.
        selectedTarget = (savedTargets + discoveredTargets).first { $0.host == host }
    }

    /// Removes a saved target immediately, with no confirmation. If it was the
    /// selected target, falls back to the first remaining saved target, or
    /// clears to manual entry if none remain.
    func removeSavedTarget(_ target: ScannerTarget) {
        savedTargets.removeAll { $0.host == target.host }
        persistSavedTargets()

        if selectedTarget?.host == target.host {
            selectedTarget = savedTargets.first
        }
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        let factory = discoveryFactory
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let discovery = factory()
            self.activeDiscovery = discovery
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
        if let discovery = activeDiscovery {
            activeDiscovery = nil
            Task { await discovery.stop() }
        }
    }

    private func handleDiscoveredTarget(_ target: ScannerTarget) {
        if let index = discoveredTargets.firstIndex(where: { $0.host == target.host }) {
            // A later delivery for the same host (e.g. a resolved hostname arriving
            // after the initial probe result) updates the display name in place.
            if let displayName = target.displayName, discoveredTargets[index].displayName == nil {
                discoveredTargets[index].displayName = displayName
            }
        } else {
            discoveredTargets.append(target)
        }

        guard let displayName = target.displayName else { return }

        // Backfill a saved target that was saved before its name resolved, so
        // it stops showing the bare IP — now and after relaunch.
        if let savedIndex = savedTargets.firstIndex(where: { $0.host == target.host }),
           savedTargets[savedIndex].displayName == nil {
            savedTargets[savedIndex].displayName = displayName
            persistSavedTargets()
        }
        if selectedTarget?.host == target.host, selectedTarget?.displayName == nil {
            selectedTarget?.displayName = displayName
        }
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        // Load saved manual targets.
        if let data = UserDefaults.standard.data(forKey: Self.savedTargetsKey),
           let decoded = try? JSONDecoder().decode([ScannerTarget].self, from: data) {
            savedTargets = decoded
        }

        // Migrate legacy ipAddress key, once.
        let legacy = UserDefaults.standard.string(forKey: "ipAddress") ?? ""
        if !legacy.isEmpty {
            if !savedTargets.contains(where: { $0.host == legacy }) {
                let migrated = ScannerTarget(host: legacy, displayName: nil, source: .manual)
                savedTargets.append(migrated)
                persistSavedTargets()
            }
            UserDefaults.standard.removeObject(forKey: "ipAddress")
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

    /// Writes the pages again after a failed write. The plan is recomputed, so
    /// a retry picks up a newly chosen folder, a name that has since been taken,
    /// or an append target that has been fixed or unticked.
    func retrySave() {
        guard case .failed = saveStatus else { return }
        saveScanResult()
    }

    /// Writes the completed ScanJob's ScanResult to the Destination through the
    /// DestinationWriter. The plan is recomputed here; the caption was only a preview.
    /// On failure the pages stay in memory and `saveStatus` carries the reason.
    /// An append whose target has become unusable fails here; it never falls
    /// back to creating a different file.
    private func saveScanResult() {
        guard case .complete(let pages) = jobState, !pages.isEmpty else { return }
        let dpiValue = Int(resolution.rawValue) ?? 300

        refreshDestinationPlan()
        guard let url = destinationPlan.url, let folder = destinationFolder else {
            saveStatus = .failed(destinationPlan.caption)
            return
        }

        do {
            let outcome = try destinationWriter.write(
                pages: pages, dpi: dpiValue, to: url, as: fileType, append: destinationPlan.isAppend
            )
            switch outcome {
            case .created:
                saveStatus = .saved(fileName: url.lastPathComponent, folderName: folder.lastPathComponent)
            case .appended(let addedPageCount, let totalPageCount):
                saveStatus = .appended(
                    fileName: url.lastPathComponent,
                    addedPageCount: addedPageCount,
                    totalPageCount: totalPageCount
                )
            }
            refreshDestinationPlan()
        } catch {
            if destinationWriter.fileExists(at: folder) {
                saveStatus = .failed(error.localizedDescription)
                refreshDestinationPlan()
            } else {
                // The folder vanished: forget it so the caption asks for a new one.
                saveStatus = .failed(
                    "The folder \u{201C}\(folder.lastPathComponent)\u{201D} is no longer there. Choose a folder, then retry."
                )
                destinationFolder = nil
            }
        }
    }
}
