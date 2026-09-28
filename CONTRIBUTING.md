# Contributing to nullTickets

1. **Read [AGENTS.md](AGENTS.md)** first — it defines the engineering protocol,
   module map, and conventions for this repository.
2. One concern per PR. No drive-by refactors.
3. Before every commit:
   - `zig build test --summary all` — 0 failures, 0 leaks
   - `bash tests/test_e2e.sh` — end-to-end API flow must pass
   - `zig fmt --check src/`
4. Every PR runs the 4-target CI matrix (linux-x86_64, linux-aarch64,
   macos-aarch64, windows-x86_64). Keep it green.
5. Bug fixes must include a regression test citing the issue number.
6. REST API changes must keep `/openapi.json` and `/.well-known/openapi.json`
   exports in sync — the tracker contract is consumed by agents and
   orchestrators that depend on it.
