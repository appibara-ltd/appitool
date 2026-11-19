import Foundation
import Testing
@testable import appitool

@Suite("ProcessRunner Tests")
struct ProcessRunnerTests {

    @Test("Captures stdout and stderr separately and combined")
    func runCapturesStdoutAndStderr() async throws {
        let separate = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo hello_out && echo hello_err >&2"]
        )
        #expect(separate.isSuccess)
        #expect(separate.exitCode == 0)
        #expect(separate.stdout.contains("hello_out"))
        #expect(separate.stderr.contains("hello_err"))

        let combined = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo combined_out && echo combined_err >&2"],
            combineOutput: true
        )
        #expect(combined.isSuccess)
        #expect(combined.stdout.contains("combined_out"))
        #expect(combined.stdout.contains("combined_err"))
        #expect(combined.stderr.isEmpty)
    }

    @Test("Propagates non-zero exit codes and supports discarded output")
    func exitCodeAndDiscardedOutput() async throws {
        let failure = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "exit 7"])
        #expect(!failure.isSuccess)
        #expect(failure.exitCode == 7)

        let discarded = try await ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo ignored_out && echo ignored_err >&2"],
            discardError: true,
            discardOutput: true
        )
        #expect(discarded.isSuccess)
        #expect(discarded.stdout.isEmpty)
        #expect(discarded.stderr.isEmpty)
    }

    @Test("Pipes raw stdin bytes and collects stdout bytes")
    func runBytesRoundtrip() async throws {
        let payload = Array("appitool-bytes-test".utf8)
        let result = try await ProcessRunner.runBytes("/bin/cat", input: payload)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "appitool-bytes-test")
    }

    @Test("Streams output cleanly in silent mode")
    func streamSilentCollectsOutput() async throws {
        let result = try await ProcessRunner.stream(
            "/bin/sh",
            arguments: ["-c", "echo line_1 && echo line_2"],
            style: .silent
        )
        #expect(result.isSuccess)
        #expect(result.stdout.contains("line_1"))
        #expect(result.stdout.contains("line_2"))
    }

    @Test("Executes git helper and checks standard executables")
    func gitAndHasExecutable() async throws {
        let gitResult = try await ProcessRunner.git(["--version"])
        #expect(gitResult.isSuccess)
        #expect(gitResult.stdout.lowercased().contains("git version"))

        #expect(ProcessRunner.hasExecutable("ls"))
        #expect(ProcessRunner.hasExecutable("/bin/sh"))
        #expect(!ProcessRunner.hasExecutable("definitely_missing_binary_\(UUID().uuidString)"))
        #expect(!ProcessRunner.hasExecutable(""))
    }
}
