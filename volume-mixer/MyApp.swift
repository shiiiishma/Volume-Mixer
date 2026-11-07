import SwiftUI

@main
struct MyApp: App {
    @State private var viewModel = MixerViewModel()
    
    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "speaker.wave.2.fill") {
            ContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
