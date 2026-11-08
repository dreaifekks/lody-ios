"""Drive the production app against the owned synthetic tailnet hub, never the real LAN."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ui'))
from driver import UI, configure_app
import catalog

root = Path('.artifacts/home-tailnet')
state = json.loads((root / 'state.json').read_text())
assert state['ready'] and state['base'].startswith('http://100.122.16.85:')
udid = os.environ['LODY_VERIFY_UDID']
app = sys.argv[1]
bundle, _ = configure_app(app)
ui = UI(udid, root / 'ui')


def sim(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], capture_output=True, text=True, check=check, timeout=60)


def seen(id, text):
    return ui.wait(lambda items: next((item for item in items if item.get('AXUniqueId') == id and text in str(item)), None), f'{id}: {text}', timeout=60)


sim('terminate', udid, bundle, check=False)
sim('uninstall', udid, bundle, check=False)
sim('keychain', udid, 'reset')
sim('install', udid, app)
sim('ui', udid, 'appearance', 'light')
sim('launch', udid, bundle, '-AppleLanguages', '(en)', '-AppleLocale', 'en_US')
ui.element('onboarding-join-lan', timeout=60)
ui.axe('tap', '--id', 'onboarding-join-lan')
ui.axe('tap', '--id', 'lan-invite')
ui.axe('type', state['invite'])
ui.axe('tap', '--id', 'lan-join-submit')
# Fresh installation must ask immediately after joining, before a relaunch.
ui.wait(lambda items: any(item.get('AXLabel') == 'Allow' for item in items), 'Joining LAN did not request notification permission', timeout=60)
ui.capture('join-notification-permission')
ui.axe('tap', '--label', 'Allow')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'join-lan-form' for item in items), 'Join form stayed open', timeout=60)
ui.wait(lambda items: any('Mini Project' in (item.get('AXLabel') or '') for item in items), 'Tailnet catalog did not arrive', timeout=60)
ui.axe('tap', '--label', catalog.text('inbox.settings.section.view'))
ui.axe('tap', '--label', catalog.text('inbox.settings.view.machines'))
seen('machine:home-mini', 'Mini Online')
seen('machine:home-nuc', 'NUC Offline')
ui.capture('tailnet-by-machine')
ui.axe('tap', '--id', 'machine:home-mini')
ui.wait(lambda items: not any(i.get('AXUniqueId', '').startswith('toggle:') and 'Mini Project' in str(i) for i in items), 'Machine did not fold')
ui.capture('tailnet-machine-folded')
ui.axe('tap', '--id', 'machine:home-mini')
ui.axe('tap', '--label', catalog.text('tabs.settings'))
seen('account', 'ms')
ui.capture('tailnet-settings-latency')
ui.axe('tap', '--id', 'account')
ui.element('hub')
ui.capture('tailnet-account-hub')
ui.axe('tap', '--id', 'hub')
seen('sync', catalog.text('settings.connection.live'))
seen('presence', 'Live')
online = seen('machine:home-mini', 'ms')
offline = seen('machine:home-nuc', 'Offline')
assert 'Online' in str(online) and 'darwin' in str(online) and 'v0.109.0-lan.synthetic' in str(online), online
assert 'linux' in str(offline) and 'v0.109.0-lan.synthetic' in str(offline), offline
seen('hub', 'ms')
ui.capture('tailnet-connection-live')
sim('ui', udid, 'appearance', 'dark')
ui.capture('tailnet-connection-live-dark')
(root / 'outcome.json').write_text(json.dumps({'joined': True, 'postJoinPermission': True, 'byMachine': True, 'machineFold': True, 'hubLatency': True, 'onlineHeartbeatAndPing': True, 'offlineHeartbeat': True, 'presence': 'live', 'sync': 'live'}, indent=2) + '\n')
print('PASS: synthetic tailnet join, immediate permission, By Machine, folding, hub latency, online ping/offline heartbeat and sync health')
