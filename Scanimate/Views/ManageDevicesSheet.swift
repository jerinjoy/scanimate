import SwiftUI

struct ManageDevicesSheet: View {
    @ObservedObject var viewModel: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Devices")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            List {
                Section("Saved") {
                    if viewModel.savedTargets.isEmpty {
                        Text("No saved devices")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.savedTargets) { target in
                        HStack {
                            TargetLabel(target: target)
                            Spacer()
                            Button {
                                viewModel.removeSavedTarget(target)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }

                Section {
                    if viewModel.unsavedDiscoveredTargets.isEmpty {
                        Text(viewModel.isDiscovering ? "Searching…" : "No new devices found")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.unsavedDiscoveredTargets) { target in
                        HStack {
                            TargetLabel(target: target)
                            Spacer()
                            Button {
                                viewModel.saveDiscoveredTarget(target)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Add")
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Found on Network")
                        if viewModel.isDiscovering {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Spacer()
                        Button("Search Again") { viewModel.startDiscovery() }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.isDiscovering)
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
        // Discovery is on demand: opening this sheet is a search for devices.
        .onAppear { viewModel.startDiscovery() }
    }
}

private struct TargetLabel: View {
    let target: ScannerTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let displayName = target.displayName, !displayName.isEmpty {
                Text(displayName)
                Text(target.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(target.host)
            }
        }
    }
}
