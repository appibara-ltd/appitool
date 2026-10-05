import Foundation

/// Centralized logging struct replacing standard `print` calls.
/// Can be invoked directly as `Log(...)` with identical semantics to `Swift.print`.
package struct Log: Sendable {
    package nonisolated(unsafe) static var depth: Int = 0

    @discardableResult
    package init(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let output = items.map { "\($0)" }.joined(separator: separator)
        let indent = items.isEmpty ? "" : String(repeating: " ", count: max(0, Log.depth))
        Swift.print("\(indent)\(output)", terminator: terminator)
    }

    @discardableResult
    package init() {
        Swift.print()
    }
}
