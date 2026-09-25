import Foundation
import Combine
import AppKit
import CryptoKit
import QuickTodoCore

enum UpdaterError: Int, Error, CaseIterable {
    static let domain = "UpdaterError"
    case checksumMissing = 1
    case checksumAssetMissing = 2
    case bundleValidationFailed = 3
    case codeSignatureFailed = 4
    case processTimeout = 5
    case relaunchFailed = 6
}

final class Updater: ObservableObject {
    static let shared = Updater()

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
    private let processTimeout: TimeInterval = 60
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
                    if self.isManualCheck { self.resetAfterDelay() }
                }
            }
        } catch {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Checksum verification failed: \(error.localizedDescription)"
                if self.isManualCheck { self.resetAfterDelay() }
            }
        }
    }

    // Helper to run Process with timeout
    private func runProcessWithTimeout(_ process: Process, timeout: TimeInterval? = nil, description: String) throws {
        let timeoutInterval = timeout ?? processTimeout
        try process.run()
        
        let semaphore = DispatchSemaphore(value: 0)
        var terminated = false
        
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            terminated = true
            semaphore.signal()
        }
        
        let result = semaphore.wait(timeout: .now() + timeoutInterval)
        if result == .timedOut {
            if !terminated {
                process.terminate()
                semaphore.wait() // Wait for termination to complete
            }
            throw NSError(domain: UpdaterError.domain, code: UpdaterError.processTimeout.rawValue, userInfo: [NSLocalizedDescriptionKey: "\(description) timed out after \(Int(timeoutInterval))s"])
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
        let extractedApp = URL(fileURLWithPath: destDir).appendingPathComponent("quicktodo.app")
        
        // Extract using ditto (like vidp does)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destDir]
        let pipe = Pipe()
        process.standardError = pipe

        do {
            try runProcessWithTimeout(process, description: "Extraction")
            guard process.terminationStatus == 0 else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("QuickTodo: ditto failed: %@", output)
                cleanup(tempDir)
                clearReleaseState()
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "The app archive could not be extracted."
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

        // Validate extracted bundle
        guard let extractedBundle = Bundle(url: extractedApp),
              extractedBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let executableURL = extractedBundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              let extractedVersion = extractedBundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              extractedVersion == releaseVersion else {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Downloaded app bundle is invalid or version mismatch."
                self.resetAfterDelay()
            }
            return
        }

        // Verify code signature
        let codesignProcess = Process()
        codesignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignProcess.arguments = ["--verify", "--strict", extractedApp.path]
        let codesignPipe = Pipe()
        codesignProcess.standardError = codesignPipe
        do {
            try runProcessWithTimeout(codesignProcess, description: "Code signature verification")
            if codesignProcess.terminationStatus != 0 {
                let output = String(data: codesignPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cleanup(tempDir)
                clearReleaseState()
                DispatchQueue.main.async {
                    self.state = .error
                    self.errorMessage = "Code signature verification failed: \(output)"
                    self.resetAfterDelay()
                }
                return
            }
        } catch {
            cleanup(tempDir)
            clearReleaseState()
            DispatchQueue.main.async {
                self.state = .error
                self.errorMessage = "Code signature check failed: \(error.localizedDescription)"
                self.resetAfterDelay()
            }
            return
        }

        // Remove quarantine attribute
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-dr", "com.apple.quarantine", extractedApp.path]
        do {
            try runProcessWithTimeout(xattrProcess, description: "Quarantine removal")
        } catch {
            // Log but don't fail - quarantine removal is best effort
            print("Warning: Failed to remove quarantine attribute: \(error)")
        }

        cleanup(tempDir)

        DispatchQueue.main.async {
            self.state = .idle
            self.releaseVersion = nil
            self.releaseURL = nil
            self.releaseChecksum = nil
            self.releaseAssetID = nil
            // Relaunch from the same bundle location (use .app directory, not executable)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [extractedApp.path]
            do {
                try task.run()
                // Give the new process time to start before terminating
                Thread.sleep(forTimeInterval: 0.5)
                NSApplication.shared.terminate(nil)
            } catch {
                self.state = .error
                self.errorMessage = "Update installed but failed to relaunch: \(error.localizedDescription)"
                self.resetAfterDelay()
            }
        }
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