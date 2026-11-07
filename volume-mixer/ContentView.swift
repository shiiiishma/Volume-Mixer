import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var viewModel: MixerViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            searchBar
            
            Divider()
                .padding(.top, 4)
            
            if viewModel.filteredApps.isEmpty {
                emptyStateView
            } else {
                appListView
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 400)
        .padding(.vertical, 8)
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(systemName: "slider.horizontal.2.square")
                .font(.title2)
                .foregroundStyle(.tint)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Volume Mixer")
                    .font(.headline)
                
                let activeCount = viewModel.apps.filter { $0.isRunningOutput }.count
                let tappedCount = viewModel.apps.filter { $0.isTapped }.count
                Text("\(activeCount) active • \(tappedCount) tapped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Mute All Toggle Button
            Button {
                viewModel.toggleMuteAll()
            } label: {
                Image(systemName: viewModel.isMuteAll ? "speaker.slash.fill" : "speaker.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.isMuteAll ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isMuteAll ? "Unmute All Apps" : "Mute All Apps")
            
            // Reset All Button
            Button {
                viewModel.resetAllApps()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reset all apps to 100% volume and default output")
            
            // Refresh Button
            Button {
                viewModel.refreshApps()
                viewModel.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh applications and audio devices")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField("Search applications...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
    
    // MARK: - App List
    private var appListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.filteredApps) { app in
                    AppRowView(app: app, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 440)
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.searchQuery.isEmpty ? "speaker.slash" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            
            Text(viewModel.searchQuery.isEmpty ? "No active audio apps" : "No matching applications")
                .font(.headline)
            
            Text(viewModel.searchQuery.isEmpty ?
                 "Launch an app like Music, Safari, or Chrome to control its volume." :
                 "Try searching for another app name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(height: 180)
    }
    
    // MARK: - Footer
    private var footerView: some View {
        HStack {
            let defaultName = viewModel.devices.first(where: { $0.uid == viewModel.defaultDeviceUID })?.name ?? "System Output"
            Label(defaultName, systemImage: "speaker.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - App Row View
struct AppRowView: View {
    let app: AudioAppItem
    let viewModel: MixerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                appIcon
                    .frame(width: 24, height: 24)
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        
                        if app.isRunningOutput {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .help("Currently playing audio")
                        }
                        
                        if app.isTapped {
                            Text("TAP")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.2))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .help("On-demand Process Tap active")
                        }
                        
                        if !app.childObjectIDs.isEmpty {
                            Text("+\(app.childObjectIDs.count) helpers")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .help("Combined child audio workers (Chrome/WebKit/GPU)")
                        }
                    }
                    
                    Text("PID: \(app.pid)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if app.isDRMProtected {
                    Text("DRM Protected")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                        .help("FairPlay DRM active: hardware direct playback enabled to avoid silence")
                }
                
                Button {
                    viewModel.toggleMute(for: app.audioObjectID)
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : (app.volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
                        .foregroundStyle(app.isMuted ? .red : .primary)
                }
                .buttonStyle(.plain)
                
                if app.isTapped {
                    Button {
                        viewModel.resetApp(for: app.audioObjectID)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to 100% and system output (releases tap)")
                }
            }
            
            // Volume Slider & Percentage
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(app.volume) },
                        set: { viewModel.setVolume(for: app.audioObjectID, volume: Float($0)) }
                    ),
                    in: 0.0...1.0
                )
                .disabled(app.isMuted)
                
                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
                    .foregroundStyle(app.isMuted ? .secondary : .primary)
            }
            
            // Peak VU Level Meter
            AudioLevelMeterView(level: app.peakLevel)
            
            // Output Device Selector
            HStack {
                Text("Output:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                
                Picker("", selection: Binding(
                    get: { app.selectedDeviceUID ?? "" },
                    set: { viewModel.setOutputDevice(for: app.audioObjectID, deviceUID: $0.isEmpty ? nil : $0) }
                )) {
                    Text("System Default").tag("")
                    ForEach(viewModel.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                
                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    @ViewBuilder
    private var appIcon: some View {
        if let runningApp = NSRunningApplication(processIdentifier: app.pid),
           let icon = runningApp.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Audio Level Meter View
struct AudioLevelMeterView: View {
    let level: Float // 0.0 to 1.0
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .green, location: 0.0),
                                .init(color: .green, location: 0.65),
                                .init(color: .yellow, location: 0.85),
                                .init(color: .red, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 3)
    }
}
