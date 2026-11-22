"""Actual product screens open the docked reference panel from a typed trigger and keep short references."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])

def tap(identifier):
    if identifier.startswith('mention-item:'):
        for attempt in range(5):
            items = ui.state()
            panel = next(i['frame'] for i in items if i.get('AXUniqueId') == 'mention-panel')
            target = next((i['frame'] for i in items if i.get('AXUniqueId') == identifier), None)
            if target and target['y'] >= panel['y'] and target['y'] + target['height'] <= panel['y'] + panel['height']:
                break
            rows = [i['frame'] for i in items if (i.get('AXUniqueId') or '').startswith('mention-item:') and i.get('frame')]
            assert rows, 'Reference panel missing'
            x = rows[0]['x'] + rows[0]['width'] / 2
            # The panel keeps its scroll between triggers: return to the top first, then page down.
            start, end = panel['y'] + panel['height'] - 24, panel['y'] + 24
            if attempt == 0:
                start, end = end, start
            ui.axe('drag', '--start-x', str(x), '--start-y', str(start), '--end-x', str(x), '--end-y', str(end),
                   '--duration', '.4', '--post-delay', '.4')
    ui.element(identifier)
    ui.axe('tap', '--id', identifier, '--post-delay', '.4')

def value(field):
    return ui.element(field).get('AXValue') or ''

def type_text(text):
    ui.axe('type', text)
    ui.restore_software_keyboard()

def shortcut(field, host):
    tap(field)
    # A listed prompt shortcut replaces its trigger with its body; nothing of "/rev" remains.
    ui.type_into(field, '/rev')
    tap('mention-item:ui-review-shortcut')
    assert value(field) == 'Review the diff ', f'The shortcut left its trigger or lost its body: {value(field)!r}'
    ui.capture(host + '-shortcut')
    for _ in range(len(value(field)) + 4):
        ui.axe('key', '42')
    ui.restore_software_keyboard()
    ui.wait(lambda items: not value(field), 'Could not clear the shortcut body')

def choose(field, host):
    tap(field)
    type_text('@')
    files = ui.element('mention-item:file')
    assert catalog.text('mentions.truncated') in str(files.get('AXLabel', '')) + str(files.get('AXValue', '')), 'Truncated file listing lost its notice'
    tap('mention-item:file')
    tap('mention-item:src')
    ui.element('mention-use-directory')
    ui.capture(host + '-files')
    tap('mention-item:src/session.ts')
    assert value(field) == '@src/session.ts ', f'Selected file did not reach the real composer: {value(field)!r}'
    type_text('@')
    tap('mention-item:skill')
    tap('mention-item:/fixture/skills/auth/SKILL.md')
    assert value(field) == '@src/session.ts $auth-review ', f'The real composer lost the machine skill path or prior draft: {value(field)!r}'
    # Sessions and Agent Roles read as their names; they still send their tokens.
    for kind, path, shown in [
        ('session', 'ui-review', '@Review authentication'),
        ('role', 'role-reviewer', '🪼 Reviewer'),
        ('issue', 'issue:11', '#11'),
        ('pr', 'pr:12', '#12'),
        ('cmd', 'compact', '/compact'),
    ]:
        previous = value(field)
        type_text('@')
        tap('mention-item:' + kind)
        ui.element('mention-item:' + path)
        tap('mention-item:' + path)
        assert value(field) == previous + shown + ' ', f'Lost or expanded a reference before send: {value(field)!r}'
    ui.capture(host + '-draft')

# Start from the real inbox, not a manually wired composer preview.
tap('ui-design')
shortcut('session-input', 'chat')
choose('session-input', 'chat')
for _ in range(3):
    if not any(i.get('AXUniqueId') == 'BackButton' for i in ui.state()):
        break
    ui.axe('tap', '--id', 'BackButton', '--post-delay', '1')
ui.element('ui-design')
ui.axe('tap', '--label', catalog.text('tabs.newSession'), '--post-delay', '1')
shortcut('create-session-input', 'sheet')
choose('create-session-input', 'sheet')
print('PASS: production chat and new-session screens insert a listed prompt shortcut body, browse all seven provider-shaped categories from a typed trigger and retain short references')
