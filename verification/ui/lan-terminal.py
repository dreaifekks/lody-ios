"""Offline production terminal page: replay/input/exit, navigation and account fences.
Run with English software keyboard, light/dark screenshots and runner video enabled.
No login, Keychain, hub or member listener is used by these fixture scenes.
"""
import re
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])


def reset_case(preview):
    # A Debug deep link presents a new sheet; dismiss the old fixture first so
    # accessibility cannot target its still-visible underlying controls.
    label = catalog.text('accessibility.closeSheet', title='')
    close = ui.wait(lambda items: next((i for i in items if i.get('type') == 'Button' and i.get('AXLabel') == label), None), 'Missing fixture close')
    f = close['frame']
    ui.axe('tap', '-x', str(f['x'] + f['width'] / 2), '-y', str(f['y'] + f['height'] / 2), '--post-delay', '.4')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'terminal-fixture-open' for i in items), 'Old fixture did not close')
    ui.open_case(preview)
    ui.wait(lambda items: next((i for i in items if i.get('AXUniqueId') == 'terminal-fixture-open' and i['frame']['height'] >= 44), None), 'New fixture did not settle')


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
# A lost connection leaves its PTY alive on the member. Reconnect must list
# and attach fixture-1; opening fixture-2 here would fail later ownership counts.
ui.axe('tap', '--id', 'terminal-fixture-disconnect')
ui.element('terminal-reconnect')
ui.capture('disconnected')
ui.axe('tap', '--id', 'terminal-reconnect')
screen_contains('Lody LAN terminal fixture-1')
ui.axe('type', 'resumed same shell\n')
screen_contains('resumed same shell')
ui.capture('reconnected-same-id')
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
# End and account expiry must clean known resources even with a dead link;
# the cleanup route intentionally does not depend on the new-open auth gate.
open_terminal()
screen_contains('Lody LAN terminal fixture-4')
ui.axe('tap', '--id', 'terminal-fixture-disconnect')
ui.element('terminal-reconnect')
back()
counts = audit(0, opens=4, closes=4)
assert counts['cleanups'] == 1, counts
open_terminal()
screen_contains('Lody LAN terminal fixture-5')
ui.axe('tap', '--id', 'terminal-fixture-disconnect')
ui.element('terminal-reconnect')
ui.axe('tap', '--id', 'terminal-fixture-expire')
back()
counts = audit(0, opens=5, closes=5)
assert counts['cleanups'] == 2, counts
ui.capture('dead-link-cleaned')

reset_case('terminal-preview-late-open')
open_terminal()
ui.element('terminal-status')
back()
audit(0, opens=0, closes=0)
ui.axe('tap', '--id', 'terminal-fixture-release')
audit(0, opens=1, closes=1)
ui.capture('late-open-cleaned')

reset_case('terminal-preview-failure')
open_terminal()
retry = ui.element('terminal-reconnect')
assert retry['frame']['height'] >= 44, retry
ui.capture('refused')
ui.axe('tap', '--id', 'terminal-reconnect')
screen_contains('Lody LAN terminal')
back()
audit(0, opens=2, closes=1)
reset_case('terminal-preview-unknown')
open_terminal()
ui.wait(lambda items: any(i.get('AXUniqueId') == 'terminal-status'
    and (i.get('AXLabel') or '').startswith(catalog.text('terminal.openUnknown')) for i in items), 'Unknown open was hidden')
assert not any(i.get('AXUniqueId') == 'terminal-reconnect' for i in ui.state()), 'Unknown open allowed another open'
ui.capture('open-unknown')
back()
audit(0, opens=0, closes=0)
ui.axe('tap', '--id', 'terminal-fixture-release')
audit(0, opens=1, closes=1)
# A local notSent result arriving after onClose must resolve the old attempt
# despite the invalidated generation, restore Retry, and create exactly one PTY.
reset_case('terminal-preview-not-sent')
open_terminal()
ui.element('terminal-reconnect')
assert not any(i.get('AXUniqueId') == 'terminal-status'
    and (i.get('AXLabel') or '').startswith(catalog.text('terminal.openUnknown')) for i in ui.state())
ui.capture('local-not-sent-retry')
ui.axe('tap', '--id', 'terminal-reconnect')
screen_contains('Lody LAN terminal fixture-1')
back()
audit(0, opens=1, closes=1)
print('PASS: terminal replay/input/exit/retry, cancelled and committed return, account expiry, delayed open cleanup (offline service).')
