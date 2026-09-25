import XCTest
@testable import QuickTodoCore

/// End-to-end coverage for the update install path: a real signed bundle is
/// zipped, then installed over an existing install exactly as the app does it.
final class AppInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appinstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Happy path

    func test_installs_new_version_and_drops_files_the_new_version_removed() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0", strayFile: "LegacyOnly.txt")

        let incoming = root.appendingPathComponent("incoming/Tool.app")
        try makeBundle(at: incoming, version: "1.1.0")
        let archive = try zip(incoming, at: root.appendingPathComponent("incoming"))

        let installed = try AppInstaller.install(
            zipURL: archive, replacing: live, expectedVersion: "1.1.0"
        )

        XCTAssertEqual(installed, live)
        XCTAssertEqual(try version(of: live), "1.1.0")

        // The update replaces the bundle rather than merging into it. A file the
        // new version dropped must not survive — it would invalidate the
        // signature of the freshly installed app.
        let stray = live.appendingPathComponent("Contents/Resources/LegacyOnly.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertNoThrow(try codesignVerify(live))
    }

    func test_leaves_no_staging_or_backup_directories_behind() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0"),
            at: root.appendingPathComponent("incoming")
        )

        _ = try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")

        XCTAssertEqual(try leftovers(), [])
    }

    // MARK: - Rejections leave the running app untouched

    func test_version_mismatch_reports_both_versions() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        // The release shipped a bundle that does not match its own tag.
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.0.0"),
            at: root.appendingPathComponent("incoming")
        )

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            XCTAssertEqual(
                error as? InstallError,
                .versionMismatch(expected: "1.1.0", found: "1.0.0")
            )
        }
        XCTAssertEqual(try version(of: live), "1.0.0", "running app must survive a rejected update")
        XCTAssertEqual(try leftovers(), [])
    }

    func test_missing_version_stamp_is_reported_as_unknown() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        let incoming = try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0")
        try removeVersionStamp(from: incoming)
        try codesign(incoming)
        let archive = try zip(incoming, at: root.appendingPathComponent("incoming"))

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            XCTAssertEqual(
                error as? InstallError,
                .versionMismatch(expected: "1.1.0", found: nil)
            )
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
    }

    func test_bundle_of_a_different_app_is_rejected() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0", identifier: "com.example.tool")
        let archive = try zip(
            try makeBundle(
                at: root.appendingPathComponent("incoming/Tool.app"),
                version: "1.1.0",
                identifier: "com.attacker.other"
            ),
            at: root.appendingPathComponent("incoming")
        )

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            XCTAssertEqual(
                error as? InstallError,
                .bundleIdentifierMismatch(expected: "com.example.tool", found: "com.attacker.other")
            )
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
    }

    func test_corrupt_archive_is_rejected() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        let junk = root.appendingPathComponent("junk.zip")
        try Data("not a zip at all".utf8).write(to: junk)

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: junk, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            guard case .extractionFailed = error as? InstallError else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
    }

    func test_archive_without_an_app_is_rejected() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")

        let source = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "readme".write(
            to: source.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8
        )
        let archive = try zipDirectory(source, at: root.appendingPathComponent("plain.zip"))

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            XCTAssertEqual(error as? InstallError, .noAppInArchive)
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
    }

    func test_bundle_with_a_broken_signature_is_rejected() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        let incoming = try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0")
        // Tamper after signing so the seal no longer matches.
        try "tampered".write(
            to: incoming.appendingPathComponent("Contents/Resources/tamper.txt"),
            atomically: true, encoding: .utf8
        )
        let archive = try zip(incoming, at: root.appendingPathComponent("incoming"))

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            guard case .codeSignatureFailed = error as? InstallError else {
                return XCTFail("expected codeSignatureFailed, got \(error)")
            }
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
    }

    func test_unwritable_destination_fails_without_touching_the_app() throws {
        let parent = root.appendingPathComponent("locked", isDirectory: true)
        let live = parent.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0"),
            at: root.appendingPathComponent("incoming")
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }

        // Running as root would bypass the permission bits entirely.
        try XCTSkipIf(getuid() == 0, "permission bits do not apply to root")

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            guard case .swapFailed = error as? InstallError else {
                return XCTFail("expected swapFailed, got \(error)")
            }
        }
        XCTAssertEqual(try version(of: live), "1.0.0")
        XCTAssertEqual(try leftovers(in: parent), [])
    }

    // MARK: - Interrupted installs

    func test_recovers_an_app_left_missing_by_an_interrupted_install() throws {
        let parent = root.appendingPathComponent("Applications", isDirectory: true)
        let live = parent.appendingPathComponent("Tool.app")
        // A previous install died between its two renames: the app is gone and
        // the last working version is still parked in its backup directory.
        try makeBundle(
            at: parent.appendingPathComponent(".quicktodo-previous-crashed"),
            version: "1.0.0"
        )
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0"),
            at: root.appendingPathComponent("incoming")
        )

        _ = try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")

        XCTAssertEqual(try version(of: live), "1.1.0")
        XCTAssertEqual(try leftovers(in: parent), [])
    }

    func test_sweeps_leftovers_from_an_earlier_interrupted_install() throws {
        let live = root.appendingPathComponent("Tool.app")
        try makeBundle(at: live, version: "1.0.0")
        try makeBundle(
            at: root.appendingPathComponent(".quicktodo-stage-abandoned"), version: "0.9.0"
        )
        try makeBundle(
            at: root.appendingPathComponent(".quicktodo-previous-abandoned"), version: "0.9.0"
        )
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0"),
            at: root.appendingPathComponent("incoming")
        )

        _ = try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")

        XCTAssertEqual(try version(of: live), "1.1.0")
        XCTAssertEqual(try leftovers(), [], "stale staging/backup dirs must not pile up")
    }

    func test_unreadable_installed_bundle_is_rejected_rather_than_trusted() throws {
        let live = root.appendingPathComponent("Tool.app")
        // A .app directory with no Info.plist cannot be identified, so there is
        // nothing to check the incoming bundle against.
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let archive = try zip(
            try makeBundle(at: root.appendingPathComponent("incoming/Tool.app"), version: "1.1.0"),
            at: root.appendingPathComponent("incoming")
        )

        XCTAssertThrowsError(
            try AppInstaller.install(zipURL: archive, replacing: live, expectedVersion: "1.1.0")
        ) { error in
            XCTAssertEqual(error as? InstallError, .unreadableBundle)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: live.appendingPathComponent("Contents/Info.plist").path
            ),
            "an unidentifiable install must not be overwritten"
        )
        XCTAssertEqual(try leftovers(), [])
    }

    // MARK: - Helpers

    private func version(of app: URL) throws -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (info as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    private func removeVersionStamp(from app: URL) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization
            .propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
        info.removeValue(forKey: "CFBundleShortVersionString")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// Any staging or backup dirs the installer should have cleaned up.
    private func leftovers(in dir: URL? = nil) throws -> [String] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: (dir ?? root).path)
        return names.filter { $0.hasPrefix(".quicktodo-") }
    }

    @discardableResult
    private func makeBundle(
        at url: URL,
        version: String,
        identifier: String = "com.example.tool",
        strayFile: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        try fm.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleExecutable": "Tool",
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Tool",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = contents.appendingPathComponent("MacOS/Tool")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        if let strayFile {
            try "old".write(
                to: contents.appendingPathComponent("Resources/\(strayFile)"),
                atomically: true, encoding: .utf8
            )
        }

        try codesign(url)
        return url
    }

    private func zip(_ bundle: URL, at destination: URL) throws -> URL {
        try zipDirectory(bundle, at: destination.appendingPathComponent("\(bundle.lastPathComponent).zip"))
    }

    /// Mirrors package.sh: `ditto -c -k --keepParent`.
    private func zipDirectory(_ dir: URL, at archive: URL) throws -> URL {
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dir.path, archive.path])
        return archive
    }

    private func codesign(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    }

    private func codesignVerify(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AppInstallerTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent): \(output)"]
            )
        }
        return output
    }
}
