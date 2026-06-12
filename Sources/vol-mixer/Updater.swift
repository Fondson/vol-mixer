import AppKit
import CryptoKit
import Foundation

/// In-app updater. Checks GitHub Releases for a newer build, verifies the
/// download against an embedded Ed25519 public key, then swaps the bundle and
/// relaunches. The signature check is the security boundary: even a compromised
/// release can't push code, because it can't forge the signature.
@MainActor
final class Updater {
    static let shared = Updater()

    private let repo = "Fondson/vol-mixer"
    private let zipName = "Volume.Mixer.app.zip"
    private let bundleName = "Volume Mixer.app"

    // Base64 of the 32-byte Ed25519 public key that release signatures are
    // checked against. Generate a keypair, keep the private half as a CI secret,
    // and paste the public half here. Until it's a real key, updates are off.
    private let publicKeyBase64 = "SsH/IbtTpxOrdgyrtoVU50aEi/my/VlD9mpT0pQ1Q1g="

    private let autoKey = "vol-mixer.autoCheckUpdates"
    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    private var checking = false
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // Only self-update an installed copy; never overwrite a dev build run in place.
    private var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    private var signingKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    /// An initial background check plus a daily one — menu-bar apps run for days.
    func startAutomaticChecks() {
        guard autoCheckEnabled, signingKey != nil else { return }
        guard isInstalled else {
            NSLog("vol-mixer: auto-update off — running from %@ (move to /Applications)",
                  Bundle.main.bundlePath)
            return
        }
        Task { await self.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheckEnabled else { return }
                await self.check(userInitiated: false)
            }
        }
    }

    @objc func checkNow() { Task { await self.check(userInitiated: true) } }

    func check(userInitiated: Bool) async {
        guard !checking else { return }
        guard let key = signingKey else {
            if userInitiated { alert("Updates not configured", "This build has no update signing key.") }
            return
        }
        guard isInstalled else {
            let path = Bundle.main.bundlePath
            NSLog("vol-mixer: not updating — running from %@", path)
            if userInitiated {
                alert("Can't update this copy",
                      "Volume Mixer is running from:\n\(path)\n\nMove it into your Applications folder to enable updates.")
            }
            return
        }
        checking = true
        defer { checking = false }
        do {
            guard let release = try await latestRelease(),
                  isNewer(release.version, than: Self.currentVersion) else {
                if userInitiated { alert("You're up to date", "Volume Mixer \(Self.currentVersion) is the latest version.") }
                return
            }
            guard confirmInstall(version: release.version) else { return }

            let zip = try await downloadToFile(release.zipURL)
            let signature = try await downloadData(release.sigURL)
            guard key.isValidSignature(signature, for: try Data(contentsOf: zip)) else {
                throw UpdaterError.signatureMismatch
            }
            let newApp = try unpackAndClear(zip: zip)
            relaunch(replacing: Bundle.main.bundlePath, with: newApp.path)
        } catch {
            NSLog("vol-mixer: update failed: %@", "\(error)")
            if userInitiated { alert("Update failed", error.localizedDescription) }
        }
    }

    // MARK: - GitHub release lookup

    private struct Release { let version: String; let zipURL: URL; let sigURL: URL }
    private struct GHRelease: Decodable {
        let tag_name: String
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let assets: [Asset]
    }

    private func latestRelease() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdaterError.network }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        guard let zip = gh.assets.first(where: { $0.name == zipName })?.browser_download_url,
              let sig = gh.assets.first(where: { $0.name == zipName + ".sig" })?.browser_download_url,
              let zipURL = URL(string: zip), let sigURL = URL(string: sig)
        else { return nil }
        return Release(version: version, zipURL: zipURL, sigURL: sigURL)
    }

    private func downloadToFile(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdaterError.network }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func downloadData(_ url: URL) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdaterError.network }
        return data
    }

    // MARK: - Install

    private func unpackAndClear(zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent(bundleName)
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdaterError.badBundle }
        try runTool("/usr/bin/xattr", ["-cr", app.path])   // clear quarantine like install.sh
        return app
    }

    private func relaunch(replacing dest: String, with newApp: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // A detached helper waits for us to exit, then swaps the bundle. It keeps
        // the old copy aside until the new one is in place and restores it on
        // failure, so a permission error can't leave no app installed.
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "\(dest).old"
        if /bin/mv "\(dest)" "\(dest).old"; then
            if /bin/mv "\(newApp)" "\(dest)"; then
                /bin/rm -rf "\(dest).old"
            else
                /bin/mv "\(dest).old" "\(dest)"
            fi
        fi
        /usr/bin/xattr -cr "\(dest)"
        /usr/bin/open "\(dest)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-relaunch-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("vol-mixer: relaunch failed: %@", "\(error)")
            alert("Update failed", "Couldn't install the update.")
        }
    }

    private func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdaterError.toolFailed(path) }
    }

    // MARK: - Helpers

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
        }
        return false
    }

    private func confirmInstall(version: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Update available"
        a.informativeText = "Volume Mixer \(version) is available (you have \(Self.currentVersion)). Install and relaunch now?"
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Later")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

enum UpdaterError: LocalizedError {
    case network, signatureMismatch, badBundle, toolFailed(String)
    var errorDescription: String? {
        switch self {
        case .network: return "Couldn't reach the update server."
        case .signatureMismatch: return "The update's signature didn't match, so it was not installed."
        case .badBundle: return "The downloaded update was malformed."
        case .toolFailed(let t): return "An update step failed (\(t))."
        }
    }
}
