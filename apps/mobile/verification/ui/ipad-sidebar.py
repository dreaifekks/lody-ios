"""iPad Sidebar layout and relocated actions, using offline Home fixtures."""
import sys
import catalog
from driver import UI

ui = UI(sys.argv[1], sys.argv[2])


def labeled(label):
    return ui.wait(lambda items: next((item for item in items if item.get('AXLabel') == label), None), f'Missing {label}')


def tap_label(label):
    frame = labeled(label)['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--tap-style', 'physical', '--post-delay', '.6')


ui.element('ipad-detail-placeholder')
ui.element('ipad-inbox-list')
panel = ui.element('ipad-panel')['frame']
search = ui.wait(lambda items: next((item for item in items if item.get('subrole') == 'AXSearchField'), None), 'Missing system search')['frame']
settings = labeled(catalog.text('tabs.settings'))['frame']
view_menu = labeled(catalog.text('inbox.settings.section.view'))['frame']
workspace_item = ui.wait(lambda items: next((item for item in items if (item.get('AXLabel') or '').startswith('Switch workspace,')), None), 'Missing workspace switch')
workspace = workspace_item['frame']
fab = labeled(catalog.text('tabs.newSession'))['frame']
assert workspace['y'] + workspace['height'] <= search['y'] < panel['y'] + 150
assert workspace['x'] < panel['x'] + 40
assert workspace['x'] + workspace['width'] <= panel['x'] + panel['width'] - 8
assert view_menu['x'] < settings['x'] < fab['x']
for action in (settings, view_menu):
    assert action['y'] > panel['y'] + panel['height'] - 110
    assert abs(action['y'] - fab['y']) < 10
assert workspace['width'] >= 44 and workspace['height'] >= 44
assert fab['width'] >= 44 and fab['height'] >= 44
assert fab['x'] > panel['x'] + panel['width'] - 100
assert fab['y'] > panel['y'] + panel['height'] - 110
ui.capture('sidebar-glass-fab')

tap_label(catalog.text('inbox.settings.section.view'))
for key in ('view.projects', 'view.machines', 'view.activity', 'view.chat', 'sort.name', 'sort.activity', 'sort.urgency'):
    labeled(catalog.text(f'inbox.settings.{key}'))
ui.capture('sidebar-view-menu')
tap_label(catalog.text('inbox.settings.view.machines'))
def button(identifier):
    # An outline disclosure shares its row's identifier; the row itself is the button.
    return ui.wait(lambda items: next((i for i in items if i.get('AXUniqueId') == identifier and i.get('type') == 'Button'), None), f'Missing {identifier}')


machine = button('machine:ui')['frame']
project = button('toggle:ui:local:lody')['frame']
# The machine title heads its project outline without a section gap.
assert machine['y'] + machine['height'] <= project['y'] < machine['y'] + machine['height'] + 12
ui.capture('sidebar-machines')
# Tapping the machine title collapses its projects; tapping again restores them.
ui.axe('tap', '-x', str(machine['x'] + machine['width'] / 2), '-y', str(machine['y'] + machine['height'] / 2), '--tap-style', 'physical', '--post-delay', '.6')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'toggle:ui:local:lody' and item.get('type') == 'Button' for item in items), 'Collapsed machine kept its projects')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'machine:ui' and i.get('AXValue') == catalog.text('native.list.collapsed') for i in items), 'Machine title still reads expanded')
ui.capture('sidebar-machine-collapsed')
machine = button('machine:ui')['frame']
ui.axe('tap', '-x', str(machine['x'] + machine['width'] / 2), '-y', str(machine['y'] + machine['height'] / 2), '--tap-style', 'physical', '--post-delay', '.6')
button('toggle:ui:local:lody')
tap_label(catalog.text('inbox.settings.section.view'))
tap_label(catalog.text('inbox.settings.view.activity'))
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'machine:ui' for item in items), 'Activity view retained the machine title')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'toggle:ui:local:lody' for item in items), 'Activity view retained the project outline')
tap_label(catalog.text('inbox.settings.section.view'))
tap_label(catalog.text('inbox.settings.view.projects'))
ui.element('toggle:ui:local:lody')
tap_label(catalog.text('tabs.settings'))
close_settings = catalog.text('accessibility.closeSheet', title=catalog.text('tabs.settings'))
labeled(close_settings)
ui.capture('sidebar-settings')
tap_label(close_settings)
ui.element('ipad-inbox-list')

tap_label(workspace_item['AXLabel'])
labeled(catalog.text('workspace.edit.action'))
ui.capture('workspace-menu')
tap_label('另一个工作区')
ui.element('ipad-detail-placeholder')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'ui-design' for item in items), 'Old workspace content survived switching')
ui.capture('workspace-switched')
tap_label(catalog.workspace_switch('另一个工作区', count=0, total=0))
tap_label('我的超长工作区名称不能折行')
ui.element('ui-design')
tap_label(catalog.text('tabs.newSession'))
ui.element('create-session-input')
ui.capture('new-session')
tap_label(catalog.text('accessibility.closeSheet', title=catalog.text('create.title')))
ui.element('ipad-inbox-list')
print('PASS: Workspace at the top; view/settings at the bottom; workspace, view, settings and new-session actions remain usable.')
