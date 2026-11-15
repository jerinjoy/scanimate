import SwiftUI

struct ScanPanelView: View {
    @ObservedObject var viewModel: ScanViewModel

    private static let otherHostSentinel = "_other_"
    /// The device picker's last item. Also how the picker's pop-up is told apart
    /// from the other pop-ups in the form when one is about to open.
    private static let otherHostTitle = "Other…"

    @State private var isManagingDevices = false

    @AppStorage("resolution") private var resolution: String = Resolution.dpi300.rawValue
    @AppStorage("colorMode") private var colorMode: String = ColorMode.grayscale.rawValue
    @AppStorage("paperSize") private var paperSize: String = PaperSize.letter.rawValue
    @AppStorage("inputSource") private var inputSource: String = InputSource.flatbed.rawValue
    @AppStorage("leftPanelWidth") private var leftPanelWidth: Double = 260

    private static let leftPanelWidthRange: ClosedRange<Double> = 260...480

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: leftPanelWidth.clamped(to: Self.leftPanelWidthRange))
            PanelDivider(width: $leftPanelWidth, range: Self.leftPanelWidthRange)
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "Scanner Error",
            isPresented: Binding(
                get: { viewModel.alertError != nil },
                set: { if !$0 { viewModel.alertError = nil } }
            ),
            presenting: viewModel.alertError
        ) { _ in
            Button("OK") { viewModel.alertError = nil }
        } message: { error in
            Text(error.errorDescription ?? error.localizedDescription)
        }
        .onAppear {
            syncSettings()
        }
        // Discovery is on demand: probe when the user opens the device picker.
        .onReceive(NotificationCenter.default.publisher(for: NSPopUpButton.willPopUpNotification)) { note in
            guard let popUp = note.object as? NSPopUpButton,
                  popUp.itemTitles.contains(Self.otherHostTitle) else { return }
            viewModel.startDiscovery()
        }
        // Files may have appeared or gone while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshDestinationPlan()
        }
        .sheet(isPresented: $isManagingDevices) {
            ManageDevicesSheet(viewModel: viewModel)
        }
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            settingsForm
            Divider()
            buttonBar
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                scannerPickerRow
                if viewModel.selectedTarget == nil {
                    manualHostRow
                }
                Button("Manage Devices…") { isManagingDevices = true }
            } header: {
                HStack(spacing: 6) {
                    Text("Scanner")
                    if viewModel.isDiscovering {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                }
            }

            Section("Scan Settings") {
                Picker("Resolution", selection: $resolution) {
                    ForEach(Resolution.allCases, id: \.rawValue) { r in
                        Text(r.displayName).tag(r.rawValue)
                    }
                }
                .onChange(of: resolution) {
                    viewModel.resolution = Resolution(rawValue: $0) ?? .dpi300
                }

                Picker("Color Mode", selection: $colorMode) {
                    ForEach(ColorMode.allCases, id: \.rawValue) { c in
                        Text(c.displayName).tag(c.rawValue)
                    }
                }
                .onChange(of: colorMode) {
                    viewModel.colorMode = ColorMode(rawValue: $0) ?? .grayscale
                }

                Picker("Paper Size", selection: $paperSize) {
                    ForEach(PaperSize.allCases, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .onChange(of: paperSize) {
                    viewModel.paperSize = PaperSize(rawValue: $0) ?? .letter
                }

                Picker("Source", selection: $inputSource) {
                    ForEach(InputSource.allCases, id: \.rawValue) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                }
                .onChange(of: inputSource) {
                    viewModel.inputSource = InputSource(rawValue: $0) ?? .flatbed
                }
            }

            destinationSection
        }
        .formStyle(.grouped)
        .disabled(viewModel.isScanning || viewModel.isOverviewing)
    }

    // MARK: - Destination

    private var destinationSection: some View {
        Section("Destination") {
            TextField("Name", text: $viewModel.destinationName)

            // An ADF ScanJob is always written as PDF, so there is nothing to pick.
            Picker("Format", selection: fileTypeBinding) {
                ForEach(FileType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .disabled(viewModel.isFileTypeForced)

            // Only a PDF can be added to, so the checkbox is not shown otherwise.
            if viewModel.canAppendToExistingPDF {
                Toggle("Add to existing PDF", isOn: $viewModel.appendToExistingPDF)
                    .toggleStyle(.checkbox)
            }

            LabeledContent("Folder") {
                HStack(spacing: 6) {
                    Text(viewModel.destinationFolder?.lastPathComponent ?? "None")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(viewModel.destinationFolder == nil ? .secondary : .primary)
                        .help(viewModel.destinationFolder?.path ?? "No folder chosen")
                    Button("Choose…") { chooseDestinationFolder() }
                }
            }

            Text(viewModel.destinationCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fileTypeBinding: Binding<FileType> {
        Binding(
            get: { viewModel.fileType },
            set: { if !viewModel.isFileTypeForced { viewModel.platenFileType = $0 } }
        )
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = viewModel.destinationFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.destinationFolder = url
    }

    // MARK: - Scanner picker row

    private var scannerPickerRow: some View {
        Picker("Device", selection: pickerHostBinding) {
            // A host that is already saved is listed once, under Saved.
            if !viewModel.unsavedDiscoveredTargets.isEmpty {
                Section("Discovered") {
                    ForEach(viewModel.unsavedDiscoveredTargets) { target in
                        Text(target.displayName ?? target.host).tag(target.host)
                    }
                }
            }
            if !viewModel.savedTargets.isEmpty {
                Section("Saved") {
                    ForEach(viewModel.savedTargets) { target in
                        Text(target.displayName ?? target.host).tag(target.host)
                    }
                }
            }
            Text(Self.otherHostTitle).tag(Self.otherHostSentinel)
        }
    }

    private var pickerHostBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedTarget?.host ?? Self.otherHostSentinel },
            set: { host in
                viewModel.selectTarget(byHost: host == Self.otherHostSentinel ? nil : host)
            }
        )
    }

    // MARK: - Manual host text field

    private var manualHostRow: some View {
        LabeledContent("Address") {
            TextField("IP address or hostname", text: $viewModel.manualHost)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Button bar

    private var buttonBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            // Both stay available after a scan, so the next page is one click.
            Button("Overview") { startOverview() }
                .buttonStyle(.bordered)
                .disabled(overviewDisabled)
            Button("Scan") { startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(scanDisabled)
            if viewModel.isScanning {
                Button("Cancel") { viewModel.cancelScan() }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var overviewDisabled: Bool {
        viewModel.isScanning || viewModel.isOverviewing
            || (InputSource(rawValue: inputSource) ?? .flatbed) == .adf
            || viewModel.activeHost == nil
    }

    private var scanDisabled: Bool {
        !viewModel.canScan
    }

    // MARK: - Right panel

    @ViewBuilder
    private var rightPanel: some View {
        if viewModel.isScanning {
            scanProgressPanel
        } else if viewModel.isScanComplete {
            scanResultPanel
        } else if viewModel.isOverviewing {
            overviewProgressPanel
        } else if let data = viewModel.overviewImage {
            overviewResultPanel(data: data)
        } else {
            emptyInstructionPanel
        }
    }

    private var emptyInstructionPanel: some View {
        VStack(spacing: 8) {
            Image(systemName: "scanner")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Press Overview, then drag a box around the area to scan.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var overviewProgressPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Scanning overview…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func overviewResultPanel(data: Data) -> some View {
        Group {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(SelectionOverlayView(region: $viewModel.selectedRegion))
                    .padding(16)
            } else {
                emptyInstructionPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanProgressPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanResultPanel: some View {
        VStack(spacing: 0) {
            if let first = viewModel.previewPages.first,
               let nsImage = NSImage(data: first) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 4)
                        .padding(16)

                    if viewModel.previewPages.count > 1 {
                        Text("\(viewModel.previewPages.count) pages")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            saveStatusRow
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What became of the ScanResult: where it was written, or why it was not.
    @ViewBuilder
    private var saveStatusRow: some View {
        switch viewModel.saveStatus {
        case .saved, .appended:
            Label(viewModel.statusMessage, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed:
            HStack(spacing: 10) {
                Label(viewModel.statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Save") { viewModel.retrySave() }
                    .disabled(viewModel.isScanning || viewModel.isOverviewing)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func startScan() {
        syncSettings()
        viewModel.startScan()
    }

    private func startOverview() {
        syncSettings()
        viewModel.startOverview()
    }

    private func syncSettings() {
        viewModel.resolution = Resolution(rawValue: resolution) ?? .dpi300
        viewModel.colorMode = ColorMode(rawValue: colorMode) ?? .grayscale
        viewModel.paperSize = PaperSize(rawValue: paperSize) ?? .letter
        viewModel.inputSource = InputSource(rawValue: inputSource) ?? .flatbed
    }
}

/// A vertical divider that resizes the panel to its left when dragged.
/// The visible line stays hairline-thin; the hit area is wider so it is easy to grab.
private struct PanelDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var dragStartWidth: Double?
    @State private var isCursorPushed = false
    @State private var isHovering = false

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            pushCursor()
                        } else if dragStartWidth == nil {
                            popCursor()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? width.clamped(to: range)
                                dragStartWidth = start
                                width = (start + value.translation.width).clamped(to: range)
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                if !isHovering { popCursor() }
                            }
                    )
            )
            .onDisappear { popCursor() }
    }

    private func pushCursor() {
        guard !isCursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        isCursorPushed = true
    }

    private func popCursor() {
        guard isCursorPushed else { return }
        NSCursor.pop()
        isCursorPushed = false
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
