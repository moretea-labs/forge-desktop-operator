# Implementation plan

## Delivered in the initial repository

- independent repository and Git history;
- controller-scoped external plugin manifest;
- Swift package with native macOS drivers;
- Unix socket JSONL service and client;
- session-based AX observation and interaction;
- screenshot artifacts and bounded batch execution;
- user LaunchAgent installation and registration descriptor;
- unit and protocol smoke tests.

## Next controller-side work

1. Finish the versioned external plugin protocol in `Forge`.
2. Add registry discovery for the installed `registration.json` descriptor.
3. Map plugin manifest actions into `list_plugins`, `get_plugin`, and `plugin_action_execute` without a static import.
4. Use controller-scoped resource URIs for the GUI session and input stream.
5. Add operation events/cancel to the protocol and retain the plugin process across Controller rollouts.
6. Add semantic app adapters, beginning with Shadowrocket and System Settings.

The new repository should not be folded back into the Controller source tree.
