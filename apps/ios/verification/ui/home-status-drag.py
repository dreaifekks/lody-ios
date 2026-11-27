"""A vertical held drag over the menu's old hit area, then a stationary long press."""
import sys

import catalog
from driver import UI


ui = UI(*sys.argv[1:])


def y(node, fraction=.5):
    frame = node['frame']
    return frame['y'] + frame['height'] * fraction


def action(title):
    return ui.wait(lambda items: next((node for node in items if node.get('type') == 'Button' and node.get('AXLabel') == title
                                        and not node.get('AXUniqueId')), None), f'Missing {title}')


def drag(row, target, fraction=.5):
    start, end = ui.element(row), ui.element(target)
    x = start['frame']['x'] + start['frame']['width'] * .26
    ui.axe('drag', '--start-x', str(x), '--start-y', str(y(start)), '--end-x', str(x),
           '--end-y', str(y(end, fraction)), '--hold', '.67', '--duration', '.85')


def ordered(*ids):
    def in_order(items):
        rows = {node.get('AXUniqueId'): y(node) for node in items if node.get('AXUniqueId') in ids}
        return len(rows) == len(ids) and all(rows[a] < rows[b] for a, b in zip(ids, ids[1:]))
    ui.wait(in_order, f'Expected row order {ids}')


header = ui.element('label:settled')
ui.axe('tap', '-x', str(header['frame']['x'] + header['frame']['width'] / 2), '-y', str(y(header)))
row = ui.element('settled-a')
width = row['frame']['width']
ui.axe('drag', '--start-x', str(width * .72), '--start-y', str(y(row)),
       '--end-x', str(width * .26), '--end-y', str(y(row)), '--duration', '.4')
action(catalog.text('session.action.archive'))
focus = action(catalog.text('home.status.focus'))
ui.capture('settled-swipe')
ui.axe('tap', '-x', str(focus['frame']['x'] + focus['frame']['width'] / 2), '-y', str(y(focus)))
ordered('label:focus', 'settled-a', 'label:later')

ordered('focus-woken', 'focus-a')
drag('focus-a', 'focus-woken', .12)
ordered('label:focus', 'focus-a', 'focus-woken')
ui.capture('focus-reordered')

drag('pin-a', 'label:pinned:review')
ordered('label:pinned:review', 'pin-a', 'label:focus')
ui.capture('pin-moved-into-empty-section')

drag('pin-a', 'focus-a', .12)
ordered('label:pinned:review', 'label:focus', 'pin-a', 'focus-a')
row = ui.element('pin-a')
ui.axe('touch', '-x', str(row['frame']['width'] * .26), '-y', str(y(row)), '--down', '--up', '--delay', '.85')
action(catalog.text('session.action.pin'))
assert not any(node.get('AXLabel') == catalog.text('session.action.unpin') for node in ui.state())
ui.capture('pinned-row-unpinned-in-focus')
ui.axe('tap', '-x', str(row['frame']['width'] - 12), '-y', str(y(row)))

row = ui.element('focus-woken')
width = row['frame']['width']
ui.axe('touch', '-x', str(width * .26), '-y', str(y(row)), '--down', '--up', '--delay', '.85')
action(catalog.text('home.status.later'))
ui.capture('stationary-row-menu')

# Dismiss the menu outside its bounds and swipe on the same list after both drags.
ui.axe('tap', '-x', str(width - 12), '-y', str(y(row)))
ui.axe('drag', '--start-x', str(width * .26), '--start-y', str(y(row)),
       '--end-x', str(width * .72), '--end-y', str(y(row)), '--duration', '.4')
pin = action(catalog.text('session.action.pin'))
ui.capture('leading-swipe')
ui.axe('tap', '-x', str(pin['frame']['x'] + pin['frame']['width'] / 2), '-y', str(y(pin)))
ordered('label:pinned', 'focus-woken', 'label:pinned:maintenance')

row = ui.element('focus-a')
ui.axe('drag', '--start-x', str(width * .72), '--start-y', str(y(row)),
       '--end-x', str(width * .26), '--end-y', str(y(row)), '--duration', '.4')
action(catalog.text('home.status.settle'))
ui.capture('trailing-swipe')
