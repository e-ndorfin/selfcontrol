#!/usr/bin/env python3
"""Check registration in temporary homes, without touching browser profiles."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'BrowserExtension/scripts/install.py'


class BrowserInstallerTests(unittest.TestCase):
    def install(self, browser='helium', register_only=True, supported=True, custom=False):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            app = home / 'SelfControl with spaces.app'
            cli = app / 'Contents/MacOS/selfcontrol-cli'
            cli.parent.mkdir(parents=True)
            cli.write_text('test fixture')
            arguments = [str(INSTALLER), '--app', str(app), '--browser', browser]
            if register_only:
                arguments.append('--register-only')
            if custom:
                arguments.extend(['--browser-profile-dir', str(home / 'custom browser')])
            calls = []

            def execute(command, **kwargs):
                calls.append(command)
                payload = json.dumps({'ok': False}).encode()
                output = struct.pack('=I', len(payload)) + payload if supported else b'Old CLI usage text'
                return subprocess.CompletedProcess(command, 0, output, b'')

            with patch.object(Path, 'home', return_value=home), patch.object(sys, 'argv', arguments), \
                 patch('subprocess.run', side_effect=execute), patch('os.getuid', return_value=501), \
                 contextlib.redirect_stdout(io.StringIO()):
                if not supported:
                    with self.assertRaisesRegex(SystemExit, 'newly built SelfControl'):
                        runpy.run_path(str(INSTALLER), run_name='__main__')
                    self.assertFalse((home / 'Library').exists())
                    return
                runpy.run_path(str(INSTALLER), run_name='__main__')
            profile = home / 'custom browser' if custom else home / 'Library/Application Support' / (
                'net.imput.helium' if browser == 'helium' else 'Google/Chrome')
            host_path = profile / 'NativeMessagingHosts/org.eyebeam.selfcontrol.browser.json'
            host = json.loads(host_path.read_text())
            origin = 'chrome-extension://' + (ROOT / 'BrowserExtension/extension-id.txt').read_text().strip() + '/'
            self.assertEqual(host['allowed_origins'], [origin])
            self.assertEqual(host_path.stat().st_mode & 0o777, 0o600)
            launcher = Path(host['path'])
            self.assertEqual(launcher.stat().st_mode & 0o777, 0o700)
            self.assertIn("'" + str(cli) + "'", launcher.read_text())
            extension = home / 'Library/Application Support/SelfControl/BrowserExtension'
            self.assertTrue((extension / 'service-worker.js').is_file())
            self.assertEqual(json.loads((extension / 'manifest.json').read_text())['permissions'], ['activeTab', 'nativeMessaging'])
            self.assertEqual([str(cli), '--browser-setup'] in calls, not register_only)

    def test_helium_registration(self):
        self.install()

    def test_chrome_registration(self):
        self.install(browser='chrome')

    def test_custom_profile_registration(self):
        self.install(custom=True)

    def test_default_setup_initializes_helper(self):
        self.install(register_only=False)

    def test_old_cli_rejected_before_writing_profile(self):
        self.install(supported=False)


unittest.main()
