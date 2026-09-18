import Network
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        ScanPanelView(viewModel: viewModel)
            .frame(minWidth: 700, minHeight: 520)
            .onAppear { probeLocalNetwork() }
    }

    private func probeLocalNetwork() {
        // macOS shows the Local Network permission dialog only on first connection attempt.
        // A brief TCP probe to any RFC-1918 address is enough to trigger it before the user
        // presses Scan, so the dialog doesn't interrupt the first real scan.
        let conn = NWConnection(host: "192.168.0.1", port: 9, using: .tcp)
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
    }
}
