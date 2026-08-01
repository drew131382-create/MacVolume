import AppKit
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var manager: AudioProcessManager
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 10) {
            masterSection
            Divider()
            appList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Master

    private var masterSection: some View {
        VStack(spacing: 6) {
            HStack {
                Label("主音量", systemImage: "speaker.wave.3.fill")
                    .font(.headline)
                Spacer()
                Button {
                    manager.toggleMasterMute()
                } label: {
                    Image(systemName: manager.masterMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(manager.masterMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(manager.masterMuted ? "取消静音" : "全部静音")
            }
            HStack {
                Slider(value: masterVolumeBinding, in: 0...1.0)
                Text("\(Int(manager.masterVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var masterVolumeBinding: Binding<Float> {
        Binding(
            get: { manager.masterVolume },
            set: { manager.setMasterVolume($0) }
        )
    }

    // MARK: - App List

    private var appList: some View {
        Group {
            if manager.visibleApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("暂无可调节的应用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("播放声音的应用会自动出现在这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(manager.visibleApps.enumerated()), id: \.element.id) { index, app in
                            AppRow(app: app) { newVolume in
                                manager.setVolume(for: app, volume: newVolume)
                            } onToggleMute: {
                                manager.toggleMute(for: app)
                            } onResetVolume: {
                                manager.resetVolume(for: app)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle(isOn: $launchAtLogin) {
                Text("开机自启动")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: launchAtLogin) { _, newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }

            Spacer()

            Button("退出") {
                NSApp.terminate(nil)
            }
            .font(.caption)
        }
    }
}

// MARK: - App Row

struct AppRow: View {
    let app: AudioApp
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onResetVolume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        onToggleMute()
                    } label: {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(app.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(app.isMuted ? "取消静音" : "静音")
                }

                HStack(spacing: 6) {
                    ResetSlider(
                        value: volumeBinding,
                        range: 0...2.0,
                        onVolumeChange: { onVolumeChange($0) },
                        onDoubleClick: { onResetVolume() }
                    )
                    Text("\(Int(app.volume * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { app.volume },
            set: { onVolumeChange($0) }
        )
    }
}

// MARK: - 支持双击复位的滑块

/// 封装 NSSlider：拖动调音量，双击将音量复位为 100%
struct ResetSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let onVolumeChange: (Float) -> Void
    let onDoubleClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = ResetSliderView()
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderChanged(_:))
        slider.doubleValue = Double(value)
        slider.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.didDoubleClick()
        }
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(Float(nsView.doubleValue) - value) > 0.001 {
            nsView.doubleValue = Double(value)
        }
    }

    final class Coordinator: NSObject {
        var parent: ResetSlider

        init(_ parent: ResetSlider) {
            self.parent = parent
        }

        @objc func sliderChanged(_ sender: NSSlider) {
            parent.onVolumeChange(Float(sender.doubleValue))
        }

        func didDoubleClick() {
            parent.onDoubleClick()
        }
    }
}

/// 检测双击的 NSSlider：双击时触发复位回调，不再移动滑块
final class ResetSliderView: NSSlider {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
