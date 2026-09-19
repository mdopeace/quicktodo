import Foundation
import Combine
import AppKit

final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var releaseChecksum: String?
    @Published private(set) var errorMessage: String?

    enum State { case idle, checking, available, downloading, installing, error }

    private let repo = "mdopeace/quicktodo"
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var checkTimer: Timer?
    private var downloads: [URL: URLSessionDownloadTask] = [:]

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

    /// Copy the currently running app to /Applications
    func installCurrentAppToApplications() {
        guard let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("quicktodo.app") as URL? else { return }
        
        state = .installing
        
        let script = """
        do shell script "ditto '\(appURL.path)' '/Applications/quicktodo.app' && xattr -dr com.apple.quarantine '/Applications/quicktodo.app'" with administrator privileges
        """
        
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)
        
        DispatchQueue.main.async {
            if let errorDict = errorDict {
                self.state = .error
                self.errorMessage = "Install failed: \(errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown error")"
                self.resetAfterDelay()
            } else {
                self.state = .idle
                // Relaunch from /Applications
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["/Applications/quicktodo.app"]
                try? task.run()
                NSApplication.shared.terminate(nil)
            }
        }
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

        let script = """
        do shell script "ditto -xk '\(zipURL.path)' '/Applications/' && xattr -dr com.apple.quarantine '/Applications/quicktodo.app'" with administrator privileges
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
                // Relaunch the app from /Applications
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["/Applications/quicktodo.app"]
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
    var iconName: String {
        switch self {
        case .checking: return "arrow.clockwise.circle"
        case .available: return "arrow.down.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .installing: return "gear.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return ""
        }
    }

    var iconColor: String {
        switch self {
        case .available: return "blue"
        case .error: return "orange"
        default: return "secondary"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .checking: return "Checking for updates"
        case .available: return "Update available"
        case .downloading: return "Downloading update"
        case .installing: return "Installing update"
        case .error: return "Update error"
        case .idle: return ""
        }
    }

    var helpText: String {
        switch self {
        case .checking: return "Checking for updates…"
        case .available: return "Click to download and install v\(Updater.shared.releaseVersion ?? "")"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing update…"
        case .error: return "Error: \(Updater.shared.errorMessage ?? "Unknown")"
        case .idle: return ""
        }
    }
}