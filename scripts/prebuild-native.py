"""Generate all application, extension and verification targets with XcodeGen."""
from pathlib import Path
import json
import os
import plistlib
import subprocess


def generate(root, environment):
    generated = root / '.generated'
    (generated / 'Lody').mkdir(parents=True, exist_ok=True)
    info = plistlib.loads((root / 'iOS/Info.plist').read_bytes())
    version = json.loads((root / 'package.json').read_text())['version']
    build = environment.get('BUILD_NUMBER', info['CFBundleVersion'])
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = build
    bundle = environment.get('LODY_BUNDLE_ID', 'app.innei.lody')
    if 'LODY_ONESIGNAL_APP_ID' in environment:
        info['LodyOneSignalAppId'] = environment['LODY_ONESIGNAL_APP_ID']
    elif bundle != 'app.innei.lody':
        info['LodyOneSignalAppId'] = ''
    (generated / 'Lody/Info.plist').write_bytes(plistlib.dumps(info))
    spec = {
        'include': ['project.yml'],
        'settings': {'base': {'MARKETING_VERSION': version, 'CURRENT_PROJECT_VERSION': build}},
    }
    for key in ('LODY_BUNDLE_ID', 'LODY_APPLE_TEAM_ID'):
        if key in environment:
            spec['settings']['base'][key] = environment[key]
    profiles = json.loads(environment.get('IOS_PROFILE_MAP', '{}'))
    if profiles:
        # Release signing is another XcodeGen input, never a post-generation project edit.
        targets = {bundle: 'Lody', f'{bundle}.share': 'LodyShare',
                   f'{bundle}.notification-service': 'LodyNotificationService',
                   f'{bundle}.live-activity': 'LodyLiveActivity'}
        if set(profiles) != set(targets):
            raise ValueError('Provisioning profiles must cover exactly the app and its three extensions')
        spec['targets'] = {targets[bundle]: {'settings': {'configs': {'Release': {
            'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': 'Apple Distribution',
            'DEVELOPMENT_TEAM': environment.get('LODY_APPLE_TEAM_ID') or environment['APPLE_TEAM_ID'], 'PROVISIONING_PROFILE_SPECIFIER': profile,
        }}}} for bundle, profile in profiles.items()}
    generated_spec = generated / 'project.json'
    generated_spec.write_text(json.dumps(spec, indent=2) + '\n')
    subprocess.run(['xcodegen', 'generate', '--spec', str(generated_spec), '--project-root', str(root), '--project', str(root)], check=True)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    subprocess.run(['/bin/bash', str(root / 'Libraries/SimulatorTransport/DataChannel/build.sh')], check=True)
    generate(root, os.environ)
