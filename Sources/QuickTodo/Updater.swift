import Foundation
import Combine
import AppKit
import CryptoKit
import QuickTodoCore

final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseVersion: String?
    @Published private(set) var releaseChecksum: String?
    @Published private(set) var releaseAssetID: Int?
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
        guard state == .available, let assetID = releaseAssetID else { return }
        state = .downloading

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktodo-update-\(UUID().uuidString)", isDirectory: true)
        let zipURL = tempDir.appendingPathComponent("quicktodo.app.zip")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Could not prepare update: \(error.localizedDescription)"
                if self.isManual { self.resetAfterDelay() }
            }
            return
        }

        downloadFileViaAPI(assetID: assetID, to: zipURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.verifyAndInstall(zipURL: zipURL, tempDir: tempDir)
            case .failure(let error):
                self.cleanup(tempDir)
                self.clearReleaseState()
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    if self.isManual { self.resetAfterDelay() }
                }
            }
        }
    }

    private func downloadFileViaAPI(assetID: Int, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(assetID)")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.downloadTask(with: request) { [weak self] localURL, _, error in
            guard let self = self else { return }
            self.downloads.removeValue(forKey: apiURL)
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
        downloads[apiURL] = task
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func clearReleaseState() {
        releaseVersion = nil
        releaseChecksum = nil
        releaseAssetID = nil
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
                let id: Int
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
                  let _ = URL(string: asset.browser_download_url) else {
                self.handleError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Release asset not found"]), manual: manual)
                return
            }

            // Download checksum asynchronously (like vidp does) - follows redirects properly
            if let checksumAsset = release.assets.first(where: { $0.name == "quicktodo.app.zip.sha256" }),
               let checksumURL = URL(string: checksumAsset.browser_download_url) {
                URLSession.shared.dataTask(with: checksumURL) { [weak self] data, _, error in
                    guard let self = self else { return }
                    var checksum: String?
                    var checksumError: Error?
                    if let data = data, error == nil,
                       let checksumStr = String(data: data, encoding: .utf8) {
                        checksum = checksumStr.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first.map(String.init)
                    } else if let error = error {
                        checksumError = error
                    }
                    DispatchQueue.main.async {
                        if let checksumError = checksumError {
                            // Checksum fetch failed - don't set available, show error for manual checks
                            self.handleError(checksumError, manual: manual)
                        } else {
                            self.state = .available
                            self.releaseVersion = String(latestVersion)
                            self.releaseAssetID = asset.id
                            self.releaseChecksum = checksum
                            self.errorMessage = nil
                        }
                    }
                }.resume()
                return
            }

// No checksum asset
            DispatchQueue.main.async {
                self.state = .available
                self.releaseVersion = String(latestVersion)
                self.releaseAssetID = asset.id
                self.releaseChecksum = nil
                self.errorMessage = nil
                        }

        } catch {
            handleError(error, manual: manual)
        }
    }

    private func verifyAndInstall(zipURL: URL, tempDir: URL) {
        guard let expectedChecksum = releaseChecksum else {
            install(zipURL: zipURL, tempDir: tempDir)
            return
        }

        // Verify checksum using Swift CryptoKit (like vidp does) instead of shelling out
        do {
            let data = try Data(contentsOf: zipURL)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual.caseInsensitiveCompare(expectedChecksum) == .orderedSame {
                install(zipURL: zipURL, tempDir: tempDir)
            } else {
                cleanup(tempDir)
                clearReleaseState()
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "Checksum mismatch. Update may be corrupted."
                    if self.isManual { self.resetAfterDelay() }
                }
            }
        } catch {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Checksum verification failed: \(error.localizedDescription)"
                if self.isManual { self.resetAfterDelay() }
            }
        }
    }

    private func install(zipURL: URL, tempDir: URL) {
        DispatchQueue.main.async { self.state = .installing }

        // In-place update: extract to current app bundle's parent directory
        guard let appBundle = currentAppBundleURL else {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Could not locate app bundle for update"
                self.resetAfterDelay()
            }
            return
        }
        
        let destDir = appBundle.deletingLastPathComponent().path
        
        // Extract using ditto (like vidp does)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destDir]
        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cleanup(tempDir)
                clearReleaseState()
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = output.isEmpty ? "The app archive could not be extracted." : output
                    self.resetAfterDelay()
                }
                return
            }
        } catch {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Extraction failed: \(error.localizedDescription)"
                self.resetAfterDelay()
            }
            return
        }

        // Remove quarantine attribute
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-dr", "com.apple.quarantine", appBundle.path]
        try? xattrProcess.run()
        xattrProcess.waitUntilExit()

        cleanup(tempDir)

        DispatchQueue.main.async {
            self.state = .idle
            self.releaseVersion = nil
            self.releaseChecksum = nil
            self.releaseAssetID = nil
            // Relaunch from the same bundle location (use .app directory, not executable)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [appBundle.path]
            try? task.run()
            NSApplication.shared.terminate(nil)
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