"""LAN catalog entry, native picker, fullscreen, composer chip and floating preview."""
import sys
import re
from driver import UI
import catalog

ui = UI(*sys.argv[1:])


def menu():
    ui.element('session-preview-probe')
    ui.axe('tap', '--label', catalog.text('common.more'), '--post-delay', '.4')


def tap_simulator():
    item = ui.wait(lambda items: next((i for i in items
        if (i.get('AXLabel') or '').startswith(catalog.text('simulator.menu'))), None), 'LAN simulator entry missing')
    f = item['frame']
    ui.axe('tap', '-x', str(f['x'] + f['width'] / 2), '-y', str(f['y'] + f['height'] / 2), '--post-delay', '.5')


def stream():
    def decoded(items):
        for item in items:
            if item.get('AXUniqueId') != 'simulator-stream':
                continue
            match = re.fullmatch(r'stream:([^,]+),connections:(\d+),active:(\d+),frame:(\d+)', item.get('AXValue') or '')
            if match and int(match[4]) > 0:
                return match
        return None
    match = ui.wait(decoded, 'LAN viewer did not decode')
    assert (match[2], match[3]) == ('1', '1'), match[0]
    return match[1]


menu()
ui.capture('lan-menu')
tap_simulator()
ui.wait(lambda items: next((i for i in items if (i.get('AXLabel') or '').startswith('Fixture Phone')), None), 'Missing LAN device row')
ui.capture('lan-picker')
row = ui.wait(lambda items: next((i for i in items if (i.get('AXLabel') or '').startswith('Fixture Phone')), None), 'Missing selectable device')
f = row['frame']
ui.axe('tap', '-x', str(f['x'] + f['width'] / 2), '-y', str(f['y'] + f['height'] / 2), '--post-delay', '.8')
identity = stream()
ui.capture('lan-fullscreen')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.8')
ui.element('simulator-preview-expand')
ui.wait(lambda items: next((i for i in items if (i.get('AXLabel') or '') == catalog.text('simulator.chip.open', target='Fixture Phone')), None), 'Missing LAN composer chip')
ui.capture('lan-floating-chip')
before = ui.element('session-preview-probe').get('AXValue') or ''
ui.axe('tap', '--id', 'session-preview', '--post-delay', '.7')
assert stream() == identity, 'LAN chip recreated the shared decoder'
ui.capture('lan-chip-opened')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.8')
ui.element('simulator-preview-expand')
assert stream() == identity, 'LAN chip return recreated the shared decoder'
after = ui.element('session-preview-probe').get('AXValue') or ''
for command in ('simulator-status', 'simulator-list'):
    assert before.split(',').count(command) == after.split(',').count(command), 'Ready chip performed a control RPC'
ui.axe('tap', '--id', 'simulator-preview-close', '--post-delay', '.4')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'simulator-preview-expand' for i in items), 'Floating close failed')
# Reopen through the same production menu, retaining the member operation.
menu()
tap_simulator()
stream()
ui.axe('tap', '--label', catalog.text('common.more'), '--post-delay', '.4')
ui.axe('tap', '--label', catalog.text('simulator.stop'), '--post-delay', '.6')
ui.element('session-input')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'simulator-preview-expand' for i in items), 'Stop retained preview')
ui.capture('lan-stopped')
print('PASS: LAN entry uses LAN catalog; native picker, decoded viewer, floating preview, composer chip, reopen and stop.')
