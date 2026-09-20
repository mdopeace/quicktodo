import Foundation
import Combine
import AppKit
import QuickTodoCore

final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var releaseChecksum: String?
    @Published private(set) var errorMessage: String?

    enum State { case idle, checking, available, downloading, installing, error }

    private let repo = "mdopeace/quicktodo"
    private let currentVersion = appVersion
    private var checkTimer: Timer?
    private var downloads: [URL: URLSessionDownloadTask] = [:]
    private var lastManualCheckTime: Date?
    private let manualCheckCooldown: TimeInterval = 10

    private init() {}

    // MARK: - Public API

    func checkOnLaunch() {
        checkForUpdates(showCheckingIndicator: false, manual: false)
    }

    func checkOnMenuOpen() {
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - lastCheck > 4 * 3600 {
            checkForUpdates(showCheckingIndicator: true, manual: false)
        }
    }

    func checkManually() {
        let now = Date()
        if let last = lastManualCheckTime, now.timeIntervalSince(last) < manualCheckCooldown {
            return
        }
        lastManualCheckTime = now
        checkForUpdates(showCheckingIndicator: true, manual: true)
    }

    func downloadAndInstall() {
        guard state == .available, let url = releaseURL else { return }
        state = .downloading

        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("quicktodo_update.zip")

        downloadFile(from: url, to: zipURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.verifyAndInstall(zipURL: zipURL)
            case .failure(let error):
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    if self.isManual { self.resetAfterDelay() }
                }
            }
        }
    }

    /// Returns the .app bundle URL for the current running app
    /// Works for both release .app bundles and development builds
    private var currentAppBundleURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        
        // If running from a proper .app bundle, return the .app directory
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        
        // Running from inside a .app bundle (e.g., Contents/MacOS/QuickTodo)
        // Walk up to find the .app directory
        var current = bundleURL
        while !current.pathComponents.isEmpty {
            if current.pathExtension == "app" {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        
        // Development build (running from .build/release/QuickTodo executable)
        // Find dist/quicktodo.app by searching up the directory tree
        current = bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {  // search up to 6 levels
            let candidate = current.appendingPathComponent("dist/quicktodo.app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current = current.deletingLastPathComponent()
        }
        
        return nil
    }

    // MARK: - Private

    private var isManual = false

    private func checkForUpdates(showCheckingIndicator: Bool, manual: Bool) {
        isManual = manual

        if showCheckingIndicator {
            DispatchQueue.main.async { self.state = .checking }
        }

        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }

            if let error = error {
                self.handleError(error, manual: manual)
                return
            }

            guard let data = data else {
                self.handleError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data"]), manual: manual)
                return
            }

            self.parseRelease(data: data, manual: manual)
        }.resume()
    }

    private func parseRelease(data: Data, manual: Bool) {
        struct Release: Decodable {
            let tag_name: String
            let assets: [Asset]
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }

        do {
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latestVersion = release.tag_name.dropFirst() // remove 'v'

            guard latestVersion != currentVersion else {
                DispatchQueue.main.async {
                    if manual {
                        self.state = .idle
                        self.errorMessage = "You're on the latest version (\(self.currentVersion))"
                        self.resetAfterDelay()
                    } else {
                        self.state = .idle
                    }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                }
                return
            }

            guard let asset = release.assets.first(where: { $0.name == "quicktodo.app.zip" }),
                  let downloadURL = URL(string: asset.browser_download_url) else {
                self.handleError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Release asset not found"]), manual: manual)
                return
            }

            // Try to get checksum asset
            var checksum: String?
            if let checksumAsset = release.assets.first(where: { $0.name == "quicktodo.app.zip.sha256" }),
               let checksumURL = URL(string: checksumAsset.browser_download_url) {
                // Fetch checksum synchronously (small file)
                if let checksumData = try? Data(contentsOf: checksumURL),
                   let checksumStr = String(data: checksumData, encoding: .utf8) {
                    checksum = checksumStr.split(separator: " ").first.map(String.init)
                }
            }

            DispatchQueue.main.async {
                self.state = .available
                self.releaseVersion = String(latestVersion)
                self.releaseURL = downloadURL
                self.releaseChecksum = checksum
                self.errorMessage = nil
            }

        } catch {
            handleError(error, manual: manual)
        }
    }

    private func downloadFile(from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { localURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let localURL = localURL else {
                completion(.failure(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No local file"])))
                return
            }
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {}
            do {
                try FileManager.default.moveItem(at: localURL, to: destination)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        downloads[url] = task
    }

    private func verifyAndInstall(zipURL: URL) {
        guard let expectedChecksum = releaseChecksum else {
            // No checksum available, proceed with warning
            install(zipURL: zipURL)
            return
        }

        let checksumTask = Process()
        checksumTask.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        checksumTask.arguments = ["-a", "256", zipURL.path]
        let pipe = Pipe()
        checksumTask.standardOutput = pipe

        do {
            try checksumTask.run()
            checksumTask.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let actualChecksum = output.split(separator: " ").first.map(String.init) ?? ""

            if actualChecksum.lowercased() == expectedChecksum.lowercased() {
                install(zipURL: zipURL)
            } else {
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "Checksum mismatch. Update may be corrupted."
                    if self.isManual { self.resetAfterDelay() }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Checksum verification failed: \(error.localizedDescription)"
                if self.isManual { self.resetAfterDelay() }
            }
        }
    }

    private func install(zipURL: URL) {
        DispatchQueue.main.async { self.state = .installing }

        // In-place update: extract to current app bundle's parent directory
        guard let appBundle = currentAppBundleURL else {
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Could not locate app bundle for update"
                self.resetAfterDelay()
            }
            return
        }
        
        let destDir = appBundle.deletingLastPathComponent().path
        
        // Check if the bundle itself is writable (avoids admin prompt for user-writable locations)
        let needsAdmin = !FileManager.default.isWritableFile(atPath: appBundle.path)

        // Escape single quotes for safe shell interpolation
        func shEscape(_ path: String) -> String {
            return path.replacingOccurrences(of: "'", with: "'\\''")
        }
        let zipPath = shEscape(zipURL.path)
        let destPath = shEscape(destDir)
        let bundlePath = shEscape(appBundle.path)

        let script = """
        do shell script "ditto -xk '\(zipPath)' '\(destPath)/' && xattr -dr com.apple.quarantine '\(bundlePath)'" \(needsAdmin ? "with administrator privileges" : "")
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        DispatchQueue.main.async {
            if let errorDict = errorDict {
                self.state = .error
                self.errorMessage = "Install failed: \(errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
                if self.isManual { self.resetAfterDelay() }
            } else {
                self.state = .idle
                self.releaseVersion = nil
                self.releaseURL = nil
                self.releaseChecksum = nil
                // Relaunch from the same bundle location (use .app directory, not executable)
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = [appBundle.path]
                try? task.run()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func handleError(_ error: Error, manual: Bool) {
        DispatchQueue.main.async {
            if manual {
                self.state = .error
                self.errorMessage = error.localizedDescription
                self.resetAfterDelay()
            } else {
                self.state = .idle
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        }
    }

    private func resetAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.state = .idle
            self.errorMessage = nil
        }
    }
}

// MARK: - SwiftUI Helpers

extension Updater.State {
    var helpText: String {
        switch self {
        case .checking: return "Checking for updates…"
        case .available: return "Click to download and install v\(Updater.shared.releaseVersion ?? "")"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
        case .error: return "Error: \(Updater.shared.errorMessage ?? "Unknown")"
        case .idle: return "Check for updates"
        }
    }
}