"""Verify Home bottom new-chat button stays enabled across syncing/offline, unknown, e2ee and live states."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def create_button():
    return ui.element('home-new-session')


def assert_create_enabled(label):
    button = create_button()
    assert button.get('enabled', False) is True, (f'Create button disabled in {label}', button)
    assert button.get('AXLabel') == catalog.text('tabs.newSession'), button
    return button


def tap_create():
    frame = assert_create_enabled('tap')['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.8')


def close_create_page():
    back = ui.wait(
        lambda items: next((i for i in items if i.get('type') == 'Button' and i.get('AXLabel') == catalog.text('common.back')), None),
        'Missing Back button on pushed create page',
    )
    frame = back['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.8')
    ui.element('home-new-session')


# 1. Syncing + offline + no online machines (plaintext workspace): button stays enabled and opens CreateSession.
ui.open_case('home-fixture-state-syncing')
ui.element('home-sync-status')
assert_create_enabled('syncing-offline')
ui.capture('home-create-syncing')
tap_create()
ui.element('create-session-input')
ui.capture('create-opened-while-syncing')
close_create_page()

# 2. Unconfirmed workspace encryption mode (.unknown): button stays enabled (never gray), tap stays on Home with standard feedback.
ui.open_case('home-fixture-state-unknown')
ui.wait(
    lambda items: any('Unconfirmed Workspace' in (i.get('AXLabel') or '') for i in items),
    'Missing unconfirmed workspace capsule',
)
assert_create_enabled('unknown-mode')
ui.capture('home-create-unknown')
tap_create()
assert not any(i.get('AXUniqueId') == 'create-session-input' for i in ui.state()), 'Unknown workspace must not open plaintext creation'
ui.capture('home-create-unknown-tapped')

# 3. Encrypted workspace (.e2ee): button stays enabled (never gray), tap stays on Home with standard E2EE feedback.
ui.open_case('home-fixture-state-e2ee')
ui.wait(
    lambda items: any('Encrypted Workspace' in (i.get('AXLabel') or '') for i in items),
    'Missing encrypted workspace capsule',
)
assert_create_enabled('e2ee-mode')
ui.capture('home-create-e2ee')
tap_create()
assert not any(i.get('AXUniqueId') == 'create-session-input' for i in ui.state()), 'E2EE workspace must not open plaintext creation'
ui.capture('home-create-e2ee-tapped')

# 4. Live plaintext workspace: button stays enabled, normal style, and opens CreateSession cleanly.
ui.open_case('home-fixture-state-live')
ui.element('ui-design')
assert_create_enabled('live-normal')
ui.capture('home-create-live')
tap_create()
ui.element('create-session-input')
ui.capture('create-opened-live')
close_create_page()

print('PASS: Home create button stays enabled across syncing/offline, unknown, e2ee and live states, opens standard CreateSession when admitted, and enforces workspace boundaries.')
