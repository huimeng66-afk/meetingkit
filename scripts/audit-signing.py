#!/usr/bin/env python3
"""Offline provisioning authorization audit. Never prints profile contents or paths."""
import argparse
import datetime as dt
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

GROUP = 'com.apple.security.application-groups'
TEAM = 'com.apple.developer.team-identifier'


def decode_profile(path, fixture=False):
    if fixture:
        return plistlib.loads(Path(path).read_bytes())
    commands = []
    if shutil.which('openssl'):
        commands.append(['openssl', 'cms', '-verify', '-inform', 'DER', '-noverify', '-in', str(path)])
    if sys.platform == 'darwin' and shutil.which('security'):
        commands.append(['security', 'cms', '-D', '-i', str(path)])
    for command in commands:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            return plistlib.loads(result.stdout)
    raise ValueError('profile CMS decode failed or decoder unavailable')


def matches(pattern, value):
    return isinstance(pattern, str) and (pattern == value or
        (pattern.endswith('.*') and '*' not in pattern[:-1] and value.startswith(pattern[:-1])))


def audit(entries, base, fixture=False, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    errors, shared, teams, seen = [], None, set(), set()
    for index, entry in enumerate(entries, 1):
        prefix = 'bundle #%d: ' % index
        try:
            bundle = entry['bundle_id']
            if not isinstance(bundle, str) or not bundle or '$' in bundle or '*' in bundle or bundle in seen:
                raise ValueError('invalid or duplicate bundle identifier')
            seen.add(bundle)
            profile = decode_profile(base / entry['profile'], fixture)
            requested = plistlib.loads((base / entry['entitlements']).read_bytes())
            if 'info' in entry:
                info = plistlib.loads((base / entry['info']).read_bytes())
                if info.get('CFBundleIdentifier') != bundle:
                    raise ValueError('Info.plist bundle identifier mismatch')
            ent = profile['Entitlements']
            team_list = profile['TeamIdentifier']
            team = ent.get(TEAM)
            if not team or not isinstance(team_list, list) or team_list != [team]:
                raise ValueError('profile team mismatch')
            teams.add(team)
            if requested.get(TEAM, team) != team:
                raise ValueError('requested team mismatch')
            appid = ent.get('application-identifier', '')
            prefixes = profile.get('ApplicationIdentifierPrefix', [])
            if not isinstance(prefixes, list) or not prefixes or not any(
                    matches(appid, p + '.' + bundle) for p in prefixes if isinstance(p, str)):
                raise ValueError('application-identifier does not authorize bundle')
            req_id = requested.get('application-identifier')
            if req_id is not None and (not matches(appid, req_id) or not any(
                    req_id == p + '.' + bundle for p in prefixes)):
                raise ValueError('requested application-identifier mismatch')
            for key in ('CreationDate', 'ExpirationDate'):
                value = profile.get(key)
                if not isinstance(value, dt.datetime):
                    raise ValueError('missing or invalid profile validity date')
                value = value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value
                if (key == 'ExpirationDate' and value <= now) or (key == 'CreationDate' and value > now):
                    raise ValueError('profile expired or not yet valid')
            allowed, wanted = ent.get(GROUP, []), requested.get(GROUP, [])
            if not isinstance(allowed, list) or not isinstance(wanted, list) or not all(
                    isinstance(x, str) and x.startswith('group.') and '*' not in x for x in allowed + wanted):
                raise ValueError('invalid App Group list')
            if not set(wanted).issubset(allowed):
                raise ValueError('requested App Group not authorized')
            granted = set(wanted) & set(allowed)
            shared = granted if shared is None else shared & granted
        except (KeyError, ValueError, TypeError, OSError, plistlib.InvalidFileException, AttributeError):
            # Deliberately omit exception text: malformed input can contain credentials.
            errors.append(prefix + 'authorization or input validation failed')
    if len(teams) > 1:
        errors.append('bundles use different teams')
    if len(entries) > 1 and not shared:
        errors.append('bundles have no common authorized requested App Group')
    if not entries:
        errors.append('no bundles supplied')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, help='JSON array: bundle_id, profile, entitlements, optional info; paths relative to manifest')
    parser.add_argument('--fixture-plists', action='store_true', help='TEST ONLY: accept unsigned profile plists; never use for signing')
    args = parser.parse_args()
    try:
        manifest = Path(args.manifest)
        entries = json.loads(manifest.read_text())
        if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
            raise ValueError()
        errors = audit(entries, manifest.resolve().parent, args.fixture_plists)
    except Exception:
        errors = ['manifest or profile input rejected']
    for error in errors:
        print('FAIL: ' + error)
    if not errors:
        print('PASS: bundle authorization, teams, validity and App Group intersection checked')
    print('Scope: offline authorization only; CMS trust chain, certificate/private key pairing and code signatures are not verified.')
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
