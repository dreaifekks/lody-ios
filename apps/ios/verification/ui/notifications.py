"""Exercise the production notification settings with resettable service outcomes."""
import subprocess
import sys

import catalog
from driver import UI
ui = UI(sys.argv[1], sys.argv[2])

def text(value):
    return ui.wait(lambda items: next((i for i in items if value in str(i.get('AXLabel', ''))), None), f'Missing {value}')

def touch(node):
    frame = node['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2),
           '--tap-style', 'physical', '--pre-delay', '.5', '--post-delay', '.5')


def tap(value):
    touch(text(value))


def reset():
    touch(ui.element('notification-reset'))
    text(catalog.text('notifications.hint.default'))

text(catalog.text('notifications.hint.default'))
ui.capture('permission-undetermined')
tap(catalog.text('notifications.permission.turnOn'))
text(catalog.text('notifications.changeFailed'))
text(catalog.text('notifications.hint.default'))
ui.capture('permission-failed')
tap(catalog.text('notifications.permission.turnOn'))
text(catalog.text('notifications.hint.denied'))
ui.capture('permission-denied')
tap(catalog.text('notifications.permission.settings'))
text(catalog.text('notifications.changeFailed'))
text(catalog.text('notifications.hint.denied'))
ui.capture('settings-failed')
tap(catalog.text('notifications.permission.settings'))
ui.element('notification-settings-opened')
text(catalog.text('notifications.hint.authorized'))
ui.capture('permission-authorized')
reset()
ui.capture('reset')

touch(ui.element('activity-demo'))
result = ui.wait(lambda items: next((i['AXLabel'] for i in items
                 if i.get('AXLabel') in ('Sample activity started', 'Sample activity ended')), None),
                 'Sample activity did not change state')
if result == 'Sample activity ended':
    touch(ui.element('activity-demo'))
    text('Sample activity started')

screen = next(i['frame'] for i in ui.state() if i.get('type') == 'Application')
ui.axe('button', 'home')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'Lody' and i.get('type') == 'Button' for i in items), 'Home screen missing')
ui.screenshot('live-activity-compact')
ui.axe('touch', '-x', str(screen['width'] / 2), '-y', '33', '--down', '--up', '--delay', '1')
text('Review the release notes')
ui.screenshot('live-activity-expanded')
ui.axe('button', 'home')
subprocess.run(['xcrun', 'simctl', 'launch', ui.udid, 'ai.lody.mobile'], check=True, timeout=30)
touch(ui.element('activity-demo'))
text('Sample activity ended')
