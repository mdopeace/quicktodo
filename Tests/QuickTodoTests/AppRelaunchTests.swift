import XCTest
@testable import QuickTodoCore

/// Locks in why the relaunch cannot simply call `open`: LaunchServices dedupes
/// by bundle identifier, so the new app is never actually started.
final class AppRelaunchTests: XCTestCase {

    private func command(
        path: String = "/Applications/quicktodo.app",
        pid: pid_t = 4242
    ) -> (executable: String, arguments: [String]) {
        AppRelaunch.command(for: URL(fileURLWithPath: path), exiting: pid)
    }

    private func script(_ command: (executable: String, arguments: [String])) throws -> String {
        try XCTUnwrap(command.arguments.dropFirst().first)
    }

    func test_runs_through_a_helper_instead_of_calling_open_directly() throws {
        let command = command()

        // If this were `/usr/bin/open` with the app as its only argument,
        // LaunchServices would only activate the copy that is still running.
        XCTAssertEqual(command.executable, "/bin/sh")
        XCTAssertEqual(command.arguments.first, "-c")
        XCTAssertTrue(try script(command).contains("open"), "helper should still launch via open")
    }

    func test_waits_for_the_outgoing_process_instead_of_sleeping_a_fixed_interval() throws {
        let script = try script(command())

        // A fixed delay is only a guess about how long shutdown takes. Measured:
        // with a 1s delay and a process that takes 2.5s to exit, `open` fires
        // while the old pid is alive and is deduplicated away, so the app never
        // comes back. Polling the pid is what makes this reliable.
        XCTAssertTrue(script.contains("kill -0 \"$1\""), "expected a pid existence poll: \(script)")
        XCTAssertTrue(script.contains("\"$1\""), "expected the outgoing pid as $1: \(script)")

        let poll = try XCTUnwrap(script.range(of: "kill -0"))
        let open = try XCTUnwrap(script.range(of: "/usr/bin/open"))
        XCTAssertLessThan(poll.lowerBound, open.lowerBound, "must wait for exit before opening")
    }

    func test_poll_is_bounded_so_a_stuck_process_cannot_hang_the_helper_forever() throws {
        let script = try script(command())
        let attempts = Int(AppRelaunch.maxWait / AppRelaunch.pollInterval)
        XCTAssertTrue(
            script.contains("-lt \(attempts)"),
            "expected a bounded retry count of \(attempts): \(script)"
        )
        XCTAssertGreaterThan(attempts, 0)
    }

    func test_passes_the_outgoing_pid_so_the_helper_knows_what_to_wait_for() throws {
        XCTAssertEqual(command(pid: 4242).arguments.last, "4242")
    }

    func test_uses_absolute_tool_paths_so_it_does_not_depend_on_path() throws {
        let script = try script(command())
        XCTAssertTrue(script.contains("/usr/bin/open"), "open should be absolute: \(script)")
        XCTAssertTrue(script.contains("/bin/sleep"), "sleep should be absolute: \(script)")
    }

    func test_passes_the_bundle_path_as_an_argument_rather_than_into_the_script() throws {
        let app = "/Applications/Quick Todo & Co.app"
        let command = command(path: app)

        XCTAssertEqual(
            command.arguments[safe: 2], app,
            "the path must be passed through $0 so the shell never parses it"
        )
        let script = try script(command)
        XCTAssertFalse(script.contains(app), "interpolating the path would allow shell injection")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
