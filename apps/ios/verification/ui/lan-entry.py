"""Offline Join LAN failure/retry and Cloud-entry isolation. Never contacts a hub."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])
join = ui.element('onboarding-join-lan')
assert join['frame']['height'] >= 44
ui.axe('tap', '--id', 'onboarding-join-lan')
ui.element('join-lan-form')
invite = ui.element('lan-invite')
assert invite['frame']['height'] >= 44
ui.axe('tap', '--id', 'lan-invite')
# Secure input intentionally does not expose its value through accessibility.
ui.axe('type', 'lody-lan://offline-fixture@offline.invalid')
ui.axe('tap', '--id', 'lan-join-submit')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'lan-join-error' and i.get('AXLabel') == catalog.text('lan.join.failed') for i in items), 'Join failure must remain actionable')
ui.capture('join-failed')
ui.axe('tap', '--id', 'lan-join-submit')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'onboarding-sheet' for i in items), 'Successful join must close onboarding')
ui.open_case('settings-baseline-lan')
ui.element('settings-baseline-ready')
# Visit every part of the native list with UIKit pan gestures.
for index in range(4):
    items = ui.state()
    forbidden = {'workspace-general', 'prompt-shortcuts', 'project-visibility', 'github-settings', 'ai-usage', 'published-shares'}
    assert not forbidden.intersection(i.get('AXUniqueId') for i in items), items
    ui.capture(f'lan-settings-{index}')
    ui.axe('drag', '--start-x', '200', '--start-y', '620', '--end-x', '200', '--end-y', '280', '--duration', '.4')

# Both app hosts use the real shared composer with an injected LAN policy.
for scene, input_id in [('session-preview-lan', 'session-input'), ('create-lan', 'create-session-input')]:
    ui.open_case(scene)
    ui.element(input_id)
    ui.axe('tap', '--id', input_id)
    ui.axe('type', 'Offline LAN text draft')
    assert not any(i.get('AXUniqueId') == 'session-attach' for i in ui.state()), scene
    assert 'Offline LAN text draft' in (ui.element(input_id).get('AXValue') or ''), scene
    ui.capture(scene)
    back = [i for i in ui.state() if i.get('AXUniqueId') == 'BackButton']
    if back:
        ui.axe('tap', '--id', 'BackButton')
    else:
        close = next(i for i in ui.state() if i.get('AXLabel') == catalog.system('close'))
        frame = close['frame']
        ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2))
