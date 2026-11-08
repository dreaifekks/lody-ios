"""By Machine restores mode 3, catalog ownership, aliases and persisted folds in both native hosts."""
import sys
from driver import UI
import catalog
import pad

ui = UI(sys.argv[1], sys.argv[2])


def ids(items):
    return {item.get('AXUniqueId') for item in items}


def labeled(label):
    return ui.wait(lambda items: next((item for item in items if item.get('AXLabel') == label), None), f'Missing {label}')


def assert_expansion(identifier, opened):
    key = 'native.list.expanded' if opened else 'native.list.collapsed'
    assert ui.element(identifier).get('AXValue') == catalog.text(key), (identifier, ui.element(identifier))


def choose(key):
    ui.axe('tap', '--label', catalog.text('inbox.settings.section.view'), '--post-delay', '.4')
    labeled(catalog.text('inbox.settings.' + key))
    ui.axe('tap', '--label', catalog.text('inbox.settings.' + key), '--post-delay', '.5')


if any(item.get('AXUniqueId') == 'ipad-home' for item in ui.state()):
    pad.show_list(ui)

# The fixture saves the old value 3 before InboxController is constructed.
alpha = ui.element('machine:machine-a')
zulu = ui.element('machine:machine-z')
assert alpha['frame']['y'] < zulu['frame']['y'], 'Machine aliases determine name order, not project names'
assert 'Alpha Mac' in (alpha.get('AXLabel') or '') and '2' in (alpha.get('AXLabel') or ''), alpha
assert 'Zulu Studio' in (zulu.get('AXLabel') or '') and '1' in (zulu.get('AXLabel') or ''), zulu
assert alpha['frame']['height'] >= 44, ('Machine headers retain native touch targets', alpha)
for identifier in ('toggle:machine-boreal', 'toggle:machine-cedar', 'toggle:machine-atlas'):
    ui.element(identifier)
assert 'project-bar' not in ids(ui.state()), 'By Machine has no project filter bar'
assert_expansion('machine:machine-a', True)
assert_expansion('machine:machine-z', True)
ui.capture('machines-name')

ui.axe('tap', '--id', 'machine:machine-a', '--post-delay', '.5')
ui.wait(lambda items: 'toggle:machine-boreal' not in ids(items) and 'toggle:machine-cedar' not in ids(items), 'A machine title folds all of its projects')
ui.element('toggle:machine-atlas')
assert_expansion('machine:machine-a', False)
ui.capture('machine-folded')
ui.axe('tap', '--id', 'machine:machine-z', '--post-delay', '.5')
ui.wait(lambda items: 'toggle:machine-atlas' not in ids(items), 'Second machine did not fold')
ui.element('machine:machine-a')
ui.element('machine:machine-z')
assert not any(item.get('AXLabel') == catalog.text('sessions.placeholder.empty') for item in ui.state()), 'Collapsed machine headings are still content'
assert_expansion('machine:machine-a', False)
assert_expansion('machine:machine-z', False)
ui.capture('all-machines-folded')

choose('view.activity')
ui.wait(lambda items: 'machine:machine-a' not in ids(items), 'Activity view retained machine groups')
choose('view.machines')
ui.element('machine:machine-a')
assert 'toggle:machine-boreal' not in ids(ui.state()), 'Changing views lost the persisted machine fold'
ui.axe('tap', '--id', 'machine:machine-a', '--post-delay', '.5')
ui.element('toggle:machine-boreal')
ui.element('toggle:machine-cedar')
ui.axe('tap', '--id', 'machine:machine-z', '--post-delay', '.5')
ui.element('toggle:machine-atlas')

choose('sort.activity')
alpha, zulu = ui.element('machine:machine-a'), ui.element('machine:machine-z')
assert zulu['frame']['y'] < alpha['frame']['y'], 'Activity orders machines by their first project'
assert_expansion('machine:machine-a', True)
assert_expansion('machine:machine-z', True)
ui.capture('machines-activity')
choose('sort.urgency')
alpha, zulu = ui.element('machine:machine-a'), ui.element('machine:machine-z')
assert alpha['frame']['y'] < zulu['frame']['y'], 'Urgency orders machines by their first project'
assert_expansion('machine:machine-a', True)
assert_expansion('machine:machine-z', True)
ui.capture('machines-urgency')

# A6: the Home host uses exactly the LAN-local cached transcript preview.
frame = ui.element('boreal-session')['frame']
ui.axe('touch', '-x', str(frame['x'] + min(120, frame['width'] / 2)),
       '-y', str(frame['y'] + frame['height'] / 2), '--down', '--up', '--delay', '1.2')
ui.wait(lambda items: any(item.get('AXLabel') == 'LAN cached preview' for item in items), 'LAN Home long-press lost its cached preview')
ui.wait(lambda items: any(item.get('AXLabel') == 'Local history is available.' for item in items), 'LAN Home preview lost its assistant answer')
assert not any(item.get('AXLabel') == catalog.text('session.action.share') for item in ui.state()), 'LAN Home must hide Cloud sharing'
ui.capture('lan-home-session-preview')
print('PASS: mode 3, machine aliases/counts, native folds, persisted expansion, activity/urgency order and cached LAN preview')
