import Foundation

/// One case per failed check, so the UI can say which one broke.
public enum InstallError: Error, Equatable {
    case extractionFailed(String)
    case noAppInArchive
    case unreadableBundle
    case bundleIdentifierMismatch(expected: String, found: String?)
    case missingExecutable(String)
    case versionMismatch(expected: String, found: String?)
    case codeSignatureFailed(String)
    case swapFailed(String)

    public var message: String {
        switch self {
        case .extractionFailed(let detail):
            return "The update archive could not be extracted. \(detail)"
        case .noAppInArchive:
            return "The update archive did not contain an app bundle."
        case .unreadableBundle:
            return "The downloaded app bundle could not be read."
        case .bundleIdentifierMismatch(let expected, let found):
            return "This is not the same app (expected \(expected), got \(found ?? "none"))."
        case .missingExecutable(let name):
            return "The downloaded app is missing its executable (\(name))."
        case .versionMismatch(let expected, let found):
            return "The downloaded app is version \(found ?? "unknown"), expected \(expected)."
        case .codeSignatureFailed(let detail):
            return "Code signature verification failed. \(detail)"
        case .swapFailed(let detail):
            return "Could not replace the app bundle. \(detail)"
        }
    }
}

public enum AppInstaller {

    /// Prefix of the staging directory an install extracts into.
    private static let stagePrefix = ".quicktodo-stage-"
    /// Prefix of the directory the outgoing bundle is parked in during the swap.
    private static let backupPrefix = ".quicktodo-previous-"

    /// Replace `liveBundle` with the app inside `zipURL`.
    ///
    /// Validates a staged copy before touching the live bundle, so a bad
    /// download can't damage the running app. The swap is two renames; the
    /// original is restored if the second fails.
    ///
    /// - Returns: the URL of the installed bundle (same path as `liveBundle`).
    @discardableResult
    public static func install(
        zipURL: URL,
        replacing liveBundle: URL,
        expectedVersion: String
    ) throws -> URL {
        let fm = FileManager.default
        let parent = liveBundle.deletingLastPathComponent()
        recoverInterruptedInstall(in: parent, liveBundle: liveBundle)

        let tag = UUID().uuidString
        let stage = parent.appendingPathComponent(stagePrefix + tag)
        let backup = parent.appendingPathComponent(backupPrefix + tag)

        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        } catch {
            throw InstallError.swapFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: stage) }

        // 1. Extract into the empty staging dir. Over the live bundle it would merge
        //    and leave the new version's dropped files behind, breaking signing.
        do {
            _ = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, stage.path])
        } catch {
            throw InstallError.extractionFailed(detail(of: error))
        }

        // 2. Validate the staged bundle.
        let staged = try locateApp(in: stage)
        try validate(
            staged,
            expectedVersion: expectedVersion,
            expectedBundleIdentifier: try identity(of: liveBundle)
        )

        // Best effort: strip quarantine before it becomes the live bundle.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // 3. Swap. Safe to move the running bundle aside; its inode lives until we exit.
        let hadPrevious = fm.fileExists(atPath: liveBundle.path)
        if hadPrevious {
            do {
                try fm.moveItem(at: liveBundle, to: backup)
            } catch {
                throw InstallError.swapFailed(error.localizedDescription)
            }
        }

        do {
            try fm.moveItem(at: staged, to: liveBundle)
        } catch {
            // Put the original back rather than leaving the user with no app.
            if hadPrevious { try? fm.moveItem(at: backup, to: liveBundle) }
            throw InstallError.swapFailed(error.localizedDescription)
        }

        try? fm.removeItem(at: backup)
        return liveBundle
    }

    // MARK: - Validation

    /// Restores a bundle parked by an install that died between its two renames,
    /// then sweeps leftovers.
    private static func recoverInterruptedInstall(in parent: URL, liveBundle: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        let backups = names.filter { $0.hasPrefix(backupPrefix) }.sorted()
        let stages = names.filter { $0.hasPrefix(stagePrefix) }
        guard !backups.isEmpty || !stages.isEmpty else { return }

        if !fm.fileExists(atPath: liveBundle.path), let newest = backups.last {
            try? fm.moveItem(at: parent.appendingPathComponent(newest), to: liveBundle)
        }
        for name in stages + backups {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    /// The bundle id the incoming app must match. Throws if the live bundle is
    /// present but unreadable — no trustworthy identity to compare against.
    private static func identity(of liveBundle: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: liveBundle.path) else {
            return Bundle.main.bundleIdentifier ?? ""
        }
        guard let identifier = Bundle(url: liveBundle)?.bundleIdentifier else {
            throw InstallError.unreadableBundle
        }
        return identifier
    }

    private static func locateApp(in dir: URL) throws -> URL {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }
        guard let app = apps.first else { throw InstallError.noAppInArchive }
        return app
    }

    private static func validate(
        _ app: URL,
        expectedVersion: String,
        expectedBundleIdentifier: String
    ) throws {
        guard let bundle = Bundle(url: app) else { throw InstallError.unreadableBundle }

        guard bundle.bundleIdentifier == expectedBundleIdentifier else {
            throw InstallError.bundleIdentifierMismatch(
                expected: expectedBundleIdentifier,
                found: bundle.bundleIdentifier
            )
        }

        let name =
            bundle.infoDictionary?["CFBundleExecutable"] as? String
            ?? bundle.bundleURL.deletingLastPathComponent().lastPathComponent
        guard let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw InstallError.missingExecutable(name)
        }

        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else {
            throw InstallError.versionMismatch(expected: expectedVersion, found: nil)
        }
        guard version == expectedVersion else {
            throw InstallError.versionMismatch(expected: expectedVersion, found: version)
        }

        do {
            _ = try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch {
            throw InstallError.codeSignatureFailed(detail(of: error))
        }
    }

    // MARK: - Process

    private static let timeout: TimeInterval = 120

    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        // One shared pipe: two would let a full buffer wedge the child.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // ponytail: output buffered in memory, not size-limited; ditto/codesign/xattr
        // only write on failure. Cap it if a tool ever gets chatty.
        var output = ""
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
            drained.signal()
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }

        // A signalled `finished` implies the process exited; only a timeout needs a kill.
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw NSError(
                domain: "AppInstaller",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(URL(fileURLWithPath: tool).lastPathComponent) timed out"
                ]
            )
        }
        drained.wait()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AppInstaller",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: output.isEmpty
                        ? "exit status \(process.terminationStatus)"
                        : output
                ]
            )
        }
        return output
    }

    private static func detail(of error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
