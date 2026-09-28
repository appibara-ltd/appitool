import Foundation
import OpenAPIRuntime

/// A DateTranscoder that flexibly parses ISO8601 date strings with or without
/// fractional seconds, and with various timezone representations returned by Apple APIs.
package struct FlexibleDateTranscoder: DateTranscoder, Sendable {
    package init() {}

    public func encode(_ date: Date) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func decode(_ dateString: String) throws -> Date {
        // 1. Try ISO8601 with fractional seconds (e.g. 2024-05-10T12:34:56.789Z)
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: dateString) {
            return date
        }

        // 2. Try standard ISO8601 without fractional seconds (e.g. 2024-05-10T12:34:56Z)
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        if let date = withoutFractional.date(from: dateString) {
            return date
        }

        // 3. Fallback for custom RFC3339 formats with DateFormatter
        let rfc3339 = DateFormatter()
        rfc3339.locale = Locale(identifier: "en_US_POSIX")
        rfc3339.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]

        for format in formats {
            rfc3339.dateFormat = format
            if let date = rfc3339.date(from: dateString) {
                return date
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Expected date string to be ISO8601-formatted, but '\(dateString)' could not be parsed."
            )
        )
    }
}
