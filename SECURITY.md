# Security Policy

Please do not report security vulnerabilities in public issues.

Use GitHub **Private Vulnerability Reporting** for this repository. Include the affected version, macOS version, reproduction steps, impact, and any relevant permission or process-boundary details.

For vulnerabilities in Forge core rather than this native provider, report them in the [Forge repository](https://github.com/moretea-labs/forge/security).


## Protected console unlock

Console unlock is a separate security boundary, `computer.console.unlock.v1`, not an extension of ordinary Desktop input. `desktop_key`, `desktop_type_text`, pointer input, batching, application activation, shell/AppleScript automation, and screenshots do not gain access to `loginwindow` through this feature.

Each unlock attempt requires an explicit single-use authorization and an ephemeral credential. Authorization replay and rapid repeated attempts are rejected by bounded in-memory gates. The credential is never included in provider results/errors or intentional diagnostics and is never persisted by the provider. The provider requires its own stable Accessibility identity, an actually locked current console, and the current protected `com.apple.loginwindow` surface before performing the minimal credential + Return sequence. Success is only `locked -> unlocked` as observed from the macOS session dictionary.


Raw console credentials are not part of the ChatGPT-facing contract. Before a protected unlock, Desktop Operator may collect the credential locally in an `NSSecureTextField` while the console is unlocked and return only an opaque, process-local, single-use handle. The credential is held only in provider memory for a bounded TTL, is replaced by newer preparation, and is removed when consumed. Provider restart invalidates every handle. The legacy raw-credential provider input remains compatibility-only for rolling upgrades and is not exposed by the current ChatGPT tool surface.
