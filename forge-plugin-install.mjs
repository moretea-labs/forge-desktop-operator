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
execFileSync('/bin/bash', [join(root, 'scripts/install.sh')], { cwd: root, stdio: 'inherit' });
const registrationPath = join(homedir(), 'Library', 'Application Support', 'Forge', 'DesktopOperator', 'registration', 'registration.json');
const installed = JSON.parse(readFileSync(registrationPath, 'utf8'));
process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  providerInstall: {
    kind: 'desktop_operator',
    pluginId: 'desktop_operator',
    pluginVersion: '0.2.0',
    protocolVersion: '1.0',
    socketPath: installed.socketPath,
    launchAgentLabel: 'com.moretea.forge.desktop-operator',
    expectedProgramContains: 'Forge Desktop Operator.app'
  }
})}\n`);
