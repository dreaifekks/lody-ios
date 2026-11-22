"""Roles remain discoverable through presence startup in the real chat and create hosts."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])

def tap(identifier):
    ui.element(identifier)
    ui.axe('tap', '--id', identifier, '--post-delay', '.4')

def choose(field, host, path, token, stale_result):
    tap(field)
    tap('session-mention')
    row = ui.element('mention-item:role')
    expected_notice = 'mentions.error' if host == 'chat' else 'mentions.incomplete'
    assert catalog.text(expected_notice) in row.get('AXLabel', ''), 'Roles must show failure rather than an endless loading label'
    assert catalog.text('common.reading') not in row.get('AXLabel', ''), 'A completed Role load still says reading'
    ui.capture(host + '-roles-initial')
    tap('mention-item:role')
    ui.element('mention-picker-empty')
    ui.element('mention-picker-notice')
    ui.capture(host + '-picker-incomplete')
    # Hold explicit reload A, then let a presence-driven reload B complete.
    ui.open_case('roles-reload-hold')
    tap('mention-picker-notice')
    # A deterministic Debug action changes the same projected presence that live
    # CatalogSession publishes, without leaving or manually refreshing the picker.
    ui.open_case('roles-presence-live')
    opus = ui.element('mention-picker-item:role-reviewer@ui@opus')
    sol = ui.element('mention-picker-item:role-reviewer@ui@sol')
    remote = ui.element('mention-picker-item:role-reviewer@remote')
    assert opus['frame']['y'] < sol['frame']['y'] < remote['frame']['y'], 'Composer-machine instances must precede the remote machine'
    assert not any(i.get('AXUniqueId') == 'mention-picker-notice' for i in ui.state()), 'Live presence retained the incomplete notice'
    ui.capture(host + '-picker-live')
    # Releasing the older request must not overwrite B or reintroduce an error.
    ui.open_case('roles-reload-' + stale_result)
    ui.axe('batch', '--step', 'sleep .5')
    ui.element('mention-picker-item:role-reviewer@ui@opus')
    ui.element('mention-picker-item:role-reviewer@ui@sol')
    ui.element('mention-picker-item:role-reviewer@remote')
    assert not any(i.get('AXUniqueId') == 'mention-picker-notice' for i in ui.state()), 'Late reload replaced the live catalog'
    ui.capture(host + '-late-' + stale_result + '-ignored')
    # Machine metadata can arrive after presence is already live. Its revision
    # alone must refresh Roles without requiring a new heartbeat state.
    ui.open_case('roles-catalog-revision')
    synced = ui.element('mention-picker-item:role-synced@ui')
    opus = ui.element('mention-picker-item:role-reviewer@ui@opus')
    sol = ui.element('mention-picker-item:role-reviewer@ui@sol')
    remote = ui.element('mention-picker-item:role-reviewer@remote')
    assert opus['frame']['y'] < sol['frame']['y'] < synced['frame']['y'] < remote['frame']['y'], 'Catalog refresh lost the composer-machine preference'
    ui.capture(host + '-catalog-revision-live')
    tap('mention-picker-item:' + path)
    assert ui.element(field).get('AXValue') == token + ' ', 'Role target identity was lost in the real composer'
    ui.capture(host + '-role-inserted')

# Use the production inbox -> session -> create-sheet path with offline services.
tap('ui-design')
choose('session-input', 'chat', 'role-reviewer@ui@sol', '@role:role-reviewer@ui@sol', 'success')
ui.axe('tap', '--label', 'Back', '--post-delay', '.8')
ui.element('ui-design')
ui.open_case('roles-presence-reset')
buttons = [i for i in ui.state() if i.get('type') == 'Button' and i.get('frame')]
frame = max(buttons, key=lambda i: i['frame']['y'])['frame']
ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.8')
choose('create-session-input', 'create', 'role-reviewer@remote', '@role:role-reviewer@remote', 'failure')
print('PASS: both production hosts keep Roles while incomplete, refresh their open picker on presence, recover an initial Role failure, refresh on catalog revision with unchanged presence, ignore late reload success/failure, and retain local instance or remote machine tokens')
