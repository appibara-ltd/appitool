import Foundation
import Subprocess

/// Centralized asynchronous helper for spawning external processes, streaming tool output, and running Git commands.
enum ProcessRunner {
    static let defaultOutputLimit = 10 * 1024 * 1024

    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var isSuccess: Bool { exitCode == 0 }
    }

    enum StreamStyle: Sendable {
        case silent
        case rawStdout
        case logLines
    }

    /// Runs an executable to completion without standard input and returns its exit code and captured output.
    static func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        combineOutput: Bool = false,
        discardError: Bool = false,
        discardOutput: Bool = false,
        outputLimit: Int = defaultOutputLimit
    ) async throws -> Output {
        let exec = makeExecutable(executable)
        let args = Arguments(arguments)
        let env = makeEnvironment(environment)
        let workDir = makeWorkingDirectory(workingDirectory)

        if discardOutput && discardError {
            let result = try await Subprocess.run(
                exec,
                arguments: args,
                environment: env,
                workingDirectory: workDir,
                input: .none,
                output: .discarded,
                error: .discarded
            )
            return Output(
                exitCode: extractExitCode(result.terminationStatus),
                stdout: "",
                stderr: ""
            )
        }

        if combineOutput {
            let result = try await Subprocess.run(
                exec,
                arguments: args,
                environment: env,
                workingDirectory: workDir,
                input: .none,
                output: .string(limit: outputLimit),
                error: .combinedWithOutput
            )
            return Output(
                exitCode: extractExitCode(result.terminationStatus),
                stdout: result.standardOutput,
                stderr: ""
            )
        }

        if discardError {
            let result = try await Subprocess.run(
                exec,
                arguments: args,
                environment: env,
                workingDirectory: workDir,
                input: .none,
                output: .string(limit: outputLimit),
                error: .discarded
            )
            return Output(
                exitCode: extractExitCode(result.terminationStatus),
                stdout: result.standardOutput,
                stderr: ""
            )
        }

        let result = try await Subprocess.run(
            exec,
            arguments: args,
            environment: env,
            workingDirectory: workDir,
            input: .none,
            output: .string(limit: outputLimit),
            error: .string(limit: outputLimit)
        )
        return Output(
            exitCode: extractExitCode(result.terminationStatus),
            stdout: result.standardOutput,
            stderr: result.standardError
        )
    }

    /// Runs an executable with raw byte input and returns its exit code and raw standard output bytes.
    static func runBytes(
        _ executable: String,
        arguments: [String] = [],
        input: [UInt8],
        workingDirectory: String? = nil,
        outputLimit: Int = defaultOutputLimit
    ) async throws -> (exitCode: Int32, stdout: [UInt8]) {
        let result = try await Subprocess.run(
            makeExecutable(executable),
            arguments: Arguments(arguments),
            workingDirectory: makeWorkingDirectory(workingDirectory),
            input: .array(input),
            output: .bytes(limit: outputLimit),
            error: .discarded
        )
        return (extractExitCode(result.terminationStatus), result.standardOutput)
    }

    /// Streams combined standard output and error while buffering the complete output string.
    /// When `formatter` is provided and installed, pipes the command through `bash -c "set -o pipefail && ... | <formatter>"`.
    static func stream(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        formatter: String? = nil,
        style: StreamStyle = .logLines
    ) async throws -> Output {
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ bytes: Data) {
                lock.lock()
                data.append(bytes)
                lock.unlock()
            }

            var stringValue: String {
                lock.lock()
                defer { lock.unlock() }
                return String(data: data, encoding: .utf8) ?? ""
            }
        }

        let exec: Subprocess.Executable
        let resolvedArgs: [String]

        if let formatter, !formatter.isEmpty {
            let formatterBin = formatter.split(separator: " ").first.map(String.init) ?? ""
            if hasExecutable(formatterBin) {
                let escapedArgs = arguments.map(escapeShellArgument).joined(separator: " ")
                exec = .name("bash")
                resolvedArgs = ["-c", "set -o pipefail && \"\(executable)\" \(escapedArgs) | \(formatter)"]
            } else {
                exec = makeExecutable(executable)
                resolvedArgs = arguments
            }
        } else {
            exec = makeExecutable(executable)
            resolvedArgs = arguments
        }

        let buffer = OutputBuffer()

        let result = try await Subprocess.run(
            exec,
            arguments: Arguments(resolvedArgs),
            environment: makeEnvironment(environment),
            workingDirectory: makeWorkingDirectory(workingDirectory),
            input: .none,
            output: .sequence,
            error: .combinedWithOutput
        ) { execution in
            var pending = Data()
            let newline = UInt8(ascii: "\n")

            func emitLine(_ lineData: Data) {
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                Log(line)
            }

            for try await bufferChunk in execution.standardOutput {
                let data = Data(buffer: bufferChunk)
                guard !data.isEmpty else { continue }
                buffer.append(data)

                switch style {
                case .silent:
                    continue
                case .rawStdout:
                    FileHandle.standardOutput.write(data)
                case .logLines:
                    pending.append(data)
                    while let idx = pending.firstIndex(of: newline) {
                        emitLine(pending.subdata(in: pending.startIndex..<idx))
                        pending.removeSubrange(pending.startIndex...idx)
                    }
                }
            }

            if case .logLines = style, !pending.isEmpty {
                emitLine(pending)
            }
        }

        return Output(
            exitCode: extractExitCode(result.terminationStatus),
            stdout: buffer.stringValue,
            stderr: ""
        )
    }

    /// Executes Git non-interactively (`-c core.askPass= -c credential.helper=`).
    static func git(
        _ arguments: [String],
        in workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        combineOutput: Bool = false
    ) async throws -> Output {
        try await run(
            "git",
            arguments: ["-c", "core.askPass=", "-c", "credential.helper="] + arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            combineOutput: combineOutput
        )
    }

    /// Checks whether an executable exists at an explicit path or in standard macOS/Unix binary directories.
    static func hasExecutable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name)
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let fullPath = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return true
            }
        }
        return false
    }

    // MARK: - Private Helpers

    private static func makeExecutable(_ executable: String) -> Subprocess.Executable {
        executable.hasPrefix("/") ? .path(FilePath(executable)) : .name(executable)
    }

    private static func makeEnvironment(_ environment: [String: String]?) -> Subprocess.Environment {
        guard let environment else { return .inherit }
        var updates: [Subprocess.Environment.Key: String?] = [:]
        for (key, value) in environment {
            updates[Subprocess.Environment.Key(stringLiteral: key)] = value
        }
        return Subprocess.Environment.inherit.updating(updates)
    }

    private static func makeWorkingDirectory(_ workingDirectory: String?) -> FilePath? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return FilePath(workingDirectory)
    }

    private static func extractExitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code):
            return code
        #if !os(Windows)
        case .signaled(let code):
            return code
        #endif
        }
    }

    private static func escapeShellArgument(_ arg: String) -> String {
        if arg.contains(" ") || arg.contains("\"") || arg.contains("'") {
            return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return arg
    }
}
