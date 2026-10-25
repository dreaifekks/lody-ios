"""On a LAN the viewer of a member's simulator rides a loopback port that lives with the
session page. The chip resumes the member's running preview and the PiP follows it back to
the chat; leaving the page ends the port and forgets the operation here, so a later visit
shows no stale PiP until the simulator is opened again and adopts the member's operation."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])
generic = catalog.text('simulator.chip.open', target=catalog.text('simulator.menu'))


def open_chip():
    chip = ui.element('session-preview')
    assert chip['AXLabel'] == generic, f'The chip still names a running preview: {chip["AXLabel"]}'
    frame = chip['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2),
           '--post-delay', '1')
    stream = ui.element('simulator-stream')
    assert stream['AXLabel'] == 'Second Simulator', 'The chip did not adopt the member preview'
    ui.wait(lambda _: ':frame:' in (ui.element('simulator-stream').get('AXValue') or '') or None,
            'The adopted preview decoded no frame')


open_chip()
ui.capture('fullscreen')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.8')
ui.element('simulator-preview-expand')
ui.capture('pip')

# Leaving the session page ends the carried port; the member keeps its operation.
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.8')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'session-input' for i in items) or None,
        'The session page did not close')
ui.open_case('simulator-preview-lan')
ui.element('session-input')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'session-preview' for i in items) or None, 'Missing simulator chip')
assert not any(i.get('AXUniqueId') == 'simulator-preview-expand' for i in ui.state()), \
    'A released viewer port still shows its PiP'
ui.capture('released')

open_chip()
ui.capture('resumed')
print('PASS: LAN chip adopts the member preview, PiP follows it, leaving the page releases it, reopening adopts it again')
