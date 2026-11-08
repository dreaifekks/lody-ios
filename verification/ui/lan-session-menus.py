"""LAN project rows keep local context previews, hide sharing, and archive removes terminal."""
import json
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])
ui.element('lan-menu-active')


def hold(identifier):
    f = ui.element(identifier)['frame']
    ui.axe('touch', '-x', str(f['x'] + f['width'] / 2), '-y', str(f['y'] + f['height'] / 2), '--down', '--up', '--delay', '.9')
    ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('session.action.rename') for i in items), 'Missing native session menu')


def dismiss():
    ui.axe('tap', '-x', '12', '-y', '130', '--post-delay', '.5')


for session in ['lan-menu-active', 'lan-menu-archived']:
    hold(session)
    ui.wait(lambda items: any('Cached LAN answer stays available offline.' in (i.get('AXLabel') or '') for i in items), 'Context preview did not read the LAN session cache')
    assert not any(i.get('AXLabel') == catalog.text('session.action.share') for i in ui.state()), 'LAN project menu exposed Cloud sharing'
    ui.capture(session + '-preview')
    dismiss()
ui.axe('tap', '--id', 'lan-menu-active-tools')
ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('terminal.menu') for i in items), 'Active LAN session lost its terminal')
ui.capture('active-terminal-entry')
dismiss()
ui.axe('tap', '--id', 'lan-menu-archived-tools')
ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('session.action.rename') for i in items), 'Archived menu did not open')
assert not any(i.get('AXLabel') == catalog.text('terminal.menu') for i in ui.state()), 'Archived LAN session exposed terminal'
ui.capture('archived-no-terminal')
print(json.dumps({'cachedPreviews': True, 'lanSharingHidden': True, 'activeTerminal': True, 'archivedTerminalHidden': True}))
