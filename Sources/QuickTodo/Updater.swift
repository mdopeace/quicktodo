import Foundation
import Combine
import AppKit
import CryptoKit
import os
import QuickTodoCore

enum UpdaterError: Int, Error, CaseIterable {
    static let domain = "UpdaterError"
    case checksumMissing = 1
    case checksumAssetMissing = 2
    case bundleValidationFailed = 3
}

final class Updater: ObservableObject {
    static let shared = Updater()

    /// `NSLog` from a LaunchServices-started agent does not surface in the
    /// unified log, so update failures were effectively invisible. Visible by
    /// default: `log show --predicate 'eventMessage CONTAINS "QuickTodo.updater"'`.
    private static let log = Logger(subsystem: "com.mdopeace.quicktodo", category: "updater")

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var releaseChecksum: String?
    @Published private(set) var releaseAssetID: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadProgress: Double = 0

    enum State { case idle, checking, available, downloading, installing, error, upToDate }

    private let repo = "mdopeace/quicktodo"
    private let currentVersion = appVersion
    private var checkTimer: Timer?
    private var downloads: [URL: URLSessionDownloadTask] = [:]
    private var downloadObservations: [URL: NSKeyValueObservation] = [:]
    private var lastManualCheckTime: Date?
    private let manualCheckCooldown: TimeInterval = 10
    private let requestTimeout: TimeInterval = 30
    private var currentCheckTask: URLSessionDataTask?
    private var currentChecksumTask: URLSessionDataTask?
    private var isManualCheck = false

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
        // Don't overwrite available update notification
        if state == .available { return }
        
