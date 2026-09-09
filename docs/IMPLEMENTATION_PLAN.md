# Implementation plan

## Delivered provider boundary

- independent repository, release, signed app bundle, and user LaunchAgent;
- versioned Unix-socket provider protocol and runtime capability negotiation;
- provider-neutral Computer observation/input/capture plus v2 normalized element observation and semantic actions;
- process-local AX/window/visual bindings only, with no durable Computer target/session database;
- semantic-first interaction with stale-observation invalidation and fail-closed exact target checks;
- physical pointer/keyboard fallback isolated behind foreground, exact-window, revision, and process-wide physical-input fencing;
- exact-window non-activating native capture inside the provider process;
- bounded `macos_browser_automation` compatibility adapter retained only for Forge migration;
- full Swift regression coverage and release build/install verification.

## Remaining work belongs in Forge

Desktop Operator must not grow another controller to finish the migration. The dependent Forge repository work owns:

1. durable Computer target/session authority and persistence;
2. provider discovery, selection, scoring, routing, and fallback policy;
3. Browser policy/session cutover away from the legacy macOS compatibility adapter;
4. workflow/controller transaction and outcome reconciliation;
5. candidate-level cross-provider E2E and V2 release/A-B acceptance.

After Forge no longer depends on `macos_browser_automation.v1`, remove that compatibility adapter in a normal protocol retirement change rather than creating another Browser authority here.
