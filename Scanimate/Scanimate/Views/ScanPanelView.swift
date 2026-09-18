import SwiftUI

struct ScanPanelView: View {
    @ObservedObject var viewModel: ScanViewModel

    @AppStorage("ipAddress") private var ipAddress: String = ""
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
        .onAppear { syncSettings() }
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
            Section("Scanner") {
                LabeledContent("IP Address") {
                    TextField("e.g. 192.168.1.66", text: $ipAddress)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: ipAddress) { viewModel.ipAddress = $0 }
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
            || ipAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var scanDisabled: Bool {
        viewModel.isScanning || viewModel.isOverviewing
            || ipAddress.trimmingCharacters(in: .whitespaces).isEmpty
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
        viewModel.ipAddress = ipAddress
        viewModel.resolution = Resolution(rawValue: resolution) ?? .dpi300
        viewModel.colorMode = ColorMode(rawValue: colorMode) ?? .grayscale
        viewModel.paperSize = PaperSize(rawValue: paperSize) ?? .letter
        viewModel.inputSource = InputSource(rawValue: inputSource) ?? .flatbed
    }
}
