# Unix socket JSONL protocol

Each request and response is one UTF-8 JSON object followed by a newline.

## Request

```json
{"id":"request-1","method":"handshake","params":{}}
```

Methods:

- `handshake`: protocol and plugin identity;
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
    "activate": true
  }
}
```

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
