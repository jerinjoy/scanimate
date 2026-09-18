import SwiftUI

struct ScanPanelView: View {
    @ObservedObject var viewModel: ScanViewModel

    @AppStorage("ipAddress") private var ipAddress: String = ""
    @AppStorage("resolution") private var resolution: String = Resolution.dpi300.rawValue
    @AppStorage("colorMode") private var colorMode: String = ColorMode.grayscale.rawValue
    @AppStorage("paperSize") private var paperSize: String = PaperSize.letter.rawValue
    @AppStorage("inputSource") private var inputSource: String = InputSource.flatbed.rawValue

    var body: some View {
        VStack(spacing: 0) {
            settingsSection
            Divider()
            actionSection
        }
        .alert(
            "Scan Error",
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

    // MARK: - Settings section

    private var settingsSection: some View {
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
        .disabled(viewModel.isScanning)
    }

    // MARK: - Action section

    private var actionSection: some View {
        VStack(spacing: 16) {
            if viewModel.isScanning {
                progressArea
            } else if viewModel.isScanComplete {
                previewArea
            } else {
                Spacer().frame(height: 20)
            }
            buttonRow
        }
        .padding()
    }

    private var progressArea: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private var previewArea: some View {
        if let first = viewModel.previewPages.first,
           let nsImage = NSImage(data: first) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 4)

                if viewModel.previewPages.count > 1 {
                    Text("\(viewModel.previewPages.count) pages")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 12) {
            if viewModel.isScanComplete {
                Button("Save…") { viewModel.save() }
                    .buttonStyle(.borderedProminent)
                Button("Scan Again") { viewModel.resetForNextScan() }
                    .buttonStyle(.bordered)
            } else {
                Button("Scan") { startScan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isScanning || ipAddress.trimmingCharacters(in: .whitespaces).isEmpty)

                if viewModel.isScanning {
                    Button("Cancel") { viewModel.cancelScan() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Helpers

    private func startScan() {
        syncSettings()
        viewModel.startScan()
    }

    private func syncSettings() {
        viewModel.ipAddress = ipAddress
        viewModel.resolution = Resolution(rawValue: resolution) ?? .dpi300
        viewModel.colorMode = ColorMode(rawValue: colorMode) ?? .grayscale
        viewModel.paperSize = PaperSize(rawValue: paperSize) ?? .letter
        viewModel.inputSource = InputSource(rawValue: inputSource) ?? .flatbed
    }
}
