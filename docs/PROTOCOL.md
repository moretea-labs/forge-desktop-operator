# Unix socket JSONL protocol

Each request and response is one UTF-8 JSON object followed by a newline.

## Request

```json
{"id":"request-1","method":"handshake","params":{}}
```

Methods:

- `handshake`: protocol/plugin identity plus declared internal broker protocol and action support;
- `manifest`: static manifest;
- `health`: dynamic readiness;
- `execute`: typed desktop action;
- `shutdown`: graceful service stop.

Execute parameters:

```json
{
  "action": "desktop_session_open",
  "arguments": {
    "bundle_id": "com.apple.TextEdit",
    "launch": true,
    "activate": true,
    "reuse_existing": true
  }
}
```

`desktop_session_open` reuses a durable session for the same stable application identity by default. Pass `reuse_existing=false` only when an independent interaction lifecycle is required. After a provider restart, the interaction ID may be rebound to the still-running application, but callers must observe again because AX refs, snapshot revisions, and screenshot evidence are intentionally process-local.

## Response

Success:

```json
{"id":"request-1","ok":true,"result":{}}
```

Failure:

```json
{
  "id":"request-1",
  "ok":false,
  "error":{
    "code":"ELEMENT_NOT_FOUND",
    "message":"No Accessibility element matched the selector",
    "retryable":true,
    "domain":"accessibility"
  }
}
```

## Element references

`desktop_observe` returns session-local refs such as `ax_3_24`. A ref remains valid for the corresponding process while the AX element remains valid. A new observation replaces the ref registry for that session. Callers may alternatively select by role, title, or identifier.

## Batch

`desktop_batch` accepts at most 50 non-batch actions. `on_error` is `stop` or `continue`; every executed step returns its own result or structured error.
## Internal macOS browser broker

Forge may call the provider's internal `macos_browser_automation` RPC for bounded Chrome/Vivaldi Apple Events primitives. It is intentionally not a public `execute` action in `forge-plugin.json`; Forge owns browser policy, domain allowlists, session persistence, and composition.

The handshake declares `internalCapabilities=["macos_browser_automation.v1"]`, `browserAutomationProtocolVersion`, and the exact `browserAutomationActions`. Forge must verify the required action before issuing the internal RPC; matching the public plugin version alone is not capability proof.

The internal broker is background-first:

- `create_tab` creates a tab at the end of the current browser window and restores the original active-tab index;
- a stable `{windowId, tabId}` identifies a plugin-owned browser tab across calls;
- targeted `metadata`, JavaScript, reload, and close operate on that exact tab without activating it;
- target metadata avoids AppleScript title/name coercion for background Chrome tabs and includes the browser-native loading state;
- the broker derives whether Chrome/Vivaldi is actually frontmost from macOS `NSWorkspace`, not from a potentially stale application-script property;
- targeted cross-URL `navigate` fails with `BROWSER_AUTOMATION_BACKGROUND_NAVIGATION_REQUIRES_REPLACEMENT`. Forge composes a safe replacement-tab transaction instead of foregrounding a background tab or reporting a navigation that did not occur.

Physical desktop interaction remains a separate boundary. Coordinate presses require the target application to be truly frontmost; activation success is checked against the system frontmost application before such input is allowed.
