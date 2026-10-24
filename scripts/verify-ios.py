"""Verify an actual signed iOS archive/IPA without exposing device IDs or keys."""
from pathlib import Path
import argparse, datetime, fnmatch, json, plistlib, stat, subprocess, tempfile, zipfile


def run(*args):
    result = subprocess.run(args, capture_output=True, timeout=90)
    if result.returncode:
        raise ValueError(f'{args[0]} exited {result.returncode}')
    return result.stdout


def verify(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = info['CFBundleExecutable']
    if Path(executable).name != executable:
        raise ValueError('Invalid executable path')
    arches = run('/usr/bin/lipo', '-archs', str(app / executable)).decode().split()
    if 'arm64' not in arches or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Not an arm64 iPhoneOS application')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    entitlements = plistlib.loads(run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)))
    team = entitlements.get('com.apple.developer.team-identifier')
    if not team:
        raise ValueError('Missing Apple team signature; ad-hoc signing is insufficient')
    profile_path = app / 'embedded.mobileprovision'
    if not profile_path.is_file():
        raise ValueError('Missing install/distribution provisioning profile')
    profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', str(profile_path)))
    if team not in profile.get('TeamIdentifier', []):
        raise ValueError('Profile and signature teams differ')
    expiry = profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
    if expiry <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile expired')
    identifier = entitlements.get('application-identifier', '')
    allowed = profile.get('Entitlements', {}).get('application-identifier', '')
    if not identifier.endswith('.' + info['CFBundleIdentifier']) or not fnmatch.fnmatchcase(identifier, allowed):
        raise ValueError('Bundle, signature and profile identifiers differ')
    return {'bundle': info['CFBundleIdentifier'], 'version': info.get('CFBundleShortVersionString'),
            'build': info.get('CFBundleVersion'), 'minimumOS': info.get('MinimumOSVersion'),
            'architectures': arches, 'signatureVerified': True, 'profileExpiry': expiry.isoformat(),
            'provisionedDeviceCount': len(profile.get('ProvisionedDevices', [])),
            'allDevices': bool(profile.get('ProvisionsAllDevices')),
            'deviceInstallationTested': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='banana-ios-verify-') as temporary:
        if args.artifact.suffix.lower() == '.ipa':
            root = Path(temporary)
            with zipfile.ZipFile(args.artifact) as archive:
                for item in archive.infolist():
                    path = Path(item.filename)
                    if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(item.external_attr >> 16):
                        raise ValueError('Unsafe IPA archive member')
                archive.extractall(root)
            apps = [p for p in (root / 'Payload').glob('*.app') if p.is_dir()]
        else:
            apps = [p for p in (args.artifact / 'Products' / 'Applications').glob('*.app') if p.is_dir()]
        if len(apps) != 1:
            raise ValueError('Expected exactly one real application')
        report = verify(apps[0])
        if args.report:
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print('IOS_SIGNATURE_AND_PROFILE_PASS', report['bundle'], report['version'])


if __name__ == '__main__':
    main()
