# Global User Rules
- Always keep responses concise, brief, and direct. Do not provide detailed background explanations unless explicitly requested by the user.
- NEVER execute terminal commands or code directly. Always present the required command/code to the user, explain why it is needed, and let the user execute it.
- NEVER make assumptions or hallucinate. Unless explicitly asked for a brainstorming session, all answers must be grounded in verified facts, code evidence, or official documentation references.
- Focus strictly on verified solutions and immediate action.

# OpenAPI Management Rules
- To maintain minimal binary size and fast build times, OpenAPI targets must generate ONLY the endpoints actively used in the codebase.
- Whenever code introduces or calls a new API endpoint, immediately add its exact path to `filter.paths` in the corresponding target's `openapi-generator-config.yaml`.
- Whenever an existing API endpoint is removed or no longer referenced, immediately remove its path from `filter.paths` in the corresponding target's `openapi-generator-config.yaml`.
