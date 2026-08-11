# Architecture

## Decision

Desktop Operator is a controller-scoped external service, not a repository plugin adapter and not a repository command wrapper.

```text
ChatGPT / MCP
      |
Forge Controller
      |
External Plugin Broker (target integration)
      |
Unix domain socket JSONL
      |
desktop-operator LaunchAgent
      +-- application/window driver
      +-- Accessibility observer
      +-- semantic interaction + CGEvent fallback
      +-- screenshot artifacts
      +-- desktop session store
      +-- bounded batch executor
```

The service is installed as a user LaunchAgent because it must run in the logged-in GUI session. It is never installed as a root LaunchDaemon.

## Relationship to Forge Design

The design plugin was used as a reference for three useful properties:

1. an independent Git repository and release boundary;
2. a manifest describing stable capabilities;
3. a transport-independent core that does not import Controller private source.

Desktop Operator deliberately differs where the domain requires it:

- it is a long-lived native service rather than a repository asset editor;
- state belongs to the plugin's Application Support directory;
- the transport is a Unix socket instead of a repository CLI/API;
- sessions reference GUI processes and AX elements, not Git repositories.

## Trust and execution

The plugin does not request confirmation for each click, key, or screenshot. The user establishes trust by installing the service and granting macOS TCC access to its stable signed app identity. Forge may still apply control-plane policy to an action, but the native service does not create a second layer of per-action grants.

## State

```text
~/Applications/Forge Desktop Operator.app/       # stable TCC identity
  Contents/Info.plist
  Contents/MacOS/desktop-operator

~/Library/Application Support/Forge/DesktopOperator/
  releases/<version>/bin/desktop-operator
  registration/registration.json
  registration/forge-plugin.json          # protocol manifest filename retained for compatibility
  artifacts/
  logs/
```

The short-lived socket and lock live under `~/Library/Caches/Forge/desktop-operator.sock{,.lock}` to stay well below the macOS Unix socket path limit. A non-blocking process lock prevents multiple service instances from unlinking each other's sockets.

The LaunchAgent always executes the Mach-O inside `Forge Desktop Operator.app`. The installer prefers a persistent Developer ID or Apple Development signing identity, so replacing the binary does not intentionally create a new TCC principal. Ad-hoc signing is only a fallback and emits an explicit warning. Legacy Repo Harness environment/path names remain read-compatible only for migration; all new public identities and state use Forge.

This state is independent from Controller releases, Git worktrees, and repository leases.

## Current integration boundary

The repository and plugin registration descriptor are implemented, and Forge consumes the provider through the external plugin registration/broker path rather than importing provider source. The provider remains independently buildable and releasable.
