import Testing
import Foundation
@testable import appitool

@Suite("EnvLoader Tests")
struct EnvLoaderTests {

    // MARK: - Core Parsing Tests

    @Test("Basic key-value parsing with whitespace trimming")
    func basicKeyValueParsing() {
        let content = """
        KEY1=value1
          KEY2  =   value2  
        KEY3=
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["KEY1"] == "value1")
        #expect(env["KEY2"] == "value2")
        #expect(env["KEY3"] == "")
    }

    @Test("Preserves equal signs inside values, URLs, and Base64 padding")
    func preservesEqualSignsAndBase64() {
        let content = """
        BASE64_SINGLE_PAD=LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t=
        BASE64_DOUBLE_PAD=c3dpZnQtdG9vbHMtdmVyc2lvbg==
        URL=https://api.example.com/v1/resource?param1=val1&param2=val2
        EQUALS_CHAIN=a=b=c=d
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["BASE64_SINGLE_PAD"] == "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t=")
        #expect(env["BASE64_DOUBLE_PAD"] == "c3dpZnQtdG9vbHMtdmVyc2lvbg==")
        #expect(env["URL"] == "https://api.example.com/v1/resource?param1=val1&param2=val2")
        #expect(env["EQUALS_CHAIN"] == "a=b=c=d")
    }

    @Test("Handles empty lines, full comments, and inline comments")
    func commentsAndEmptyLines() {
        let content = """
        # This is a full-line comment
           # Indented comment

        KEY1=hello # inline comment
        KEY2=world
        # Another comment
        """
        let env = EnvLoader.parse(content: content)

        #expect(env.count == 2)
        #expect(env["KEY1"] == "hello")
        #expect(env["KEY2"] == "world")
    }

    @Test("Unquoted value starting directly with a hash results in an empty value")
    func unquotedValueStartingWithHash() {
        let content = """
        HASH_VAL=#immediate_comment
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["HASH_VAL"] == "")
    }

    @Test("Lines without equal signs and lines with empty keys are ignored")
    func invalidLinesIgnored() {
        let content = """
        JUST_TEXT_WITHOUT_EQUALS
        ANOTHER_INVALID_LINE
        =value_without_key
          =   another_empty_key
        VALID_KEY=valid_value
        """
        let env = EnvLoader.parse(content: content)

        #expect(env.count == 1)
        #expect(env["VALID_KEY"] == "valid_value")
    }

    @Test("Double-quoted strings with escape sequences, tabs, carriage returns, and inner hashes")
    func doubleQuotedStrings() {
        let content = """
        QUOTED_HASH="secret#key#value"
        ESCAPED_NEWLINE="line1\\nline2"
        ESCAPED_CR="carriage\\rreturn"
        ESCAPED_TAB="col1\\tcol2"
        ESCAPED_QUOTES="He said \\\"hello\\\""
        ESCAPED_BACKSLASH="C:\\\\path\\\\file"
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["QUOTED_HASH"] == "secret#key#value")
        #expect(env["ESCAPED_NEWLINE"] == "line1\nline2")
        #expect(env["ESCAPED_CR"] == "carriage\rreturn")
        #expect(env["ESCAPED_TAB"] == "col1\tcol2")
        #expect(env["ESCAPED_QUOTES"] == "He said \"hello\"")
        #expect(env["ESCAPED_BACKSLASH"] == "C:\\path\\file")
    }

    @Test("Single-quoted strings preserve literal content without escape processing")
    func singleQuotedStrings() {
        let content = """
        RAW_NEWLINE='line1\\nline2'
        RAW_HASH='value#with#hashes'
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["RAW_NEWLINE"] == "line1\\nline2")
        #expect(env["RAW_HASH"] == "value#with#hashes")
    }

    @Test("Multiline double-quoted values (e.g. PEM private keys)")
    func multilineDoubleQuoted() {
        let content = """
        MULTILINE_KEY="-----BEGIN PRIVATE KEY-----
        MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg
        -----END PRIVATE KEY-----"
        AFTER_MULTILINE=success
        """
        let env = EnvLoader.parse(content: content)

        let expectedKey = """
        -----BEGIN PRIVATE KEY-----
        MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg
        -----END PRIVATE KEY-----
        """
        #expect(env["MULTILINE_KEY"] == expectedKey)
        #expect(env["AFTER_MULTILINE"] == "success")
    }

    @Test("Multiline single-quoted values")
    func multilineSingleQuoted() {
        let content = """
        MULTILINE_RAW='first line
        second line
        third line'
        NEXT_VAR=ok
        """
        let env = EnvLoader.parse(content: content)

        let expected = "first line\nsecond line\nthird line"
        #expect(env["MULTILINE_RAW"] == expected)
        #expect(env["NEXT_VAR"] == "ok")
    }

    @Test("Multiline value left unclosed at end of file is still captured")
    func unclosedMultilineAtEOF() {
        let content = """
        UNCLOSED_DOUBLE="starts here but EOF occurs
        still going
        """
        let envDouble = EnvLoader.parse(content: content)
        #expect(envDouble["UNCLOSED_DOUBLE"] == "starts here but EOF occurs\nstill going")

        let contentSingle = """
        UNCLOSED_SINGLE='literal starts
        EOF occurs
        """
        let envSingle = EnvLoader.parse(content: contentSingle)
        #expect(envSingle["UNCLOSED_SINGLE"] == "literal starts\nEOF occurs")
    }

    @Test("Ignores 'export ' prefix")
    func exportPrefix() {
        let content = """
        export API_KEY=secret_123
        export PORT=3000
        """
        let env = EnvLoader.parse(content: content)

        #expect(env["API_KEY"] == "secret_123")
        #expect(env["PORT"] == "3000")
    }

    // MARK: - ProcessInfo Injection Tests

    @Test("Injects variables into ProcessInfo environment")
    func processInfoInjection() {
        let uniqueKey = "TEST_INJECTION_KEY_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let content = "\(uniqueKey)=test_value_456"

        EnvLoader.parseAndInject(content: content, overwrite: true)

        let resolved = ProcessInfo.processInfo.environment[uniqueKey]
        #expect(resolved == "test_value_456")
    }

    @Test("Honors overwrite flag when false")
    func overwriteFlag() {
        let uniqueKey = "TEST_OVERWRITE_KEY_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

        // Set initial value
        EnvLoader.parseAndInject(content: "\(uniqueKey)=initial_value", overwrite: true)
        #expect(ProcessInfo.processInfo.environment[uniqueKey] == "initial_value")

        // Attempt overwrite with overwrite: false
        EnvLoader.parseAndInject(content: "\(uniqueKey)=new_value", overwrite: false)
        #expect(ProcessInfo.processInfo.environment[uniqueKey] == "initial_value")

        // Overwrite with overwrite: true
        EnvLoader.parseAndInject(content: "\(uniqueKey)=new_value", overwrite: true)
        #expect(ProcessInfo.processInfo.environment[uniqueKey] == "new_value")
    }

    // MARK: - Disk / File Loading Tests

    @Test("Loads environment from an existing file on disk")
    func loadEnvFromFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test_\(UUID().uuidString).env")

        let content = """
        DISK_KEY_1=loaded_from_disk
        DISK_KEY_2="quoted disk value"
        """
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let env = try EnvLoader.loadEnv(from: tempFile.path)
        #expect(env["DISK_KEY_1"] == "loaded_from_disk")
        #expect(env["DISK_KEY_2"] == "quoted disk value")
        #expect(ProcessInfo.processInfo.environment["DISK_KEY_1"] == "loaded_from_disk")
    }

    @Test("Returns empty dictionary when loading non-existent file")
    func loadEnvFromNonExistentFile() throws {
        let nonExistentPath = "/path/to/definitely/non_existent_env_file_\(UUID().uuidString).env"
        let env = try EnvLoader.loadEnv(from: nonExistentPath)

        #expect(env.isEmpty)
    }

    @Test("Resolves tilde (~) path to user home directory")
    func loadEnvTildePath() throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let fileName = "test_tilde_\(UUID().uuidString).env"
        let realFile = homeDir.appendingPathComponent(fileName)

        let content = "TILDE_TEST_KEY=tilde_success"
        try content.write(to: realFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: realFile) }

        let env = try EnvLoader.loadEnv(from: "~/\(fileName)")
        #expect(env["TILDE_TEST_KEY"] == "tilde_success")

        // Also test Windows-style tilde path (~\\)
        let envWin = try EnvLoader.loadEnv(from: "~\\\(fileName)")
        #expect(envWin["TILDE_TEST_KEY"] == "tilde_success")
    }

    @Test("Default loadEnv() call executes safely")
    func defaultLoadEnvInvocation() {
        // Calling default loadEnv(from: ".env") must not crash regardless of whether .env exists in cwd
        _ = try? EnvLoader.loadEnv()
    }
}

