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
    var isDestructive: Bool { get }
    var ciFlagOverride: Bool? { get }
    var destructiveCommandDescription: String { get }
    func execute() async throws
}

extension BaseCommand {
    static var handlesErrors: Bool { true }
    var isDestructive: Bool { false }
    var ciFlagOverride: Bool? { nil }
    var destructiveCommandDescription: String { Self._commandName }

    func ciSkipResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CIEnvironment.Resolution? {
        guard isDestructive else { return nil }
        let resolution = CIEnvironment.resolve(flag: ciFlagOverride, environment: environment)
        return resolution.isCI ? resolution : nil
    }

    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        if let skipResolution = ciSkipResolution() {
            let reason = skipResolution.source.map { " (\($0))" } ?? ""
            Log("🟡 Skipping destructive command '\(destructiveCommandDescription)' in CI mode\(reason). Re-run with --no-ci to force execution.".yellow)
            return
        }
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

/// Marker protocol for destructive commands skipped as a no-op when CI mode is active.
protocol DestructiveCommand: BaseCommand {
    var ciOptions: GlobalCIOptions { get }
}

extension DestructiveCommand {
    var isDestructive: Bool { true }
    var ciFlagOverride: Bool? { ciOptions.ci }
}
