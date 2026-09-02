#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

if (process.platform !== 'darwin') {
  console.error('Forge Desktop Operator requires macOS.');
  process.exit(2);
}
const root = dirname(fileURLToPath(import.meta.url));
const sourceManifest = JSON.parse(readFileSync(join(root, 'forge-plugin.json'), 'utf8'));
execFileSync('/bin/bash', [join(root, 'scripts/install.sh')], { cwd: root, stdio: 'inherit' });
const registrationPath = join(homedir(), 'Library', 'Application Support', 'Forge', 'DesktopOperator', 'registration', 'registration.json');
const installed = JSON.parse(readFileSync(registrationPath, 'utf8'));
const installedManifest = JSON.parse(readFileSync(installed.manifestPath, 'utf8'));
if (installedManifest.id !== sourceManifest.id || installedManifest.version !== sourceManifest.version || installedManifest.protocolVersion !== sourceManifest.protocolVersion) {
  throw new Error('Installed Desktop Operator manifest identity does not match the source package.');
}
process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  providerInstall: {
    kind: 'desktop_operator',
    pluginId: installedManifest.id,
    pluginVersion: installedManifest.version,
    protocolVersion: installedManifest.protocolVersion,
    socketPath: installed.socketPath,
    executablePath: installed.executablePath,
    manifestPath: installed.manifestPath,
    serviceManager: installed.serviceManager,
    bundleIdentifier: installed.bundleIdentifier,
  },
})}
`);
