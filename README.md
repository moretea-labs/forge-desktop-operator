# Forge Desktop Operator

<p align="center"><strong>Native macOS desktop automation provider for Forge.</strong></p>
<p align="center"><a href="https://github.com/moretea-labs/forge">Forge</a> · <a href="docs/ARCHITECTURE.md">Architecture</a> · <a href="docs/PROTOCOL.md">Protocol</a> · <a href="SUPPORT.md">Support</a></p>
<p align="center"><img alt="CI" src="https://github.com/moretea-labs/forge-desktop-operator/actions/workflows/ci.yml/badge.svg"> <img alt="Release" src="https://img.shields.io/github/v/release/moretea-labs/forge-desktop-operator?sort=semver"> <img alt="macOS" src="https://img.shields.io/badge/platform-macOS-lightgrey"> <img alt="Swift" src="https://img.shields.io/badge/Swift-6-orange"> <img alt="License" src="https://img.shields.io/github/license/moretea-labs/forge-desktop-operator"></p>

Forge Desktop Operator is a controller-scoped macOS service that gives Forge a stable, permission-aware desktop interaction boundary. It runs outside the Controller process, keeps a persistent per-user app identity for macOS permissions, and exposes a versioned JSONL protocol over a Unix domain socket.

## Install through Forge

```bash
forge plugin install desktop_operator
forge plugin list --refresh
```

Forge owns trusted installation, registration, authorization, resource claims, and execution evidence. This repository owns the native macOS implementation and release lifecycle.

## Capabilities

- application discovery and launch;
- bounded desktop interaction sessions;
- Accessibility-tree observation with session-local references;
- semantic press and text entry with bounded coordinate fallback;
- keyboard shortcuts and URL opening;
- clipboard read/write and explicit copy/paste;
- window or display screenshots;
- bounded multi-step execution;
- structured health and error reporting.

The provider is intentionally a desktop operator substrate, **not** a repository command wrapper. Runtime operation does not require a Git checkout lease.

## Permissions and trust

macOS requires Accessibility and Screen Recording consent. The installer places a stable `Forge Desktop Operator.app` in `~/Applications` with bundle identifier `com.moretea.forge.desktop-operator`, so permissions attach to a durable app identity rather than a changing development binary.

Forge remains the policy authority. The provider does not add its own per-click approval layer and does not expose arbitrary AppleScript or arbitrary shell execution.

## Development

Requirements: macOS, Xcode/Swift toolchain, and a writable user home directory.

```bash
swift build
swift test
swift run desktop-operator doctor
./scripts/smoke.sh
```

Run the service directly during development:

```bash
swift run desktop-operator serve
```

Default socket:

```text
~/Library/Caches/Forge/desktop-operator.sock
```

Direct user-service installation remains available for provider development:

```bash
./scripts/install.sh
```

The installer prefers a persistent Developer ID or Apple Development signing identity, supports `FORGE_DESKTOP_OPERATOR_CODESIGN_IDENTITY`, and falls back to ad-hoc signing with an explicit warning. It installs a per-user LaunchAgent, never a LaunchDaemon.

## Architecture

```text
Forge Controller
      │ trusted registration + policy
      ▼
Unix socket JSONL
      │
      ▼
Forge Desktop Operator.app
      │
      ├─ Accessibility
      ├─ Screen capture
      └─ Keyboard / clipboard / URL actions
```

The public plugin identity is `desktop_operator`; the contract is declared in [`forge-plugin.json`](forge-plugin.json). See [Architecture](docs/ARCHITECTURE.md), [Protocol](docs/PROTOCOL.md), and the Forge [Plugin Management guide](https://github.com/moretea-labs/forge/blob/main/docs/forge-plugin-management.md).

## Project

Current release: `v0.3.0`, with the provider-neutral Computer protocol and backward compatibility for Forge clients using the legacy macOS browser-automation alias. Issues are for reproducible provider bugs and feature requests. Cross-product Forge questions belong in the [Forge Discussions](https://github.com/moretea-labs/forge/discussions). Security reports should use GitHub Private Vulnerability Reporting; see [SECURITY.md](SECURITY.md).

Licensed under the [MIT License](LICENSE).
