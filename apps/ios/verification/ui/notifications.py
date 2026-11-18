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
text('Sample activity started')
ui.axe('button', 'home')
island = ui.wait(lambda items: next((i for i in items if i.get('AXUniqueId') == 'regular.view'
                                    and '1' in (i.get('AXLabel') or '')), None), 'Compact activity count missing')
frame = island['frame']
ui.screenshot('live-activity-compact')
ui.axe('touch', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--down', '--up', '--delay', '1')
text('Review the release notes')
ui.screenshot('live-activity-expanded')
subprocess.run(['xcrun', 'simctl', 'launch', ui.udid, 'ai.lody.mobile'], check=True, timeout=30)
touch(ui.element('activity-demo'))
text('Sample activity ended')
