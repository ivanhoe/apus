# Security Model

Apus is designed for development use.

## Security Layers

| Layer | Protection |
|-------|------------|
| Build config | Call `Apus.shared.start(...)` only inside `#if DEBUG` |
| Network | HTTP server binds to localhost by default |
| Origin | Rejects non-local and invalid origins |
| Sandbox | File operations are constrained and sanitized |
| Project files | `read_project_file` / `edit_project_file` scoped to project root and sanitized |
| Read-only tools | Inspection tools do not mutate app state |

## Operational Guidance

- Keep Apus disabled in release builds.
- Prefer default localhost binding unless you explicitly need remote access.
- Treat actions as privileged operations and register only what your team needs.
