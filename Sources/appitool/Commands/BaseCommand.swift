import ArgumentParser
import Foundation
import Rainbow

/// Lightweight CLI command error formatted and handled centrally by `BaseCommand`.
struct CommandError: LocalizedError, Sendable {
    let message: String
    let hint: String?

    var errorDescription: String? { message }

    init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }
}

/// Base protocol for asynchronous CLI commands that automatically loads `.env` variables before execution.
protocol BaseCommand: AsyncParsableCommand {
    static var handlesErrors: Bool { get }
    func execute() async throws
}

extension BaseCommand {
    static var handlesErrors: Bool { true }

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        do {
            try await execute()
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch let cleanExit as CleanExit {
            throw cleanExit
        } catch let commandError as CommandError {
            if Self.handlesErrors {
                Log("Error: ".red.bold + commandError.message)
                if let hint = commandError.hint, !hint.isEmpty {
                    Log(hint.yellow)
                }
            }
            throw ExitCode.failure
        } catch let validationError as ValidationError {
            if Self.handlesErrors {
                Log("Error: ".red.bold + validationError.message)
            }
            throw ExitCode.failure
        } catch {
            if Self.handlesErrors {
                Log("Error: ".red.bold + error.localizedDescription)
            }
            throw ExitCode.failure
        }
    }
}
