import ArgumentParser
import Foundation
import Testing
@testable import appitool

@Suite("BaseCommand Tests")
struct BaseCommandTests {
    private enum StubFailure: Error, LocalizedError {
        case failed

        var errorDescription: String? { "stub generic error" }
    }

    private enum Outcome: String, ExpressibleByArgument {
        case success
        case commandError
        case commandErrorWithHint
        case validationError
        case genericError
        case customExitCode
        case cleanExit
    }

    private struct HandlingStubCommand: BaseCommand {
        static let configuration = CommandConfiguration(commandName: "handling-stub")

        @Option var outcome: Outcome = .success

        func execute() async throws {
            switch outcome {
            case .success:
                return
            case .commandError:
                throw CommandError("command failed")
            case .commandErrorWithHint:
                throw CommandError("command failed", hint: "try again")
            case .validationError:
                throw ValidationError("validation failed")
            case .genericError:
                throw StubFailure.failed
            case .customExitCode:
                throw ExitCode(42)
            case .cleanExit:
                throw CleanExit.helpRequest()
            }
        }
    }

    private struct UnhandlingStubCommand: BaseCommand {
        static let configuration = CommandConfiguration(commandName: "unhandling-stub")
        static var handlesErrors: Bool { false }

        @Option var outcome: Outcome = .success

        func execute() async throws {
            switch outcome {
            case .success:
                return
            case .commandError:
                throw CommandError("unhandled command error")
            case .commandErrorWithHint:
                throw CommandError("unhandled command error", hint: "hint")
            case .validationError:
                throw ValidationError("unhandled validation error")
            case .genericError:
                throw StubFailure.failed
            case .customExitCode:
                throw ExitCode(42)
            case .cleanExit:
                throw CleanExit.helpRequest()
            }
        }
    }

    @Test("Successful execute completes without throwing")
    func successCompletes() async throws {
        var cmd = try HandlingStubCommand.parse(["--outcome", "success"])
        try await cmd.run()
    }

    @Test("CommandError, ValidationError, and generic Error map to ExitCode.failure")
    func errorsMapToExitCodeFailure() async {
        for rawOutcome in ["commandError", "commandErrorWithHint", "validationError", "genericError"] {
            do {
                var cmd = try HandlingStubCommand.parse(["--outcome", rawOutcome])
                try await cmd.run()
                Issue.record("Expected ExitCode.failure for \(rawOutcome)")
            } catch let exitCode as ExitCode {
                #expect(exitCode == .failure)
            } catch {
                Issue.record("Unexpected error type for \(rawOutcome): \(error)")
            }
        }
    }

    @Test("Custom ExitCode and CleanExit pass through unchanged")
    func exitCodeAndCleanExitPassthrough() async {
        do {
            var cmd = try HandlingStubCommand.parse(["--outcome", "customExitCode"])
            try await cmd.run()
            Issue.record("Expected ExitCode(42)")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 42)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            var cmd = try HandlingStubCommand.parse(["--outcome", "cleanExit"])
            try await cmd.run()
            Issue.record("Expected CleanExit")
        } catch is CleanExit {
            // Expected passthrough
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Commands with handlesErrors == false still convert thrown errors to ExitCode.failure")
    func handlesErrorsFalseStillMapsToFailure() async {
        for rawOutcome in ["commandError", "validationError", "genericError"] {
            do {
                var cmd = try UnhandlingStubCommand.parse(["--outcome", rawOutcome])
                try await cmd.run()
                Issue.record("Expected ExitCode.failure for \(rawOutcome)")
            } catch let exitCode as ExitCode {
                #expect(exitCode == .failure)
            } catch {
                Issue.record("Unexpected error type for \(rawOutcome): \(error)")
            }
        }
    }
}
