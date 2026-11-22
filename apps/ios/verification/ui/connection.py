"""Real Settings → LAN account → Connection, with scripted hub/RPC boundaries."""
import sys
import re
import subprocess
from driver import BUNDLE_ID
from driver import UI
import catalog
ui = UI(sys.argv[1], sys.argv[2])
ui.wait(lambda items: any(i.get('AXUniqueId') == 'account' and 'ms' in str(i) for i in items), 'Settings account subtitle includes hub latency')
ui.capture('settings-hub-latency')
ui.axe('tap', '--id', 'account')
ui.element('hub')
ui.capture('account-hub')
ui.axe('tap', '--id', 'hub')
ui.element('retry')
ui.capture('machine-list-error')
ui.axe('tap', '--id', 'retry')
for id, text in [('machine:online', 'Online'), ('machine:offline', 'Offline')]:
    item = ui.element(id)
    assert text in str(item), item
    assert 'v0.109.0' in str(item), item
# Online ping fails and offline ping succeeds: neither overrides heartbeat state.
ui.wait(lambda items: any(i.get('AXUniqueId') == 'machine:offline' and 'Offline' in str(i) for i in items), 'Heartbeat remains authoritative')
ui.capture('computers-heartbeat')
ui.axe('tap', '--id', 'sync')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'sync' and catalog.text('settings.connection.live') in str(i) for i in items), 'Resync updates stream health')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'presence' and 'Live' in str(i) for i in items), 'Presence health is live')
ui.capture('connection-live')

# A failed refresh with cached machines keeps the list, without a new retry row.
assert not any(i.get('AXUniqueId') == 'retry' for i in ui.state())


def hub_value(items):
    node = next((i for i in reversed(items) if i.get('AXUniqueId') == 'hub'), None)
    match = re.fullmatch(r'(\d+) ms', str((node or {}).get('AXValue') or ''))
    return int(match.group(1)) if match else -1


# Observe one periodic measurement, then foreground well before its next 10s tick.
old = hub_value(ui.state())
ui.wait(lambda items: hub_value(items) > old, 'Periodic hub measurement did not advance', timeout=14)
old = hub_value(ui.state())
ui.axe('button', 'home')
subprocess.run(['xcrun', 'simctl', 'launch', ui.udid, BUNDLE_ID], check=True, capture_output=True, timeout=30)
ui.invalidate_axe()
ui.wait(lambda items: hub_value(items) > old, 'Foreground did not immediately remeasure hub latency', timeout=5)
ui.capture('connection-foreground-remeasured')
