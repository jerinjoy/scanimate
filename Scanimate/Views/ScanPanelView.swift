import SwiftUI

struct ScanPanelView: View {
    @ObservedObject var viewModel: ScanViewModel

    private static let otherHostSentinel = "_other_"

    @AppStorage("resolution") private var resolution: String = Resolution.dpi300.rawValue
    @AppStorage("colorMode") private var colorMode: String = ColorMode.grayscale.rawValue
    @AppStorage("paperSize") private var paperSize: String = PaperSize.letter.rawValue
    @AppStorage("inputSource") private var inputSource: String = InputSource.flatbed.rawValue

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 260)
            Divider()
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
            viewModel.startDiscovery()
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
        }
        .formStyle(.grouped)
        .disabled(viewModel.isScanning || viewModel.isOverviewing)
    }

    // MARK: - Scanner picker row

    private var scannerPickerRow: some View {
        Picker("Device", selection: pickerHostBinding) {
            if !viewModel.discoveredTargets.isEmpty {
                Section("Discovered") {
                    ForEach(viewModel.discoveredTargets) { target in
                        Text(target.displayName ?? target.host).tag(target.host)
                    }
                }
            }
            if !viewModel.savedTargets.isEmpty {
                Section("Saved") {
                    ForEach(viewModel.savedTargets) { target in
                        Text(target.host).tag(target.host)
                    }
                }
            }
            Text("Other…").tag(Self.otherHostSentinel)
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
            if viewModel.isScanComplete {
                Button("Save…") { viewModel.save() }
                    .buttonStyle(.borderedProminent)
                Button("Scan Again") { viewModel.resetForNextScan() }
                    .buttonStyle(.bordered)
            } else {
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
            }
        }
        .padding(12)
    }

    private var overviewDisabled: Bool {
        viewModel.isScanning || viewModel.isOverviewing
            || (InputSource(rawValue: inputSource) ?? .flatbed) == .adf
            || viewModel.activeHost == nil
    }

    private var scanDisabled: Bool {
        viewModel.isScanning || viewModel.isOverviewing
            || viewModel.activeHost == nil
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
            Text("Press Overview to preview the scanner bed.")
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

    @ViewBuilder
    private var scanResultPanel: some View {
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
