# Security Policy

Please do not report security vulnerabilities in public issues.

Use GitHub **Private Vulnerability Reporting** for this repository. Include the affected version, macOS version, reproduction steps, impact, and any relevant permission or process-boundary details.

For vulnerabilities in Forge core rather than this native provider, report them in the [Forge repository](https://github.com/moretea-labs/forge/security).


## Protected console unlock

Console unlock is a separate security boundary, `computer.console.unlock.v1`, not an extension of ordinary Desktop input. `desktop_key`, `desktop_type_text`, pointer input, batching, application activation, shell/AppleScript automation, and screenshots do not gain access to `loginwindow` through this feature.

Each unlock attempt requires an explicit single-use authorization and an ephemeral credential. Authorization replay and rapid repeated attempts are rejected by bounded in-memory gates. The credential is never included in provider results/errors or intentional diagnostics and is never persisted by the provider. The provider requires its own stable Accessibility identity, an actually locked current console, and the current protected `com.apple.loginwindow` surface before performing the minimal credential + Return sequence. Success is only `locked -> unlocked` as observed from the macOS session dictionary.
