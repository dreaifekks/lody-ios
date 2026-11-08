"""Real Settings → LAN account → Connection, with scripted hub/RPC boundaries."""
import sys
from driver import UI
import catalog
ui = UI(sys.argv[1], sys.argv[2])
ui.wait(lambda items: any(i.get('AXUniqueId') == 'account' and '18 ms' in str(i) for i in items), 'Settings account subtitle includes hub latency')
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
