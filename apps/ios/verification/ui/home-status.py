"""Later, Undo and held moves on the offline Home Status list."""
import sys

import catalog
from driver import UI

ui = UI(*sys.argv[1:])


def center(node):
    frame = node['frame']
    return ('-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2))


def menu_action(key):
    label = catalog.text(key)
    def matches(item):
        spoken = item.get('AXLabel') or ''
        return (item.get('type') == 'Button' and not item.get('AXUniqueId')
                and (spoken == label or spoken.startswith(f'{label}, ')))
    return ui.wait(lambda items: next((item for item in items if matches(item)), None), f'Missing menu action {label}')


for section in ('focus', 'later', 'settled'):
    ui.element(f'label:{section}')
assert not any(item.get('AXUniqueId') in {'later-a', 'later-child', 'settled-a'} for item in ui.state())
ui.capture('collapsed')
# An empty pin section's label (with its menu) and a collapsed tier's label (without) are spaced alike.
pitch = lambda a, b: ui.element(b)['frame']['y'] - ui.element(a)['frame']['y']
assert abs(pitch('label:pinned:review', 'label:focus') - pitch('label:later', 'label:settled')) < 1, 'Group labels are spaced differently'
# The label menu keeps its 44 pt target beyond the compact label.
menu = ui.element('label-menu:pinned:review')['frame']
ui.axe('tap', '-x', str(menu['x'] + menu['width'] / 2), '-y', str(menu['y'] + 2))
new_section = catalog.text('home.pins.newSection')
ui.axe('tap', *center(ui.wait(lambda items: next((i for i in items if i.get('AXLabel') == new_section and i.get('type') == 'Button'), None), 'The label menu did not open')))
ui.axe('tap', '--label', catalog.text('common.cancel'))
ui.axe('tap', *center(ui.element('label:later')))
child_return = ui.element('later-child')['AXValue']
ui.axe('tap', *center(ui.element('label:later')))

for key, command in [('home.status.later', 'snooze'), ('home.status.settle', 'settle')]:
    evidence = f'{command}-undo'
    ui.axe('touch', *center(ui.element('focus-a')), '--down', '--up', '--delay', '.85')
    ui.axe('tap', *center(menu_action(key)))
    if key == 'home.status.later':
        for preset in ('oneHour', 'laterToday', 'tomorrowMorning', 'nextWeek'):
            key = f'home.status.later.{preset}'
            assert menu_action(key)['AXLabel'].startswith(f'{catalog.text(key)}, '), 'Missing resolved preset time'
        ui.capture('later-presets')
        ui.axe('tap', *center(menu_action('home.status.later.oneHour')))
    ui.axe('tap', '--label', catalog.text(f'home.status.opened.{command}.all'))
    undo = catalog.text('home.status.toast.undo')

    def undo_button(items):
        if any(item.get('AXUniqueId') == 'focus-a' for item in items):
            return None
        return next((item for item in items if item.get('AXLabel') == undo and item.get('type') == 'Button'), None)

    ui.wait(undo_button, 'The opener should leave Focus and show Undo')
    ui.axe('tap', '--label', undo, '--tap-style', 'simulator')
    ui.element('focus-a')
    ui.axe('tap', *center(ui.element('label:later')))
    assert ui.element('later-child')['AXValue'] == child_return, 'Undo did not restore the child’s original Later time'
    ui.capture(f'{evidence}-restored-child')
    ui.axe('tap', *center(ui.element('label:later')))

ui.capture('restored-focus')


def check_first(first_id, second_id):
    def ordered(items):
        by_id = {i['AXUniqueId']: i for i in items if i.get('AXLabel') in {first_id, second_id}
                 and i.get('AXUniqueId') == i['AXLabel']}
        if not {first_id, second_id} <= by_id.keys():
            return False
        first, second = by_id[first_id], by_id[second_id]
        for row_id in (first_id, second_id):
            assert sum(i.get('AXUniqueId') == row_id for i in items) == 1, (
                f'Expected one accessibility button for {row_id}')
        return (first['frame']['y'] < second['frame']['y']
                and catalog.text('home.status.moveDown') in first['custom_actions']
                and catalog.text('home.status.moveUp') not in first['custom_actions']
                and catalog.text('home.status.moveUp') in second['custom_actions']
                and catalog.text('home.status.moveDown') in second['custom_actions'])
    ui.wait(ordered, f'Expected {first_id} first and refreshed accessibility actions')


ui.axe('touch', *center(ui.element('focus-woken')), '--down', '--up', '--delay', '.85')
ui.axe('tap', *center(menu_action('home.status.moveToTop')))
ui.open_case('status-catalog-repeat')
check_first('focus-woken', 'focus-a')
ui.open_case('status-catalog-readback')
check_first('focus-woken', 'focus-a')
ui.capture('read-back-move')
ui.axe('tap', *center(ui.element('label:settled')))
ui.axe('touch', *center(ui.element('settled-a')), '--down', '--up', '--delay', '.85')
menu_action('home.status.later')
ui.capture('settled-offers-later')
print('PASS: Later and Settled start collapsed, Later shows presets on first use, and both actions restore the opener to Focus and the child to its original Later time. '
      'The moved row keeps its place through catalog readback and the accessibility actions follow the new order.')
