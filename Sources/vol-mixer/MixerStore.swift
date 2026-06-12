import Foundation
import AppKit
import CoreAudio
import Observation

@Observable
@MainActor
final class MixerStore {
    /// Processes shown in the UI: audio-producing plus anything with an active mixer.
    var processes: [AudioProcessInfo] = []
    /// Requested gain per PID. Absent ⇒ unity (1.0), no mixer created yet.
    /// Preserved across mute toggles — the slider position is remembered.
    var gains: [pid_t: Float] = [:]
    /// PIDs currently muted. Effective output is 0, slider keeps the prior gain.
    var muted: Set<pid_t> = []
    /// Last error per PID (e.g. TCC denial on first tap).
    var errors: [pid_t: String] = [:]

    /// All output devices currently visible to Core Audio (excluding our own
    /// private aggregates).
    var outputDevices: [AudioOutputDevice] = []
    /// The AudioObjectID of the system default output device.
    var currentOutputDeviceID: AudioObjectID = 0

    private var mixers: [pid_t: VolumeMixer] = [:]
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var refreshTimer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func beginRefreshing() {
        refresh()
        refreshOutputDevices()
        startListeningForDefaultOutputChanges()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshOutputDevices()
            }
        }
    }

    func refreshOutputDevices() {
        if let list = try? OutputDeviceList.all() {
            if list != outputDevices { outputDevices = list }
        }
        if let id = try? OutputDeviceList.currentDefaultID(),
           id != currentOutputDeviceID {
            currentOutputDeviceID = id
        }
    }

    /// Change the system default output. If there are any active mixers, tear
    /// them down and re-create them against the new output — without this
    /// they would keep writing to the previous device (silence for the user).
    func setOutputDevice(_ id: AudioObjectID) {
        do {
            try OutputDeviceList.setDefault(id)
            NSLog("vol-mixer: set default output to %u", id)
        } catch {
            NSLog("vol-mixer: setOutputDevice failed: %@", "\(error)")
            return
        }
        currentOutputDeviceID = id
        rebuildActiveMixers()
    }

    private func rebuildActiveMixers() {
        let activePIDs = Array(mixers.keys)
        guard !activePIDs.isEmpty else { return }
        NSLog("vol-mixer: rebuilding %d mixer(s) for new output", activePIDs.count)
        for pid in activePIDs {
            mixers[pid]?.stop()
            mixers.removeValue(forKey: pid)
            // Recreate even at unity gain: this PID was actively tapped, so keep
            // routing it through the new device (applyEffective would skip 1.0).
            let m = VolumeMixer(targetPID: pid, gain: effectiveGain(pid: pid))
            do { try m.start(); mixers[pid] = m }
            catch { errors[pid] = describe(error) }
        }
    }

    private func startListeningForDefaultOutputChanges() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.currentOutputDeviceID
                self.refreshOutputDevices()
                if self.currentOutputDeviceID != previous {
                    NSLog("vol-mixer: system default output changed externally")
                    self.rebuildActiveMixers()
                }
            }
        }
        defaultOutputListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, nil, block)
        if status != noErr {
            NSLog("vol-mixer: could not listen for default output changes: OSStatus %d", status)
        }
    }

    private func stopListeningForDefaultOutputChanges() {
        guard let block = defaultOutputListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
        defaultOutputListener = nil
    }

    func refresh() {
        pruneDeadProcesses()
        do {
            let all = try AudioProcessList.all()
            let visible = all
                .filter { $0.pid != self.ownPID }
                .filter { $0.isRunning || self.mixers[$0.pid] != nil }
            // Resolve each display name once (NSRunningApplication lookups aren't
            // free) rather than re-resolving inside every sort comparison.
            let named = visible.map { (info: $0, name: $0.displayName) }
            processes = named.sorted { a, b in
                // Active mixers first, then currently playing, then by name.
                let aMixing = mixers[a.info.pid] != nil
                let bMixing = mixers[b.info.pid] != nil
                if aMixing != bMixing { return aMixing }
                if a.info.isRunning != b.info.isRunning { return a.info.isRunning }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }.map { $0.info }
        } catch {
            // Swallow — leave the previous list on screen.
        }
    }

    // PIDs are recycled by macOS, so drop state for processes that have exited
    // before a new process can inherit an old volume/mute (and stop its tap).
    private func pruneDeadProcesses() {
        let tracked = Set(mixers.keys)
            .union(gains.keys).union(muted).union(errors.keys)
        for pid in tracked where !Self.processAlive(pid) {
            mixers[pid]?.stop()
            mixers.removeValue(forKey: pid)
            gains.removeValue(forKey: pid)
            muted.remove(pid)
            errors.removeValue(forKey: pid)
        }
    }

    private static func processAlive(_ pid: pid_t) -> Bool {
        // kill(pid, 0) probes existence without delivering a signal.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM   // exists but owned by another user
    }

    func setGain(pid: pid_t, gain: Float) {
        gains[pid] = max(0, gain)
        applyEffective(pid: pid)
    }

    func toggleMute(pid: pid_t) {
        if muted.contains(pid) {
            muted.remove(pid)
        } else {
            muted.insert(pid)
        }
        applyEffective(pid: pid)
    }

    func reset(pid: pid_t) {
        mixers[pid]?.stop()
        mixers.removeValue(forKey: pid)
        gains[pid] = 1.0
        muted.remove(pid)
        errors[pid] = nil
    }

    /// Tear down every active mixer, regardless of whether the corresponding
    /// process is still in the visible `processes` list.
    func releaseAll() {
        let activePIDs = Array(mixers.keys)
        NSLog("vol-mixer: releaseAll tearing down %d mixer(s): %@",
              activePIDs.count,
              activePIDs.map(String.init).joined(separator: ","))
        for (_, m) in mixers { m.stop() }
        mixers = [:]
        // Reassign rather than mutate so @Observable sees a single write per
        // property — avoids any chance of missed notifications through
        // in-place collection mutation.
        gains = [:]
        muted = []
        errors = [:]
    }

    func isActive(pid: pid_t) -> Bool { mixers[pid] != nil }
    func isMuted(pid: pid_t) -> Bool { muted.contains(pid) }
    var hasAnyActive: Bool {
        !mixers.isEmpty || !muted.isEmpty || gains.contains { $0.value != 1.0 }
    }
    func effectiveGain(pid: pid_t) -> Float {
        muted.contains(pid) ? 0 : Self.gainCurve(gains[pid] ?? 1.0)
    }

    /// Maps slider position (0…1.5) to a gain multiplier with an exponential
    /// taper, so equal slider moves feel like equal loudness steps.
    private static func gainCurve(_ position: Float) -> Float {
        let p = max(0, position)
        if p >= 1.0 { return p }   // boost is linear, so 150% on the slider is 1.5×
        // 40 dB taper, unity at 1.0; fade to silence across the bottom tenth.
        let curve = expf(4.605 * p) / 100.0
        return p < 0.1 ? curve * (p / 0.1) : curve
    }

    /// Pushes the effective gain (0 if muted, else slider value) to the mixer,
    /// creating one lazily if the state now differs from unity pass-through.
    private func applyEffective(pid: pid_t) {
        errors[pid] = nil
        let effective = effectiveGain(pid: pid)

        if let m = mixers[pid] {
            m.setGain(effective)
            return
        }
        // No mixer yet — only spin one up if we actually need to change output.
        guard effective != 1.0 else { return }

        let m = VolumeMixer(targetPID: pid, gain: effective)
        do {
            try m.start()
            mixers[pid] = m
        } catch {
            errors[pid] = describe(error)
            gains[pid] = 1.0
            muted.remove(pid)
        }
    }

    func stopAll() {
        for (_, m) in mixers { m.stop() }
        mixers.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopListeningForDefaultOutputChanges()
    }

    private func describe(_ error: Error) -> String {
        if let ca = error as? CAError {
            // Known TCC failure codes — surface something actionable.
            switch ca.status {
            case 1852797029:           // 'nope' — permission denied
                return "permission denied — grant Audio Capture in System Settings"
            case -4, 560947567:        // '!aut', generic perms
                return "not authorised — see README for codesigning + TCC grant"
            default:
                return ca.description
            }
        }
        return "\(error)"
    }
}

extension AudioProcessInfo {
    var displayName: String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let n = app.localizedName, !n.isEmpty {
            return n
        }
        if let b = bundleID { return b }
        if let e = executable { return e }
        return "pid \(pid)"
    }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}
