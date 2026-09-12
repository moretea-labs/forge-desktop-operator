# Architecture

## Decision

Forge Desktop Operator is a controller-scoped macOS-native provider for Forge's Unified Computer Interaction Plane. It is an independently built and signed user service, not a second Computer controller, not a repository command wrapper, and not a durable semantic state owner.

```text
ChatGPT / MCP
      |
Forge Controller
      +-- durable Computer target/session authority
      +-- provider selection / policy / transaction ownership
      |
      v
External Plugin Broker
      | versioned Computer provider protocol
      v
Unix domain socket JSONL
      |
desktop-operator LaunchAgent
      +-- application/window mechanics
      +-- Accessibility observation + semantic actions
      +-- exact-window native capture
      +-- foreground-fenced physical input fallback
      +-- ephemeral AX / visual bindings
```

The service is installed as a user LaunchAgent because it must run in the logged-in GUI session. It is never installed as a root LaunchDaemon.

## Authority boundary

Forge is the sole owner of durable Computer semantics. Desktop Operator must not own or infer:

- durable Computer targets or interaction sessions;
- provider selection, scoring, routing, fallback policy, or cross-provider arbitration;
- Browser policy, durable Browser/tab session identity, or domain allowlists;
- Work, Controller, Workflow, approval, or scheduling decisions;
- semantic transaction reconciliation, retry ownership, or outcome authority.

Desktop Operator owns only native mechanics and rebuildable provider-local bindings. An interaction id, AX element ref, AX window ref, snapshot revision, or visual evidence record is process-local provider state. Provider restart drops those bindings and Forge must rebind/re-observe from its durable target authority.

A successful semantic element mutation retires the observation epoch that authorized it. Old element/window refs then fail closed as stale; callers must re-observe. Bounds are observation metadata and never element identity or pointer authorization.

## Native interaction policy

Accessibility observation and semantic AX actions are target-bound and do not require foreground merely because they mutate UI. Physical pointer/keyboard operations are different: they retain a dedicated process-wide physical-input lock, require the exact target application to already be foreground, and preserve window/revision fencing. The provider never silently promotes a failed semantic action into coordinate input.

Window capture is non-activating and requires an exact window id. Capture runs inside the signed provider process through native CoreGraphics/ImageIO and is validated against the target window before and after capture when used as pointer evidence.

## Browser compatibility boundary

`BrowserAutomationBroker` is a migration-only internal compatibility adapter. It is not advertised through Unified Computer and cannot own Forge Browser sessions or Browser policy. The historical `macos_browser_automation` RPC remains temporarily available for Forge clients that still need bounded Chrome/Vivaldi Apple Events primitives. It is the only named duplicate compatibility surface in this repository and is intended for retirement after Forge completes its Browser/Computer cutover.

The compatibility adapter may use bounded Apple Events required by that legacy surface, but Desktop Operator exposes no arbitrary AppleScript or shell execution API. Browser durable authority remains in Forge.

## Trust and execution

The user establishes native trust by installing the signed app and granting macOS TCC access to its stable bundle identity. Forge may apply control-plane policy before dispatch; Desktop Operator does not create another per-action approval authority.

TCC-sensitive actions execute from `Forge Desktop Operator.app`. Accessibility and Screen Recording permission ownership therefore remains attached to the signed provider app rather than an arbitrary shell process.

## Filesystem and lifecycle state

```text
~/Applications/Forge Desktop Operator.app/
  Contents/Info.plist
  Contents/MacOS/desktop-operator

~/Library/Application Support/Forge/DesktopOperator/
  releases/<version>/bin/desktop-operator
  registration/registration.json
  registration/forge-plugin.json
  artifacts/
  logs/

~/Library/Caches/Forge/
  desktop-operator.sock
  desktop-operator.sock.lock
```

There is intentionally no durable Desktop Computer session database. Registration, release binaries, artifacts, and logs are provider lifecycle assets; they are not Computer target/session authority. The short-lived socket and lock remain under `~/Library/Caches/Forge` to keep the Unix socket path bounded.

The LaunchAgent starts through `/usr/bin/env -i` with a minimal `HOME`, `PATH`, `LANG`, and `TMPDIR` allowlist. Controller credentials and unrelated user-session environment variables are not inherited. Legacy Repo Harness environment/path names remain read-compatible only where migration requires them.

## Integration boundary

The provider is independently buildable and releasable. Forge consumes it through registration plus the versioned Unix-socket protocol rather than source imports. Runtime capability descriptors are negotiation evidence, not another policy layer.

The advertised Unified Computer capabilities are `computer.observe.v1`, `computer.input.v1`, `computer.capture.v1`, `computer.element.observe.v2`, and `computer.element.action.v2`. `computer.browser_automation.v1` is deliberately not advertised.


### Protected console boundary

`computer.console.unlock.v1` is an independent provider capability because lock-screen credential input has a distinct authorization and secret-lifetime boundary. Forge owns the provider-neutral contract, negotiation, and explicit authorization policy; Desktop Operator owns macOS lock-state facts, exact `loginwindow` binding, physical input, bounded attempt enforcement, and postcondition verification. The capability is not reachable from the provider's generic compatibility action dispatcher or `desktop_batch`, so ordinary Computer input remains target-bound and cannot be widened into a lock-screen primitive.


### Console credential locality

The protected console-unlock boundary does not require ChatGPT or Forge Runtime to transport the macOS login password. Desktop Operator owns a short-lived, process-local credential vault populated only from a provider-local secure prompt while the console is unlocked. Forge receives only an opaque single-use handle. This keeps raw credentials out of MCP arguments, plugin receipts, Process/Work state, logs, files, clipboard state, and replayable jobs while preserving the existing loginwindow-only input and postcondition checks.
