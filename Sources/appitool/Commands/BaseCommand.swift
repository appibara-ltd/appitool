import ArgumentParser
import Foundation

/// Base protocol for asynchronous CLI commands that automatically loads `.env` variables before execution.
protocol BaseCommand: AsyncParsableCommand {
    func execute() async throws
}

extension BaseCommand {
    func run() async throws {
        _ = try? EnvLoader.loadEnv()
        try await execute()
    }
}
