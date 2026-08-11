# Contributing

Contributions are welcome. Keep changes scoped to the macOS desktop-provider boundary; Forge core policy and orchestration live in the main Forge repository.

## Development

```bash
swift build
swift test
./scripts/smoke.sh
```

Before opening a pull request, ensure the relevant tests pass, avoid committing local sockets/build products/permission state, and document user-visible protocol or permission changes. Keep provider actions bounded and typed; do not add arbitrary shell or AppleScript execution surfaces.
