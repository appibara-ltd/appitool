import Foundation

/// A reusable, atomic unit of work in appitool (similar to Fastlane actions).
/// Tasks encapsulate a single responsibility (e.g., updating build numbers, running xcodebuild/gradle, exporting artifacts).
public protocol Task: Sendable {
    associatedtype Input = Void
    associatedtype Output = Void

    /// Executes the task with the given input and returns the result.
    @discardableResult
    func run(_ input: Input) async throws -> Output
}

public extension Task where Input == Void {
    /// Convenience runner for tasks requiring no input parameters.
    @discardableResult
    func run() async throws -> Output {
        try await run(())
    }
}
