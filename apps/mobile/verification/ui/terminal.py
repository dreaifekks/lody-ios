"""LAN terminal page: the native shell surface takes keyboard input above the keyboard and reads out its screen."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def screen(items):
    return next((i for i in items if i.get('AXUniqueId') == 'terminal-view'), None)


view = ui.element('terminal-view')
assert view.get('AXLabel') == catalog.text('native.terminal.accessibility'), view
# The fixture is ready at once: no status and no reconnect action over the shell.
assert not any(i.get('AXUniqueId') in ('terminal-status', 'terminal-reconnect') for i in ui.state())
ui.wait(lambda items: 'Lody LAN terminal fixture' in ((screen(items) or {}).get('AXValue') or ''), 'Missing fixture banner')
# The shell title from the machine becomes the page title.
ui.wait(lambda items: any(i.get('AXLabel') == 'fixture' and i.get('type') in ('Heading', 'StaticText') for i in items), 'Missing shell title')
ui.capture('ready')

# The page opens with the keyboard; typed input reaches the shell and echoes.
ui.axe('type', 'echo lody\n')
ui.wait(lambda items: ((screen(items) or {}).get('AXValue') or '').count('echo lody') >= 2, 'Input did not reach the shell')
typed = ui.element('terminal-view')['frame']
# The shell shrinks above the keyboard instead of hiding its prompt behind it.
keyboard = [i['frame'] for i in ui.state() if i.get('type') == 'Keyboard' or i.get('AXUniqueId') == 'Keyboard']
if keyboard:
    assert typed['y'] + typed['height'] <= keyboard[0]['y'] + 1, (typed, keyboard[0])
assert typed['height'] >= 120, typed
ui.capture('typed')
print('PASS: terminal surface, fixture banner, shell title, keyboard input echo and keyboard-aware layout')
