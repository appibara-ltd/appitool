import Foundation

/// Shared helpers for normalizing raw CLI / `.env` string values.
enum CLIValues {
    /// Returns the value trimmed of whitespace/newlines, or `nil` when it is `nil` or empty after trimming.
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Splits a comma-separated value into trimmed, non-empty items (`"a, b,,c"` → `["a", "b", "c"]`).
    static func commaSeparated(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Like `commaSeparated`, but returns `nil` instead of an empty array when no items remain.
    static func commaSeparatedOrNil(_ raw: String?) -> [String]? {
        let items = commaSeparated(raw)
        return items.isEmpty ? nil : items
    }
}
