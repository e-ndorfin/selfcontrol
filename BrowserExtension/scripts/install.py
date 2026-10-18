#!/usr/bin/env python3
"""Register the private extension and its signed native helper for this Mac user in Helium or Chrome."""
import argparse
import hashlib
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=Path('/Applications/SelfControl.app'))
parser.add_argument('--browser', choices=['helium', 'chrome'], default='helium', help='Browser to register (default: helium).')
parser.add_argument('--browser-profile-dir', type=Path, help='Override the browser user-data directory for a nonstandard profile.')
parser.add_argument('--register-only', action='store_true', help='Register files after setup has already succeeded.')
args = parser.parse_args()
if os.getuid() == 0:
    sys.exit('Run this installer as your signed-in user, without sudo.')
root = Path(__file__).resolve().parents[1]
app = args.app.expanduser().resolve()
cli = app / 'Contents/MacOS/selfcontrol-cli'
if not cli.is_file():
    sys.exit(f'Could not find the SelfControl command-line helper at {cli}')
if not (root / 'extension/service-worker.js').is_file():
    sys.exit('Build the extension first: npm ci && npm run build (inside BrowserExtension).')
manifest = json.loads((root / 'extension/manifest.json').read_text())
digest = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
extension_id = ''.join(chr(ord('a') + int(value, 16)) for value in digest)
if extension_id != (root / 'extension-id.txt').read_text().strip():
    sys.exit('The extension ID does not match its manifest key.')
subprocess.run(['codesign', '--verify', '--strict', str(cli)], check=True)
# A malformed append proves the CLI supports framed messaging, without
# contacting the daemon or changing any settings.
payload = json.dumps({'operation': 'invalid', 'domains': []}).encode()
probe = subprocess.run([str(cli), '--native-messaging', f'chrome-extension://{extension_id}/'],
                       input=struct.pack('=I', len(payload)) + payload, capture_output=True, timeout=5)
try:
    length = struct.unpack('=I', probe.stdout[:4])[0]
    response = json.loads(probe.stdout[4:])
    assert probe.returncode == 0 and len(probe.stdout) == length + 4 and response['ok'] is False
except (ValueError, KeyError, AssertionError, struct.error):
    sys.exit('Install the newly built SelfControl app before running this installer.')
if not args.register_only:
    subprocess.run([str(cli), '--browser-setup'], check=True)

support = Path.home() / 'Library/Application Support/SelfControl'
support.mkdir(parents=True, exist_ok=True)
extension = support / 'BrowserExtension'
# Merge a new build into the stable unpacked-extension path; preserve the ID.
shutil.copytree(root / 'extension', extension, dirs_exist_ok=True)
launcher = support / 'browser-native-host'
launcher.write_text('#!/bin/sh\nexec ' + shlex.quote(str(cli)) + ' --native-messaging "$@"\n')
launcher.chmod(0o700)
browser_dir = args.browser_profile_dir.expanduser().resolve() if args.browser_profile_dir else (Path.home() / 'Library/Application Support' / ('net.imput.helium' if args.browser == 'helium' else 'Google/Chrome'))
native_hosts = browser_dir / 'NativeMessagingHosts'
native_hosts.mkdir(parents=True, exist_ok=True)
host = {
    'name': 'org.eyebeam.selfcontrol.browser',
    'description': 'Append the clicked website to the SelfControl blocklist',
    'path': str(launcher),
    'type': 'stdio',
    'allowed_origins': [f'chrome-extension://{extension_id}/']
}
path = native_hosts / 'org.eyebeam.selfcontrol.browser.json'
path.write_text(json.dumps(host, indent=2) + '\n')
path.chmod(0o600)
print(f'Extension ID: {extension_id}\nNative helper registered: {path}\n')
browser_name = 'Helium' if args.browser == 'helium' else 'Chrome'
extensions_url = 'helium://extensions' if args.browser == 'helium' else 'chrome://extensions'
print(f'In {browser_name}, open {extensions_url}, enable Developer mode, and choose Load unpacked:')
print(extension)
print('Then pin Add to SelfControl to the toolbar. Reload the extension after subsequent installs.')
