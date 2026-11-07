#!/usr/bin/env python3
"""Generated synthetic fixtures only; no certificates, signing or network."""
import copy
import datetime as dt
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name('audit-signing.py')
spec = importlib.util.spec_from_file_location('audit_signing', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.now = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        self.profile = {
            'TeamIdentifier': ['TESTTEAM'], 'ApplicationIdentifierPrefix': ['TESTTEAM'],
            'CreationDate': dt.datetime(2025, 1, 1), 'ExpirationDate': dt.datetime(2027, 1, 1),
            'Entitlements': {'application-identifier': 'TESTTEAM.com.test.app',
                             module.TEAM: 'TESTTEAM', module.GROUP: ['group.test']}}
        self.entries = []
        for i, bundle in enumerate(('com.test.app', 'com.test.app.Broadcast')):
            self.entries.append(dict(bundle_id=bundle, profile='p%d.plist' % i,
                                     entitlements='e%d.plist' % i, info='i%d.plist' % i))
            profile = copy.deepcopy(self.profile)
            profile['Entitlements']['application-identifier'] = 'TESTTEAM.' + bundle
            self.write('p%d.plist' % i, profile)
            self.write('e%d.plist' % i, {module.GROUP: ['group.test']})
            self.write('i%d.plist' % i, {'CFBundleIdentifier': bundle})

    def write(self, name, data):
        (self.base / name).write_bytes(plistlib.dumps(data))

    def result(self):
        return module.audit(self.entries, self.base, True, self.now)

    def test_valid(self):
        self.assertEqual(self.result(), [])

    def test_invalid_profiles(self):
        changes = [
            ('expired', lambda p: p.update(ExpirationDate=dt.datetime(2024, 1, 1))),
            ('future', lambda p: p.update(CreationDate=dt.datetime(2028, 1, 1))),
            ('missing_date', lambda p: p.pop('ExpirationDate')),
            ('bundle', lambda p: p['Entitlements'].update({'application-identifier': 'TESTTEAM.com.other'})),
            ('team', lambda p: p.update(TeamIdentifier=['OTHER'])),
            ('group', lambda p: p['Entitlements'].update({module.GROUP: ['group.other']})),
            ('bad_group_type', lambda p: p['Entitlements'].update({module.GROUP: 'group.test'})),
        ]
        for name, change in changes:
            with self.subTest(name=name):
                p = copy.deepcopy(self.profile)
                change(p)
                self.write('p0.plist', p)
                self.assertTrue(self.result())

    def test_no_shared_group(self):
        p = copy.deepcopy(self.profile)
        p['Entitlements'][module.GROUP] = ['group.other']
        self.write('p0.plist', p)
        self.write('e0.plist', {module.GROUP: ['group.other']})
        self.assertIn('bundles have no common authorized requested App Group', self.result())

    def test_cross_team(self):
        p = copy.deepcopy(self.profile)
        p['TeamIdentifier'] = ['OTHER']
        p['ApplicationIdentifierPrefix'] = ['OTHER']
        p['Entitlements'][module.TEAM] = 'OTHER'
        p['Entitlements']['application-identifier'] = 'OTHER.com.test.app'
        self.write('p0.plist', p)
        self.assertIn('bundles use different teams', self.result())

    def test_info_mismatch(self):
        self.write('i0.plist', {'CFBundleIdentifier': 'com.other'})
        self.assertTrue(self.result())

    def test_duplicate(self):
        self.entries.append(self.entries[0])
        self.assertTrue(self.result())

    def test_wildcard(self):
        p = copy.deepcopy(self.profile)
        p['Entitlements']['application-identifier'] = 'TESTTEAM.com.test.*'
        self.write('p0.plist', p)
        self.assertEqual(self.result(), [])

    def test_requested_identity(self):
        self.write('e0.plist', {module.TEAM: 'OTHER', module.GROUP: ['group.test']})
        self.assertTrue(self.result())
        self.write('e0.plist', {'application-identifier': 'TESTTEAM.com.other', module.GROUP: ['group.test']})
        self.assertTrue(self.result())

    def test_cms_required_and_no_credentials_in_output(self):
        sentinel = 'SECRET_SENTINEL_DO_NOT_PRINT'
        (self.base / 'p0.plist').write_text(sentinel)
        (self.base / 'manifest.json').write_text(json.dumps(self.entries))
        for flag in ([], ['--fixture-plists']):
            result = subprocess.run([sys.executable, str(SCRIPT), '--manifest',
                                     str(self.base / 'manifest.json')] + flag,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(sentinel, result.stdout + result.stderr)
            self.assertNotIn(str(self.base), result.stdout + result.stderr)

    def test_empty(self):
        self.entries = []
        self.assertTrue(self.result())


if __name__ == '__main__':
    unittest.main()
