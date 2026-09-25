import XCTest
@testable import QuickTodoCore

/// Locks in why the relaunch cannot simply call `open`: LaunchServices dedupes
/// by bundle identifier, so the new app is never actually started.
///
/// The behavioural tests here execute the generated command for real. Asserting
/// on substrings of the script is not enough — swapping `open "$0"` for
/// `"$1"`, or `&&` for `||`, leaves every substring check passing while
/// breaking the feature outright.
final class AppRelaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Behaviour

    func test_opens_the_bundle_path_and_not_the_pid_once_the_process_is_gone() throws {
        let log = try makeLog()
        let app = "/Applications/quicktodo.app"

        let start = Date()
        try run(AppRelaunch.command(
            for: URL(fileURLWithPath: app),
            exiting: try exitedPID(),
            open: try makeOpenStub()
        ))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            try String(contentsOf: log, encoding: .utf8), "open \(app)\n",
            "the helper must open the bundle path ($0), not the outgoing pid ($1)"
        )
        // A pid that is already gone needs no waiting. A loop that always ran to
        // its cap would burn the full budget here and silently degrade back to
        // a fixed delay, which is the bug this whole mechanism exists to avoid.
        XCTAssertLessThan(
            elapsed, AppRelaunch.maxWait / 2,
            "must not wait when the outgoing process has already exited"
        )
    }

    func test_waits_for_a_live_process_to_exit_before_opening() throws {
        let log = try makeLog()
        // The child appends to the log as it exits, so the ordering of the two
        // events is directly observable.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 0.4; echo child-exited >> \(log.path)"]
        try child.run()

        try run(AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"),
            exiting: child.processIdentifier,
            open: try makeOpenStub()
        ))
        child.waitUntilExit()

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines,
            ["child-exited", "open /Applications/quicktodo.app"],
            "open must not run while the outgoing process is still alive"
        )
    }

    // MARK: - Shape

    func test_runs_through_a_helper_instead_of_calling_open_directly() throws {
        let command = AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"), exiting: 4242
        )
        // If this were `/usr/bin/open` with the app as its only argument,
        // LaunchServices would only activate the copy that is still running.
        XCTAssertEqual(command.executable, "/bin/sh")
        XCTAssertEqual(command.arguments.first, "-c")
        XCTAssertEqual(command.arguments.last, "4242")
    }

    func test_uses_absolute_tool_paths_so_it_does_not_depend_on_path() throws {
        let script = try script()
        XCTAssertTrue(script.contains("/bin/kill"), "kill should be absolute: \(script)")
        XCTAssertTrue(script.contains("/bin/sleep"), "sleep should be absolute: \(script)")
        XCTAssertTrue(script.contains("/usr/bin/open"), "open should be absolute: \(script)")
    }

    func test_poll_is_bounded_so_a_stuck_process_cannot_hang_the_helper_forever() throws {
        let script = try script()
        // Read the cap out of the script rather than recomputing it, so a wrong
        // value is actually caught.
        let range = try XCTUnwrap(
            script.range(of: #"-lt (\d+)"#, options: .regularExpression),
            "expected a numeric retry cap in \(script)"
        )
        let attempts = try XCTUnwrap(Int(script[range].dropFirst("-lt ".count)))
        XCTAssertGreaterThan(attempts, 0, "the cap must allow at least one attempt")
        XCTAssertLessThanOrEqual(
            Double(attempts) * AppRelaunch.pollInterval, AppRelaunch.maxWait,
            "the retry cap must bound the total wait"
        )
    }

    // MARK: - Helpers

    private func script() throws -> String {
        let command = AppRelaunch.command(
            for: URL(fileURLWithPath: "/Applications/quicktodo.app"), exiting: 4242
        )
        return try XCTUnwrap(command.arguments.dropFirst().first)
    }

    private func makeLog() throws -> URL {
        root.appendingPathComponent("calls.log")
    }

    /// A stand-in for `open` that records how it was called.
    private func makeOpenStub() throws -> String {
        let stub = root.appendingPathComponent("open")
        try "#!/bin/sh\nprintf 'open %s\\n' \"$1\" >> \(try makeLog().path)\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    /// The pid of a process that has already exited.
    private func exitedPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func run(_ command: (executable: String, arguments: [String])) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }
}
