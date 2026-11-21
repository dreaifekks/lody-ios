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
assert not any(item.get('AXUniqueId') in {'later-a', 'settled-a'} for item in ui.state())
ui.capture('collapsed')

for key, evidence in [('home.status.later', 'later-undo'), ('home.status.settle', 'settle-undo')]:
    ui.axe('touch', *center(ui.element('focus-a')), '--down', '--up', '--delay', '.85')
    ui.axe('tap', *center(menu_action(key)))
    if key == 'home.status.later':
        for preset in ('oneHour', 'laterToday', 'tomorrowMorning', 'nextWeek'):
            key = f'home.status.later.{preset}'
            assert menu_action(key)['AXLabel'].startswith(f'{catalog.text(key)}, '), 'Missing resolved preset time'
        ui.capture('later-presets')
        ui.axe('tap', *center(menu_action('home.status.later.oneHour')))
    ui.wait(lambda items: not any(item.get('AXUniqueId') == 'focus-a' for item in items),
            'The conversation remained in Focus')
    undo = catalog.text('home.status.toast.undo')
    ui.wait(lambda items: any(item.get('AXLabel') == undo for item in items), 'Missing Undo')
    ui.screenshot(evidence)
    ui.axe('tap', '--label', undo)
    ui.element('focus-a')

ui.capture('restored-focus')


def check_first(first_id, second_id):
    def ordered(items):
        by_id = {i['AXUniqueId']: i for i in items if i.get('AXLabel') in {first_id, second_id}
                 and i.get('AXUniqueId') == i['AXLabel']}
        if not {first_id, second_id} <= by_id.keys():
            return False
        first, second = by_id[first_id], by_id[second_id]
        return (first['frame']['y'] < second['frame']['y']
                and catalog.text('home.status.moveDown') in first['custom_actions']
                and catalog.text('home.status.moveUp') not in first['custom_actions']
                and catalog.text('home.status.moveUp') in second['custom_actions'])
    ui.wait(ordered, f'Expected {first_id} first and refreshed accessibility actions')


ui.axe('touch', *center(ui.element('focus-woken')), '--down', '--up', '--delay', '.85')
ui.axe('tap', *center(menu_action('home.status.moveToTop')))
check_first('focus-woken', 'focus-a')
ui.open_case('status-catalog-repeat')
check_first('focus-woken', 'focus-a')
ui.capture('held-move')
ui.open_case('status-catalog-readback')
check_first('focus-woken', 'focus-a')
ui.capture('read-back-move')
print('PASS: Later and Settled start collapsed, Later shows presets on first use, and both actions undo. '
      'The moved row keeps its place through catalog readback and the accessibility actions follow the new order.')