        let now = Date()
        if let last = lastManualCheckTime, now.timeIntervalSince(last) < manualCheckCooldown {
            // Show friendly message instead of silently returning
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Please wait a moment before checking again"
                self.resetAfterDelay()
            }
            return
        }
        checkForUpdates(showCheckingIndicator: true, manual: true)
    }

    func downloadAndInstall() {
        guard state == .available, let url = releaseURL else { return }
        state = .downloading

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktodo-update-\(UUID().uuidString)", isDirectory: true)
        let zipURL = tempDir.appendingPathComponent("quicktodo.app.zip")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Could not prepare update: \(error.localizedDescription)"
                if self.isManualCheck { self.resetAfterDelay() }
            }
            return
        }

        downloadFile(from: url, to: zipURL) { [weak self] result in
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
                    if self.isManualCheck { self.resetAfterDelay() }
                }
            }
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func clearReleaseState() {
        releaseVersion = nil
        releaseURL = nil
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

    private func checkForUpdates(showCheckingIndicator: Bool, manual: Bool) {
        isManualCheck = manual

        // Cancel any in-flight request
        currentCheckTask?.cancel()
        currentChecksumTask?.cancel()

        if showCheckingIndicator {
            DispatchQueue.main.async { self.state = .checking }
        }

        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = requestTimeout

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            self.currentCheckTask = nil

            // Only update cooldown on successful response (not on error)
            if error == nil, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                self.lastManualCheckTime = Date()
            }

            if let error = error {
                // Ignore cancelled requests
                if (error as NSError).code == NSURLErrorCancelled { return }
                self.handleError(error, manual: manual)
                return
            }

            guard let data = data else {
                self.handleError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data"]), manual: manual)
                return
            }

            // Handle rate limiting
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    self.handleError(NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub API rate limited. Please try again later."]), manual: manual)
                    return
                }
            }

            self.parseRelease(data: data, manual: manual)
        }
        currentCheckTask = task
        task.resume()
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
            
            // Safely extract version from tag_name (handle both "v1.3.2" and "1.3.2" formats)
            let latestVersion: String
            if release.tag_name.hasPrefix("v") {
                latestVersion = String(release.tag_name.dropFirst())
            } else {
                latestVersion = release.tag_name
            }

            guard latestVersion != currentVersion else {
                DispatchQueue.main.async {
                    if manual {
                        self.state = .upToDate
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
                  let downloadURL = URL(string: asset.browser_download_url),
                  downloadURL.scheme == "https" else {
                self.handleError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Release asset not found or invalid URL"]), manual: manual)
                return
            }

            // Download checksum asynchronously (like vidp does) - follows redirects properly
            if let checksumAsset = release.assets.first(where: { $0.name == "quicktodo.app.zip.sha256" }),
               let checksumURL = URL(string: checksumAsset.browser_download_url),
               checksumURL.scheme == "https" {
                let checksumReq = URLRequest(url: checksumURL, timeoutInterval: requestTimeout)
                currentChecksumTask?.cancel()
                let task = URLSession.shared.dataTask(with: checksumReq) { [weak self] data, _, error in
                    guard let self = self else { return }
                    self.currentChecksumTask = nil
                    var checksum: String?
                    var checksumError: Error?
                    if let data = data, error == nil,
                       let checksumStr = String(data: data, encoding: .utf8) {
                        checksum = checksumStr.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first.map(String.init)
                    } else if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled { return }
                        checksumError = error
                    }
                    DispatchQueue.main.async {
                        if let checksumError = checksumError {
                            self.clearReleaseState()
                            self.handleError(checksumError, manual: manual)
                        } else {
                            guard let checksum = checksum else {
                                self.clearReleaseState()
                                self.handleError(NSError(domain: UpdaterError.domain, code: UpdaterError.checksumMissing.rawValue, userInfo: [NSLocalizedDescriptionKey: "Checksum file was empty"]), manual: manual)
                                return
                            }
                            self.state = .available
                            self.releaseVersion = String(latestVersion)
                            self.releaseURL = downloadURL
                            self.releaseAssetID = asset.id
                            self.releaseChecksum = checksum
                            self.errorMessage = nil
                        }
                    }
                }
                currentChecksumTask = task
                task.resume()
                return
            }

            // No checksum asset - require checksum for security
            self.handleError(NSError(domain: UpdaterError.domain, code: UpdaterError.checksumAssetMissing.rawValue, userInfo: [NSLocalizedDescriptionKey: "Release is missing required checksum file"]), manual: manual)

        } catch {
            handleError(error, manual: manual)
        }
    }

    private func downloadFile(from url: URL, to destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = requestTimeout

        let task = URLSession.shared.downloadTask(with: req) { [weak self] localURL, response, error in
            guard let self = self else { return }
            self.downloads.removeValue(forKey: url)
            self.downloadObservations.removeValue(forKey: url)
            self.downloadProgress = 0
            
            if let error = error {
                // Ignore cancelled requests
                if (error as NSError).code == NSURLErrorCancelled { return }
                completion(.failure(error))
                return
            }
            guard let localURL = localURL else {
                completion(.failure(NSError(domain: UpdaterError.domain, code: UpdaterError.bundleValidationFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "No local file"])))
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
        
        // Observe progress
        let observation = task.progress.observe(\Progress.fractionCompleted) { [weak self] progress, change in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        
        task.resume()
        downloads[url] = task
        downloadObservations[url] = observation
    }

    private func verifyAndInstall(zipURL: URL, tempDir: URL) {
        // Fail closed: without the expected digest there is nothing to verify
        // against, so installing would mean trusting an unverified download.
        guard let expectedChecksum = releaseChecksum else {
            fail("The update is missing its checksum, so it was not installed.", tempDir: tempDir)
            return
        }

        // Verify checksum using Swift CryptoKit (like vidp does) instead of shelling out
        do {
            let data = try Data(contentsOf: zipURL)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                fail("Checksum mismatch. The update was not installed.", tempDir: tempDir)
                return
            }
            install(zipURL: zipURL, tempDir: tempDir)
        } catch {
            fail("Checksum verification failed: \(error.localizedDescription)", tempDir: tempDir)
        }
    }

    private func install(zipURL: URL, tempDir: URL) {
        DispatchQueue.main.async { self.state = .installing }

        guard let version = releaseVersion else {
            fail("The update to install is no longer known. Check for updates again.", tempDir: tempDir)
            return
        }
        guard let appBundle = currentAppBundleURL else {
            fail("Could not locate the running app to update.", tempDir: tempDir)
            return
        }

        // AppInstaller stages, validates, then swaps. The live bundle is only
        // touched once the staged copy has passed every check.
        do {
            let installed = try AppInstaller.install(
                zipURL: zipURL,
                replacing: appBundle,
                expectedVersion: version
            )
            cleanup(tempDir)
            DispatchQueue.main.async { self.relaunch(from: installed) }
        } catch let error as InstallError {
            fail(error.message, tempDir: tempDir)
        } catch {
            fail("Update failed: \(error.localizedDescription)", tempDir: tempDir)
        }
    }

    private func fail(_ message: String, tempDir: URL) {
        cleanup(tempDir)
        clearReleaseState()
        Self.log.error("\(AppRelaunch.logTag): update failed: \(message, privacy: .public)")
        DispatchQueue.main.async {
            self.state = .error
            self.errorMessage = message
            self.resetAfterDelay()
        }
    }

    private func relaunch(from appURL: URL) {
        state = .idle
        clearReleaseState()

        // Launch through a detached helper rather than calling `open` here:
        // LaunchServices will not start a second copy of an app whose bundle id
        // is already running, so opening now would only re-activate this
        // process, which then exits and leaves nothing running. The helper waits
        // for this process to actually be gone before opening, because an
        // orderly shutdown is not instantaneous.
        let command = AppRelaunch.command(
            for: appURL,
            exiting: ProcessInfo.processInfo.processIdentifier
        )
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command.executable)
        helper.arguments = command.arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice

        // The pid is this app's own, and it is the one the helper waits on, so
        // label it as such — logging it as the helper's would send a debugger
        // looking for a process that has already exited.
        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            try helper.run()
            Self.log.notice("""
                \(AppRelaunch.logTag): update installed, helper will reopen once \
                pid \(pid, privacy: .public) exits
                """)
        } catch {
            state = .error
            errorMessage = "Update installed but could not restart: \(error.localizedDescription)"
            resetAfterDelay()
            return
        }

        // Let the helper be scheduled before this process goes away.
        Thread.sleep(forTimeInterval: 0.2)
        NSApplication.shared.terminate(nil)
    }

    private func handleError(_ error: Error, manual: Bool) {
        DispatchQueue.main.async {
            if manual {
                self.state = .error
                self.errorMessage = self.friendlyErrorMessage(for: error)
                self.resetAfterDelay()
            } else {
                self.state = .idle
            }
            // Only update last check time on actual error (not cancelled)
            if (error as NSError).code != NSURLErrorCancelled {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            }
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Cannot reach update server. Check your internet connection."
            case NSURLErrorTimedOut:
                return "Update check timed out. Try again."
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection. Cannot check for updates."
            case NSURLErrorNetworkConnectionLost:
                return "Network connection lost. Try again."
            case NSURLErrorCancelled:
                return "Update check cancelled."
            default:
                return "Network error: \(error.localizedDescription)"
            }
        }
        // Handle HTTP status codes
        if nsError.domain == "" {
            if nsError.code == 403 || nsError.code == 429 {
                return "GitHub API rate limited. Please try again later."
            }
        }
        return error.localizedDescription
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
        case .downloading: 
            let progress = Int(Updater.shared.downloadProgress * 100)
            return "Downloading update… \(progress)%"
        case .installing: return "Installing update…"
        case .upToDate:
            if let msg = Updater.shared.errorMessage, !msg.isEmpty {
                return msg
            }
            return "You're on the latest version"
        case .error: return "Error: \(Updater.shared.errorMessage ?? "Unknown")"
        case .idle: 
            if let msg = Updater.shared.errorMessage, !msg.isEmpty {
                return msg
            }
            return "Check for updates"
        }
    }
}