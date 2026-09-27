#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import ucrt
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#endif
import Foundation

/// A utility for parsing `.env` files and injecting environment variables into `ProcessInfo`.
public enum EnvLoader {

    /// Loads and parses environment variables from a `.env` file at the specified path,
    /// injecting them into the current process environment (`ProcessInfo`).
    ///
    /// - Parameters:
    ///   - path: The file path to the `.env` file (defaults to `".env"` in the current working directory).
    ///   - overwrite: Whether existing environment variables should be overwritten (defaults to `false`).
    /// - Returns: A dictionary of parsed key-value pairs loaded from the file.
    /// - Throws: An error if the file exists but cannot be read.
    @discardableResult
    public static func loadEnv(from path: String = ".env", overwrite: Bool = false) throws -> [String: String] {
        let fileManager = FileManager.default

        // Resolve tilde (`~`) if present in path
        var resolvedPath = path
        if resolvedPath.hasPrefix("~/") || resolvedPath.hasPrefix("~\\") {
            let subpath = String(resolvedPath.dropFirst(2))
            resolvedPath = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
        }

        guard fileManager.fileExists(atPath: resolvedPath) else {
            return [:]
        }

        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        return parseAndInject(content: content, overwrite: overwrite)
    }

    /// Parses the raw string contents of an environment file and injects the variables into `ProcessInfo`.
    ///
    /// - Parameters:
    ///   - content: Raw text content formatted as key-value pairs.
    ///   - overwrite: Whether existing environment variables should be overwritten (defaults to `false`).
    /// - Returns: A dictionary of parsed key-value pairs.
    @discardableResult
    public static func parseAndInject(content: String, overwrite: Bool = false) -> [String: String] {
        let parsed = parse(content: content)
        for (key, value) in parsed {
            setEnvironmentVariable(key: key, value: value, overwrite: overwrite)
        }
        return parsed
    }

    /// Parses the raw string contents of an environment file into a dictionary of key-value pairs.
    ///
    /// Supports:
    /// - Single-line and multiline quoted values (`"` and `'`).
    /// - Full-line and trailing comments starting with `#`.
    /// - Escaped characters (`\n`, `\r`, `\t`, `\"`, `\\`) in double-quoted strings.
    /// - Preserves `=` characters inside values (e.g., Base64 padding or URLs).
    /// - Optional `export ` prefix (compatible with bash/sh export syntax).
    ///
    /// - Parameter content: Raw text content.
    /// - Returns: Dictionary of parsed key-value pairs.
    public static func parse(content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)

        var currentMultilineKey: String?
        var currentMultilineQuote: Character?
        var currentMultilineBuffer = ""

        for line in lines {
            // Case 1: Currently inside a multiline quoted string
            if let key = currentMultilineKey, let quote = currentMultilineQuote {
                if let closingIndex = findClosingQuoteIndex(in: line, quote: quote) {
                    // Reached the closing quote
                    let segment = String(line[..<closingIndex])
                    currentMultilineBuffer += (currentMultilineBuffer.isEmpty ? "" : "\n") + segment

                    let finalizedValue = finalizeValue(currentMultilineBuffer, quote: quote)
                    result[key] = finalizedValue

                    // Reset multiline tracker
                    currentMultilineKey = nil
                    currentMultilineQuote = nil
                    currentMultilineBuffer = ""
                } else {
                    // Line does not close the quote, accumulate and continue
                    currentMultilineBuffer += (currentMultilineBuffer.isEmpty ? "" : "\n") + line
                }
                continue
            }

            // Case 2: Standard line parsing
            var trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Ignore empty lines and full comment lines
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }

            // Strip optional 'export ' prefix (e.g., 'export FOO=bar')
            if trimmedLine.hasPrefix("export ") {
                trimmedLine = String(trimmedLine.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }

            // Must contain an '=' delimiter separating key and value
            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmedLine[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                continue
            }

            let rawValue = String(trimmedLine[trimmedLine.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

            // Inspect opening quote
            if let firstChar = rawValue.first, (firstChar == "\"" || firstChar == "'") {
                let quoteChar = firstChar
                let contentAfterFirstQuote = String(rawValue.dropFirst())

                if let closingIndex = findClosingQuoteIndex(in: contentAfterFirstQuote, quote: quoteChar) {
                    // Single-line quoted string
                    let quotedContent = String(contentAfterFirstQuote[..<closingIndex])
                    result[key] = finalizeValue(quotedContent, quote: quoteChar)
                } else {
                    // Multiline string starts here
                    currentMultilineKey = key
                    currentMultilineQuote = quoteChar
                    currentMultilineBuffer = contentAfterFirstQuote
                }
            } else {
                // Unquoted value: strip trailing inline comments (e.g. `KEY=value # comment`)
                let cleanedValue = stripInlineComment(from: rawValue)
                result[key] = cleanedValue
            }
        }

        // If EOF was reached while still in a multiline string, save what we have
        if let key = currentMultilineKey, let quote = currentMultilineQuote {
            result[key] = finalizeValue(currentMultilineBuffer, quote: quote)
        }

        return result
    }

    // MARK: - Private Helpers

    /// Sets an environment variable in the current process across POSIX (setenv) and Windows (_putenv_s).
    public static func setEnvironmentVariable(key: String, value: String, overwrite: Bool = false) {
        #if os(Windows)
        if overwrite || getenv(key) == nil {
            _putenv_s(key, value)
        }
        #else
        setenv(key, value, overwrite ? 1 : 0)
        #endif
    }

    /// Finds the index of an unescaped closing quote character in a line.
    private static func findClosingQuoteIndex(in line: String, quote: Character) -> String.Index? {
        var isEscaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]

            if char == "\\" && quote == "\"" {
                isEscaped.toggle()
            } else {
                if char == quote && !isEscaped {
                    return index
                }
                isEscaped = false
            }

            index = line.index(after: index)
        }

        return nil
    }

    /// Finalizes the parsed value depending on whether it was double-quoted or single-quoted.
    private static func finalizeValue(_ value: String, quote: Character) -> String {
        if quote == "\"" {
            // Unescape escaped characters in double-quoted strings
            return value
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else {
            // Single quotes preserve content literally
            return value
        }
    }

    /// Strips trailing inline comments from unquoted values (e.g. `value # comment`).
    private static func stripInlineComment(from value: String) -> String {
        // Only consider '#' as an inline comment if preceded by whitespace
        if let range = value.range(of: " #") {
            return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("#") {
            return ""
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
