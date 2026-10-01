"""By Machine home view on the phone: a machine title heads its project cards and collapses them on tap."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def rows(items, identifier):
    # An outline disclosure shares its row's identifier; the row is the widest.
    return [i for i in items if i.get('AXUniqueId') == identifier and i['frame']['width'] > 60]


def row(identifier):
    return ui.wait(lambda items: max(rows(items, identifier), key=lambda i: i['frame']['width'], default=None), f'Missing {identifier}')


def tap_machine():
    frame = row('machine:ui')['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--tap-style', 'physical', '--post-delay', '.8')


view_label = catalog.text('inbox.settings.section.view')
ui.axe('tap', '--label', view_label, '--post-delay', '.8')
ui.axe('tap', '--label', catalog.text('inbox.settings.view.machines'), '--post-delay', '.8')
machine = row('machine:ui')
assert machine.get('AXValue') == catalog.text('native.list.expanded'), machine
assert catalog.plural('inbox.machine.projects', 2) in machine.get('AXLabel', ''), machine
project = row('toggle:ui:local:lody')['frame']
# The title sits directly above the first card of its machine.
assert machine['frame']['y'] + machine['frame']['height'] <= project['y'] < machine['frame']['y'] + machine['frame']['height'] + 24, (machine['frame'], project)
ui.capture('machines')

tap_machine()
ui.wait(lambda items: not rows(items, 'toggle:ui:local:lody') and not rows(items, 'project:ui:empty'), 'Collapsed machine kept its projects')
# The disclosure turns with the state, not only the rows.
ui.wait(lambda items: (max(rows(items, 'machine:ui'), key=lambda i: i['frame']['width'], default={}) or {}).get('AXValue') == catalog.text('native.list.collapsed'), 'Machine title still reads expanded')
# Only that machine's projects go; pinned sessions and chats stay.
row('toggle:pinned')
row('toggle:chat')
ui.capture('collapsed')

tap_machine()
row('toggle:ui:local:lody')
row('project:ui:empty')
ui.capture('restored')

# Leave the persisted view as the other Home cases expect.
ui.axe('tap', '--label', view_label, '--post-delay', '.8')
ui.axe('tap', '--label', catalog.text('inbox.settings.view.projects'), '--post-delay', '.8')
row('toggle:ui:local:lody')
print('PASS: By Machine titles its projects with a count, collapses and restores only its own projects')
