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
                ForEach(viewModel.savedTargets) { target in
                    HStack {
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
                        Spacer()
                        Button {
                            viewModel.removeSavedTarget(target)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 280)
    }
}
