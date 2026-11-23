import AppKit
import Foundation

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browser_download_url: String
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [GitHubReleaseAsset]
}

private enum UpdateError: Error, LocalizedError {
    case unzipFailed
    case missingExpectedFiles
    case notAnInstalledAppBundle

    var errorDescription: String? {
        switch self {
        case .unzipFailed: return "Couldn't unpack the update."
        case .missingExpectedFiles: return "Update package is missing expected files."
        case .notAnInstalledAppBundle: return "Not running from an installed .app bundle."
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(progress: Double)
    case installing
    case error(String)
}

/// Checks GitHub Releases for a newer version and, if found, downloads just the
/// two binaries that actually change between releases (the app executable and
/// the HAL plugin driver) rather than the full DMG -- see release.yml's "Create
/// OTA update package" step, which is what publishes the zip this looks for.
///
/// Install is a quit-then-swap: this process can't safely overwrite its own
/// running executable and relaunch itself, so it writes a small helper script
/// that waits for this process to actually exit, replaces the two binaries in
/// place inside the already-installed .app, re-signs (ad-hoc, matching how
/// Scripts/make_app_bundle.sh signs a fresh build), and relaunches -- then
/// this process quits, handing off to that already-running helper.
@available(macOS 14.2, *)
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateState = .idle

    private static let repo = "hashedalgorithm/volume-control"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private var pendingRelease: GitHubRelease?
    private var downloadProgressObservation: NSKeyValueObservation?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        state = .checking
        var request = URLRequest(url: Self.latestReleaseURL)
        // GitHub's API rejects requests with no User-Agent at all.
        request.setValue("VolumeControl-UpdateChecker", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.state = .error("Couldn't check for updates. Check your connection and try again.")
                    return
                }
                let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                if Self.isNewer(latest, than: self.currentVersion) {
                    self.pendingRelease = release
                    self.state = .available(version: latest)
                } else {
                    self.pendingRelease = nil
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// Component-wise numeric comparison (not lexicographic -- "0.1.10" must sort
    /// after "0.1.9", which plain string comparison gets wrong).
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func downloadAndInstall() {
        guard let release = pendingRelease else {
            state = .error("No update to install -- check for updates first.")
            return
        }
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("VolumeControl-update-") && $0.name.hasSuffix(".zip") }),
              let url = URL(string: asset.browser_download_url) else {
            state = .error("Latest release has no update package -- download the DMG from GitHub instead.")
            return
        }

        state = .downloading(progress: 0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL, error == nil else {
                DispatchQueue.main.async { self.state = .error("Download failed. Check your connection and try again.") }
                return
            }
            // The completion handler's tempURL is deleted the moment this closure
            // returns, so it has to be moved to a location this process owns
            // before any further (especially async) work touches it.
            let ownedZip = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeControl-update-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: tempURL, to: ownedZip)
            } catch {
                DispatchQueue.main.async { self.state = .error("Couldn't save the downloaded update.") }
                return
            }
            self.install(fromZip: ownedZip)
        }
        downloadProgressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.state = .downloading(progress: progress.fractionCompleted) }
        }
        task.resume()
    }

    private func install(fromZip zipURL: URL) {
        DispatchQueue.main.async { self.state = .installing }

        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeControl-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zipURL.path, "-d", extractDir.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw UpdateError.unzipFailed
            }

            let newBinary = extractDir.appendingPathComponent("VolumeControl")
            let newDriver = extractDir.appendingPathComponent("VolumeControlMicMix")
            guard FileManager.default.fileExists(atPath: newBinary.path),
                  FileManager.default.fileExists(atPath: newDriver.path) else {
                throw UpdateError.missingExpectedFiles
            }

            let appPath = Bundle.main.bundlePath
            guard appPath.hasSuffix(".app") else {
                throw UpdateError.notAnInstalledAppBundle
            }

            try launchSwapHelper(appPath: appPath, newBinary: newBinary.path, newDriver: newDriver.path, extractDir: extractDir, zipURL: zipURL)

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: extractDir)
            try? FileManager.default.removeItem(at: zipURL)
            DispatchQueue.main.async { self.state = .error("Install failed: \(error.localizedDescription)") }
        }
    }

    /// Writes and launches a detached shell script that does the actual file
    /// swap once this process has fully exited. A spawned process is not killed
    /// when its parent quits (unlike, say, a Windows job object) -- it's simply
    /// reparented to launchd and keeps running, which is what makes this handoff
    /// work at all.
    private func launchSwapHelper(appPath: String, newBinary: String, newDriver: String, extractDir: URL, zipURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("vc-update-swap-\(UUID().uuidString).sh")

        let driverBinaryPath = "\(appPath)/Contents/Resources/VolumeControlMicMix.driver/Contents/MacOS/VolumeControlMicMix"
        let script = """
        #!/bin/bash
        set -e
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        cp -f "\(newBinary)" "\(appPath)/Contents/MacOS/VolumeControl"
        cp -f "\(newDriver)" "\(driverBinaryPath)"
        codesign --force --deep --sign - "\(appPath)" >/dev/null 2>&1 || true
        rm -rf "\(extractDir.path)" "\(zipURL.path)" "$0"
        open "\(appPath)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
    }
}
