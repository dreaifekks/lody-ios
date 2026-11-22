"""Docked @ and / suggestions give up rows before the conversation composer reaches the page header."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])
field = 'session-input'


def by_id(items, identifier):
    return next((i['frame'] for i in items if i.get('AXUniqueId') == identifier), None)


def key(label):
    """Software keys: hardware-keyboard events would hide the keyboard this check measures."""
    def find(items):
        return next((i for i in items if (i.get('AXLabel') or '').casefold() == label and i['frame']['height'] > 20), None)
    if not find(ui.state()):
        layer = next(i for i in ui.state() if i.get('AXLabel') in ('numbers', 'letters') and i['frame']['height'] > 20)
        ui.axe('tap', '--label', layer['AXLabel'], '--tap-style', 'physical', '--post-delay', '.3')
    frame = ui.wait(find, 'Software key missing: ' + label)['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--tap-style', 'physical', '--post-delay', '.3')


def open_conversation():
    ui.element('home-chat-list')
    try:
        ui.element('ui-design', timeout=5)
    except AssertionError:
        # Fixture chats belong to teammates; a fresh device starts on Mine.
        ui.axe('tap', '--label', catalog.text('inbox.settings.section.view'), '--post-delay', '.8')
        label = catalog.text('home.scope.team')
        option = ui.wait(lambda items: min((i for i in items if i.get('AXLabel') == label), key=lambda i: i['frame']['y'], default=None), 'Missing team scope')['frame']
        ui.axe('tap', '-x', str(option['x'] + option['width'] / 2), '-y', str(option['y'] + option['height'] / 2), '--post-delay', '.8')
    ui.axe('tap', '--id', 'ui-design', '--post-delay', '1.2')
    ui.axe('tap', '--id', field, '--post-delay', '.6')
    ui.wait_for_keyboard(field)


def docked(item, name):
    header = ui.element('BackButton')['frame']
    limit = header['y'] + header['height']
    samples = []

    def settled(items):
        panel, grabber, keyboard = by_id(items, 'mention-panel'), by_id(items, 'session-grabber'), ui.visible_keyboard(items)
        if not panel or not grabber or not keyboard or not by_id(items, item):
            return None
        geometry = (panel['y'], panel['height'], grabber['y'])
        samples[:] = samples[-2:] + [geometry]
        if len(samples) < 3 or len(set(samples)) > 1:
            return None
        return panel, grabber, keyboard

    panel, grabber, keyboard = ui.wait(settled, 'Docked suggestions did not settle: ' + name)
    assert grabber['y'] >= limit - 0.5, f'{name}: composer top {grabber["y"]} reached the page header ending at {limit}'
    assert panel['height'] >= 120 - 0.5, f'{name}: suggestions shrank below their minimum ({panel["height"]})'
    assert panel['y'] + panel['height'] <= keyboard['y'] + 1, f'{name}: suggestions fall behind the keyboard'
    status = by_id(ui.state(), 'chat-overlay-status')
    assert not status or status['y'] + status['height'] <= grabber['y'], f'{name}: the connection status covers the page header'
    ui.capture(name)
    return panel


ui.capture('resting')
open_conversation()
key('/')
docked('mention-item:compact', 'slash')
key('delete')
for line in 'abcde':
    key(line)
    key('return')
key('@')
mention = docked('mention-item:role', 'multiline-mention')
assert mention['height'] < 280, 'A long draft kept the full suggestion height and pushed the composer up'
print('PASS: @ and / suggestions shrink to keep the conversation composer below its header, above the keyboard')
