# Forge Desktop Operator

Forge Desktop Operator is a controller-scoped macOS automation service for Forge. It runs outside the Controller process, owns desktop interaction sessions, and exposes a versioned JSONL protocol over a Unix domain socket.

The public provider is intentionally an operator substrate rather than another repository command wrapper:

- persistent per-user service;
- application discovery and launch;
- Accessibility tree observation with session-local element references;
- semantic press and text entry with bounded coordinate fallback;
- keyboard shortcuts and URL opening;
- window or display screenshots;
- bounded multi-step execution;
- structured health, errors, and evidence paths.

It does not depend on a Git checkout lease at runtime. The repository is only the source and release boundary.

## Build and test

```bash
swift build
swift test
```

## Run locally

```bash
swift run desktop-operator doctor
swift run desktop-operator serve
```

The default socket is:

```text
~/Library/Caches/Forge/desktop-operator.sock
```

Run the protocol smoke test:

```bash
./scripts/smoke.sh
```

## Install as a user service

```bash
./scripts/install.sh
```

The installer builds a versioned release and installs `~/Applications/Forge Desktop Operator.app` with the stable bundle identifier `com.moretea.forge.desktop-operator`. It signs the app with an available Developer ID or Apple Development identity (or `FORGE_DESKTOP_OPERATOR_CODESIGN_IDENTITY` when explicitly set), writes the plugin registration descriptor, and loads a per-user LaunchAgent that executes the signed app binary. If no persistent signing identity exists it falls back to ad-hoc signing with an explicit warning. It does not install a LaunchDaemon and does not couple the service to the Controller release lifecycle.

macOS still requires Accessibility and Screen Recording consent, but the user grants those permissions to the stable Forge app identity rather than a changing build output. The plugin itself does not introduce per-click or per-key confirmation gates; trust is established at installation/session level.

See [Architecture](docs/ARCHITECTURE.md) and [Protocol](docs/PROTOCOL.md).


## Forge plugin contract

This repository is the official macOS `desktop_operator` external provider for Forge. The public contract is declared in `forge-plugin.json`; Forge remains the policy, authorization, resource-claim, and execution-evidence authority.

Install through Forge when available:

```bash
forge plugin install desktop_operator
```

Direct source installation remains supported for development:

```bash
./scripts/install.sh
```

The Forge installer entrypoint is `forge-plugin-install.mjs`; it installs the signed user service and returns only bounded provider facts for Forge to validate and register.
