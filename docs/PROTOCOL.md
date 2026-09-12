# Unix socket JSONL protocol

Each request and response is one UTF-8 JSON object followed by a newline.

## Methods

- `handshake`: plugin identity, Computer runtime descriptors, and explicitly named compatibility metadata;
- `manifest`: static provider manifest;
- `health`: dynamic native readiness;
- `execute`: compatibility Desktop actions declared by the public plugin manifest;
- `computer_execute`: provider-neutral Unified Computer capability execution;
- `macos_browser_automation`: deprecated migration-only Browser compatibility RPC;
- `shutdown`: graceful service stop.

Example request:

```json
{"id":"request-1","method":"handshake","params":{}}
```

## Provider-local interaction bindings

`desktop_session_open` creates or reuses a process-local provider binding to a running application. The returned interaction id is not durable Computer authority. Provider restart intentionally drops interaction ids, AX refs, snapshot revisions, and screenshot evidence; Forge must rebind and observe again from its own durable Computer target.

`desktop_observe` and `computer.element.observe.v2` create an observation epoch. Element refs such as `ax_7_24` and AX window refs are valid only for the exact interaction/application/window context and `snapshotRevision` that produced them. A new observation replaces the ref registry.

A successful `computer.element.action.v2` semantic mutation retires the authorizing observation epoch. Reusing its old ref fails with `COMPUTER_ELEMENT_OBSERVATION_STALE`; callers must re-observe. Bounds are metadata only and never authorize pointer input.

## Unified Computer negotiation

`handshake` and `health` include `computerCapabilities`, each with `capabilityId`, integer `protocolVersion`, transport `method`, and bounded `actions`. The provider currently advertises:

- `computer.observe.v1`;
- `computer.input.v1`;
- `computer.capture.v1`;
- `computer.element.observe.v2`;
- `computer.element.action.v2`.

Unknown capabilities and incompatible protocol versions fail before native dispatch. `computer.browser_automation.v1` is not a Unified Computer capability of this provider.

Example semantic observation request:

```json
{"id":"computer-observe-1","method":"computer_execute","params":{"capability":"computer.element.observe.v2","protocolVersion":2,"arguments":{"interactionId":"desk_example"}}}
```

Example semantic action request shape:

```json
{"id":"computer-action-1","method":"computer_execute","params":{"capability":"computer.element.action.v2","protocolVersion":2,"arguments":{"target":{"interactionId":"desk_example","pid":123,"bundleIdentifier":"com.example.Editor","appName":"Editor","windowRef":"ax_7_1","snapshotRevision":7},"ref":"ax_7_24","action":"invoke"}}}
```

## Foreground and physical input

Accessibility observation and semantic AX actions do not require foreground solely because they inspect or mutate UI. Physical pointer/keyboard actions remain separately fenced: the exact target app must already be foreground, pointer input requires fresh exact-window visual evidence, and the provider does not activate a different app as an implicit fallback.

Window capture requires an exact `window_id` and uses an in-process native capture path. Capture does not activate the target application.

## Browser compatibility adapter

The handshake still declares `internalCapabilities=["macos_browser_automation.v1"]`, `browserAutomationProtocolVersion`, and bounded `browserAutomationActions` for migration compatibility. Forge may use this explicit legacy RPC while older Browser integration is being retired.

This adapter is not a public `execute` action and is not advertised in `computerCapabilities`. Forge owns Browser policy, durable tab/session identity, allowlists, and transaction composition. The provider exposes no arbitrary shell or arbitrary AppleScript method.

## Batch

`desktop_batch` accepts at most 50 non-batch actions. `on_error` is `stop` or `continue`; each executed step returns its own result or structured error. Batch execution does not create a second global semantic lock: individual actions keep their own native locking/fencing requirements.

## Response

Success:

```json
{"id":"request-1","ok":true,"result":{}}
```

Failure:

```json
{"id":"request-1","ok":false,"error":{"code":"COMPUTER_ELEMENT_OBSERVATION_STALE","message":"Re-observe before acting.","retryable":true,"domain":"accessibility"}}
```


## Explicit console unlock capability

`computer.console.unlock.v1` is a provider-owned, macOS-only protected capability exposed through `computer_execute` with action `unlock_console`. It is intentionally separate from `computer.input.v1` and from the compatibility `execute`/`desktop_batch` action surface.

The invocation requires a non-reusable `explicit_single_use` authorization envelope and one ephemeral `credential` field. The provider consumes the authorization before checking or performing physical input, applies a bounded in-memory attempt window, requires the current console to be locked, resolves only the visible `com.apple.loginwindow` protected surface, revalidates that target immediately before input, performs only credential text plus Return, and reports success only after the system lock dictionary observes the console become unlocked. No screenshot, clipboard, coordinate, shell, AppleScript, application-activation, or generic key fallback is permitted.

Credential material is request-memory only. It is not part of manifest state, plugin registration, result/error payloads, logs, persisted receipts, or provider state. An unchanged authoritative lock state is a typed failure rather than transport success.


## Protected console credential preparation

`computer.console.unlock.v1` exposes two protected actions. `prepare_unlock_console` is valid only while the console is unlocked; it shows a provider-local secure password field and returns an opaque `credential_handle` plus a bounded expiry. The credential never enters the socket request or response. `unlock_console` consumes that handle exactly once after the console is locked, then performs the existing loginwindow identity checks, credential text + Return input, and authoritative unlocked postcondition verification. Provider restart or handle expiry invalidates the preparation.
