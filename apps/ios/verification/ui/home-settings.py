"""Native Home Settings tab, Debug return and a nested settings page."""
import sys
import subprocess
from driver import UI
import catalog

ui = UI(*sys.argv[1:])
workspace_name = '我的超长工作区名称不能折行'
avatar_label = catalog.workspace_switch(workspace_name)
def home_ready():
    ui.wait(lambda items: any(i.get('AXLabel') == avatar_label for i in items), 'Missing workspace avatar')
home_ready()

ui.axe('tap', '--id', 'home-tab-settings')
ui.element('account')
subprocess.run(['xcrun', 'simctl', 'openurl', ui.udid, 'lody:///debug'], check=True, timeout=30)
ui.element('permission-native-preview')
assert not any(i.get('AXUniqueId') == 'account' for i in ui.state())
ui.capture('debug')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '1')
ui.element('account')
assert not any(i.get('AXUniqueId') == 'permission-native-preview' for i in ui.state())


ui.capture('settings')
ui.axe('tap', '--id', 'preferences')
ui.element('app-icon')
ui.capture('preferences')
ui.axe('tap', '--label', catalog.text('common.back'))
ui.element('account')
ui.axe('tap', '--id', 'home-tab-chats')
home_ready()
ui.capture('settings-closed')

print('PASS: Home switches to Settings, enters Debug and Preferences, and returns to Chats.')
