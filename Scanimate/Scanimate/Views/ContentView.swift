import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        ScanPanelView(viewModel: viewModel)
            .frame(minWidth: 480, minHeight: 520)
    }
}
