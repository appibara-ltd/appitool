# Global User Rules
- Always keep responses concise, brief, and direct. Do not provide detailed background explanations unless explicitly requested by the user.
- NEVER execute terminal commands or code directly, except for read-only Git inspection commands (e.g., `git diff`, `git status`, `git log`). Any mutating, building, or destructive commands must always be presented to the user to execute.
- NEVER make assumptions or hallucinate. Unless explicitly asked for a brainstorming session, all answers must be grounded in verified facts, code evidence, or official documentation references.
- When asked for a commit message, provide ONLY the message formatted inside a markdown code block (never wrapped inside shell commands like `git commit -m`).
- Focus strictly on verified solutions and immediate action.

# OpenAPI Management Rules
- To maintain minimal binary size and fast build times, OpenAPI targets must generate ONLY the endpoints actively used in the codebase.
- Whenever code introduces or calls a new API endpoint, immediately add its exact path to `filter.paths` in the corresponding target's `openapi-generator-config.yaml`.
- Whenever an existing API endpoint is removed or no longer referenced, immediately remove its path from `filter.paths` in the corresponding target's `openapi-generator-config.yaml`.

# Environment Variables & Configuration Architecture
- Reading environment variables (`ProcessInfo.processInfo.environment`, `getenv`, etc.) is strictly permitted ONLY within `Commands/` (and `Core/` as an exception).
- `Flow/`, `Tasks/`, and `Services/` must NEVER read environment variables directly. They must receive all required configurations, credentials, URLs, and keys purely via function arguments, initializers, or context objects.
- Commands are responsible for resolving CLI options with environment variable fallbacks and passing the resolved values down into Tasks, Services, and Flow.
- Whenever code introduces or reads a new environment variable, immediately add it to `.env.example` with a descriptive comment and placeholder value.
- Whenever an existing environment variable is removed or no longer referenced in the codebase, immediately remove it from `.env.example`.

# CLI Option Standards
- All CLI options must ideally use `name: .shortAndLong` (e.g., `-b, --bundle-id`, `-p, --package-name`, `-d, --distribution`), providing both a single-character shorthand and a descriptive kebab-case flag unless a single-character conflict exists.
- Never alias semantically different concepts under the same option (e.g., `--bundle-id` and `--app-id` are distinct concepts and must never be aliases for the same option).

# Command Structure Conventions
- Commands partitioned into platform-specific subcommands (e.g., `ios` and `android`) must be grouped into a dedicated subdirectory inside `Sources/appitool/Commands/` named after the root command (e.g., `Commands/Build/` for `BuildCommand.swift`, `BuildIOSCommand.swift`, `BuildAndroidCommand.swift`, and `Commands/Check/` for `CheckCommand.swift`, `CheckIOSCommand.swift`, `CheckAndroidCommand.swift`).
- Standalone commands without platform subcommands remain directly under `Sources/appitool/Commands/`.

# Execution & Workflow Guidelines
- Before building or executing commands, always ensure the local repository is up to date by running `git pull`.
- Always run `swift run appitool -h` first to discover existing/new subcommands and options before executing specific commands.
- The CLI can be built and executed directly via Swift Package Manager:
  ```bash
  swift run appitool <subcommand> [options]
  ```
- For minimal release binary size, always build with release configuration and strip debug/global symbols:
  ```bash
  swift build -c release && strip .build/release/appitool
  ```
