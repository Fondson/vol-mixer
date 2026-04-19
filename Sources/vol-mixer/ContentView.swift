import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            outputPicker
            Divider()
            if store.processes.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.processes, id: \.pid) { p in
                            ProcessRow(process: p)
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // Width is pinned by the popover; let the popover decide the height.
        .frame(minWidth: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Text("Per-app volume")
                .font(.headline)
            Spacer()
            Button {
                store.releaseAll()
            } label: {
                Label("Reset all", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .disabled(!store.hasAnyActive)
            .help("Release every tap and restore all sliders to 100%")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var outputPicker: some View {
        let current = store.outputDevices.first { $0.id == store.currentOutputDeviceID }
        return HStack(spacing: 10) {
            Image(systemName: current?.sfSymbol ?? "hifispeaker")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Output")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(store.outputDevices) { d in
                    Button {
                        store.setOutputDevice(d.id)
                    } label: {
                        if d.id == store.currentOutputDeviceID {
                            Label(d.name, systemImage: "checkmark")
                        } else {
                            Text(d.name)
                        }
                    }
                }
            } label: {
                Text(current?.name ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No audio-producing processes")
                .foregroundStyle(.secondary)
            Text("Play something — the list refreshes automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ProcessRow: View {
    let process: AudioProcessInfo
    @Environment(MixerStore.self) private var store

    private var gainValue: Float {
        store.gains[process.pid] ?? 1.0
    }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(process.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 10) {
                    percentLabel
                    muteButton
                    resetButton
                }

                if let e = store.errors[process.pid] {
                    Text(e)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(width: 180, alignment: .leading)

            slider
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var muteButton: some View {
        Button {
            store.toggleMute(pid: process.pid)
        } label: {
            Image(systemName: store.isMuted(pid: process.pid)
                  ? "speaker.slash.fill"
                  : "speaker.fill")
            .foregroundStyle(store.isMuted(pid: process.pid) ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(store.isMuted(pid: process.pid) ? "Unmute" : "Mute")
    }

    @ViewBuilder
    private var percentLabel: some View {
        Group {
            if store.isMuted(pid: process.pid) {
                Text("muted").foregroundStyle(.red)
            } else {
                Text(String(format: "%.0f%%", gainValue * 100))
                    .foregroundStyle(gainValue == 1.0 ? .secondary : .primary)
            }
        }
        .font(.system(.caption, design: .monospaced))
        // Fixed width so swapping between "100%" / "muted" doesn't shift
        // the mute and reset buttons that follow.
        .frame(width: 44, alignment: .leading)
    }

    private var resetButton: some View {
        Button {
            store.reset(pid: process.pid)
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!store.isActive(pid: process.pid)
                  && gainValue == 1.0
                  && !store.isMuted(pid: process.pid))
        .help("Reset to 100% and release the tap")
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = process.icon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var slider: some View {
        let binding = Binding<Double>(
            get: { Double(gainValue) },
            set: { store.setGain(pid: process.pid, gain: Float($0)) }
        )
        return Slider(value: binding, in: 0...1.5) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
