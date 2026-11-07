"""Offline production terminal page: replay/input/exit, navigation and account fences.
Run with English software keyboard, light/dark screenshots and runner video enabled.
No login, Keychain, hub or member listener is used by these fixture scenes.
"""
import re
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])


def open_terminal():
    ui.axe('tap', '--id', 'terminal-fixture-open')
    return ui.element('terminal-view')


def back():
    ui.axe('tap', '--id', 'BackButton')
    return ui.element('terminal-fixture-probe')


def audit(active, opens=None, closes=None):
    def matches(items):
        probe = next((i for i in items if i.get('AXUniqueId') == 'terminal-fixture-probe'), None)
        if not probe:
            return None
        text = probe.get('AXLabel') or ''
        counts = dict((key, int(value)) for key, value in re.findall(r'(\w+):(\d+)', text))
        if counts.get('active') != active:
            return None
        if opens is not None and counts.get('opens') != opens:
            return None
        if closes is not None and counts.get('closes') != closes:
            return None
        return counts
    return ui.wait(matches, f'Wrong terminal ownership: active={active}, opens={opens}, closes={closes}')


def screen_contains(text):
    return ui.wait(lambda items: next((i for i in items
        if i.get('AXUniqueId') == 'terminal-view' and text in (i.get('AXValue') or '')), None),
        f'Terminal never rendered {text!r}')


ui.element('terminal-fixture-open')
open_terminal()
screen_contains('Lody LAN terminal')
ui.capture('replay-nerd-fonts')
ui.axe('tap', '--id', 'terminal-view')
ui.axe('type', 'echo hello\n')
screen_contains('echo hello')
ui.capture('input')
# A short edge drag followed by release cancels the interactive pop. It must
# leave this same shell usable. Temporal evidence is in the runner's run.mp4.
terminal = ui.element('terminal-view')['frame']
y = terminal['y'] + min(90, terminal['height'] / 3)
ui.axe('drag', '--start-x', '1', '--start-y', str(y), '--end-x', '45', '--end-y', str(y), '--duration', '.7')
ui.element('terminal-view')
ui.axe('type', 'after cancel\n')
screen_contains('after cancel')
ui.capture('cancelled-pop')
ui.axe('type', 'exit\n')
ui.element('terminal-reconnect')
ui.capture('exited')
ui.axe('tap', '--id', 'terminal-reconnect')
screen_contains('Lody LAN terminal')
ui.axe('tap', '--id', 'terminal-fixture-expire')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'terminal-status'
    and i.get('AXLabel') == catalog.text('terminal.unavailable') for i in items), 'Account expiry did not close terminal')
assert not any(i.get('AXUniqueId') == 'terminal-reconnect' for i in ui.state())
ui.capture('expired')
back()
counts = audit(0, opens=2, closes=2)
assert counts['inputs'] > 0, counts
# An ordinary committed pop ends a shell too.
open_terminal()
screen_contains('Lody LAN terminal')
back()
audit(0, opens=3, closes=3)
ui.capture('closed')

ui.open_case('terminal-preview-late-open')
open_terminal()
ui.element('terminal-status')
back()
audit(0, opens=0, closes=0)
ui.axe('tap', '--id', 'terminal-fixture-release')
audit(0, opens=1, closes=1)
ui.capture('late-open-cleaned')

ui.open_case('terminal-preview-failure')
open_terminal()
retry = ui.element('terminal-reconnect')
assert retry['frame']['height'] >= 44, retry
ui.capture('refused')
ui.axe('tap', '--id', 'terminal-reconnect')
screen_contains('Lody LAN terminal')
back()
audit(0, opens=2, closes=1)
print('PASS: terminal replay/input/exit/retry, cancelled and committed return, account expiry, delayed open cleanup (offline service).')
