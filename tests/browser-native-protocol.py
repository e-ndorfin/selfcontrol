#!/usr/bin/env python3
"""Exercise the real native helper against a mocked XPC client, never network rules."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import unittest

BINARY = sys.argv.pop(1)
ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'chrome-extension://' + (ROOT / 'BrowserExtension/extension-id.txt').read_text().strip() + '/'


def frame(value):
    payload = json.dumps(value, ensure_ascii=False).encode()
    return struct.pack('=I', len(payload)) + payload


def run(payload, mode='idle', origin=ORIGIN):
    env = dict(os.environ, SC_BROWSER_TEST_MODE=mode)
    proc = subprocess.run([BINARY, '--native-messaging', origin], input=payload, capture_output=True, env=env, timeout=5)
    assert proc.returncode == 0, proc.stderr.decode()
    assert len(proc.stdout) >= 4, proc.stdout
    length = struct.unpack('=I', proc.stdout[:4])[0]
    assert len(proc.stdout) == length + 4, 'stdout must contain exactly one framed response'
    response = json.loads(proc.stdout[4:])
    for key in ['ok', 'saved', 'activeApplied', 'alreadyPresent']:
        assert type(response[key]) is bool, f'{key} must be a JSON boolean, not a number'
    return response


class BrowserProtocolTests(unittest.TestCase):
    def test_idle_and_active_results(self):
        for mode, active in [('idle', False), ('active', True)]:
            reply = run(frame({'operation': 'append', 'domains': ['reddit.com', 'news.reddit.com']}), mode)
            self.assertTrue(reply['ok'])
            self.assertTrue(reply['saved'])
            self.assertEqual(reply['activeApplied'], active)

    def test_partial_and_duplicate_results(self):
        payload = frame({'operation': 'append', 'domains': ['reddit.com']})
        partial = run(payload, 'partial')
        self.assertFalse(partial['ok'])
        self.assertTrue(partial['saved'])
        self.assertFalse(partial['activeApplied'])
        self.assertEqual(partial['message'], 'Active rules failed')
        self.assertTrue(run(payload, 'duplicate')['alreadyPresent'])

    def test_helper_compatibility(self):
        payload = frame({'operation': 'append', 'domains': ['reddit.com']})
        self.assertFalse(run(payload, 'missing')['ok'])
        self.assertIn('setup', run(payload, 'old')['message'])

    def test_origin_restriction(self):
        self.assertFalse(run(frame({'operation': 'append', 'domains': ['reddit.com']}), origin='chrome-extension://' + 'a' * 32 + '/')['ok'])

    def test_invalid_frames(self):
        cases = [b'', b'\x02\x00', struct.pack('=I', 0), struct.pack('=I', 8193),
                 struct.pack('=I', 100) + b'{}', struct.pack('=I', 2) + b'\xff\xff',
                 struct.pack('=I', 2) + b'xx', frame([]), frame(None)]
        for payload in cases:
            with self.subTest(payload=payload):
                self.assertFalse(run(payload)['ok'])

    def test_invalid_operations_and_domains(self):
        for value in [
            {}, {'operation': 'remove', 'domains': ['reddit.com']},
            {'operation': 'append', 'domains': ['https://reddit.com']},
            {'operation': 'append', 'domains': ['reddit.com\nother.com']},
            {'operation': 'append', 'domains': ['reddit.com', 'www.reddit.com', 'news.reddit.com']},
            {'operation': 'append', 'domains': [42]}, {'operation': 'append', 'domains': None}
        ]:
            with self.subTest(value=value):
                self.assertFalse(run(frame(value))['ok'])

    def test_unicode_input_uses_byte_lengths(self):
        self.assertFalse(run(frame({'operation': 'append', 'domains': ['bücher.de']}))['ok'])
        self.assertTrue(run(frame({'operation': 'append', 'domains': ['xn--bcher-kva.de']}))['ok'])

    def test_fragmented_input(self):
        proc = subprocess.Popen([BINARY, '--native-messaging', ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        payload = frame({'operation': 'append', 'domains': ['reddit.com']})
        for byte in payload:
            proc.stdin.write(bytes([byte]))
            proc.stdin.flush()
        proc.stdin.close()
        output = proc.stdout.read()
        self.assertEqual(proc.wait(timeout=5), 0)
        proc.stdout.close()
        proc.stderr.close()
        self.assertTrue(json.loads(output[4:])['ok'])


unittest.main()
