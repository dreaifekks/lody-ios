"""The connection page shows the hub and each computer with how it answers, from a fixture service."""
import json
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])

def spoken(item):
    return ' '.join([str(item.get(key) or '') for key in ('AXLabel', 'AXValue')] + [spoken(child) for child in item.get('children') or []])

def label(identifier):
    return spoken(ui.element(identifier))

def answered(identifier, text):
    return ui.wait(lambda items: next((item for item in items if item.get('AXUniqueId') == identifier and text in spoken(item)), None), f'{identifier} did not show {text}')

answered('hub', catalog.text('settings.connection.latency', ms=12))
answered('machine:nuc', catalog.text('settings.connection.latency', ms=18))
answered('machine:mac', catalog.text('settings.connection.latency', ms=227))
answered('machine:n100', catalog.text('settings.connection.machineOffline'))
nuc = label('machine:nuc')
assert 'NUC' in nuc and 'homenucserver' in nuc, 'The short name leads and the machine name follows'
assert catalog.text('settings.connection.offline') in label('sync')
ui.capture('connection')

# An interrupted sync is retried from its row.
ui.axe('tap', '--id', 'sync', '--post-delay', '.5')
answered('sync', catalog.text('settings.connection.live'))
ui.capture('resynced')
print(json.dumps({'hubMs': 12, 'online': ['nuc', 'mac'], 'offline': ['n100'], 'resynced': True}))
