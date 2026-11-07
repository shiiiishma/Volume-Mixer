import SwiftUI

@main
struct MyApp: App {
    @State private var viewModel = MixerViewModel()
    
    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.horizontal.2.square") {
            ContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
