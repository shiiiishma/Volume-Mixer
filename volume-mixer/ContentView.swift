import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var viewModel: MixerViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
                .padding(.vertical, 4)
            
            masterVolumeRow
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
            
            Divider()
                .padding(.vertical, 4)
            
            HStack {
                Text("APPLICATIONS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 4)
            
            if viewModel.apps.isEmpty {
                emptyStateView
            } else {
                appListView
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 380)
        .padding(.vertical, 8)
        .onAppear {
            viewModel.refreshDevices()
            viewModel.refreshMasterVolume()
            viewModel.refreshApps()
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            
            Text("Volume Mixer")
                .font(.headline)
            
            Spacer()
            
            // Master Mute All Toggle
            Button {
                viewModel.toggleMuteAll()
            } label: {
                Image(systemName: viewModel.isMuteAll ? "speaker.slash.fill" : "speaker.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.isMuteAll ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isMuteAll ? "Unmute All Apps" : "Mute All Apps")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
    
    // MARK: - Master Volume Single Row
    private var masterVolumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.isMasterMuted ? "speaker.slash.fill" : (viewModel.masterVolume > 0.5 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                .font(.system(size: 13))
                .foregroundStyle(viewModel.isMasterMuted ? .red : .primary)
                .frame(width: 20)
            
            Text("Total")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 90, alignment: .leading)
            
            Slider(
                value: Binding(
                    get: { Double(viewModel.masterVolume) },
                    set: { viewModel.setMasterVolume(Float($0)) }
                ),
                in: 0.0...1.0
            )
            .disabled(viewModel.isMasterMuted)
            
            Text("\(Int(viewModel.masterVolume * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(viewModel.isMasterMuted ? .secondary : .primary)
            
            // Default Device Menu
            Menu {
                ForEach(viewModel.devices) { device in
                    Button {
                        viewModel.setDefaultOutputDevice(uid: device.uid)
                    } label: {
                        HStack {
                            Text(device.name)
                            if device.uid == viewModel.defaultDeviceUID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Output: \(viewModel.devices.first(where: { $0.uid == viewModel.defaultDeviceUID })?.name ?? "Default Output")")
            
            // Total Mute Button
            Button {
                viewModel.toggleMasterMute()
            } label: {
                Image(systemName: viewModel.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.isMasterMuted ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isMasterMuted ? "Unmute Total Volume" : "Mute Total Volume")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // MARK: - App List
    private var appListView: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(viewModel.apps) { app in
                    AppRowView(app: app, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 350)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "app.dashed")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            
            Text("No open applications detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
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
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// MARK: - App Row View (Single Line)
struct AppRowView: View {
    let app: AudioAppItem
    let viewModel: MixerViewModel
    
    var body: some View {
        HStack(spacing: 8) {
            appIcon
                .frame(width: 20, height: 20)
            
            // App Name & Indicators (One column)
            HStack(spacing: 3) {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if app.isRunningOutput {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .help("Currently playing audio")
                }
                
                if app.isTapped {
                    Text("TAP")
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.18))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("On-demand Process Tap active")
                }
                
                if app.isDRMProtected {
                    Text("DRM")
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("FairPlay DRM active: hardware direct playback enabled")
                }
            }
            .frame(width: 90, alignment: .leading)
            
            // Slider with VU Peak Meter right below it
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { Double(app.volume) },
                        set: { viewModel.setVolume(for: app.pid, volume: Float($0)) }
                    ),
                    in: 0.0...1.0
                )
                .disabled(app.isMuted)
                
                AudioLevelMeterView(level: app.peakLevel)
            }
            
            // Percentage
            Text("\(Int(app.volume * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(app.isMuted ? .secondary : .primary)
            
            // Output Device Menu
            Menu {
                Button {
                    viewModel.setOutputDevice(for: app.pid, deviceUID: nil)
                } label: {
                    HStack {
                        Text("System Default")
                        if app.selectedDeviceUID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                
                Divider()
                
                ForEach(viewModel.devices) { device in
                    Button {
                        viewModel.setOutputDevice(for: app.pid, deviceUID: device.uid)
                    } label: {
                        HStack {
                            Text(device.name)
                            if app.selectedDeviceUID == device.uid {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 11))
                    .foregroundStyle(app.selectedDeviceUID == nil ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(app.selectedDeviceUID == nil ? "Output: System Default" : "Output: \(viewModel.devices.first(where: { $0.uid == app.selectedDeviceUID })?.name ?? "")")
            
            // Mute Button
            Button {
                viewModel.toggleMute(for: app.pid)
            } label: {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : (app.volume > 0.5 ? "speaker.wave.2.fill" : "speaker.wave.1.fill"))
                    .font(.system(size: 12))
                    .foregroundStyle(app.isMuted ? .red : .primary)
            }
            .buttonStyle(.plain)
            .help(app.isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .frame(height: 2)
    }
}
