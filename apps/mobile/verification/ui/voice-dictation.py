"""Experimental voice dictation stays out of the composer until Settings turns it on; the switch then shows a 44 pt microphone in the create-session and chat hosts, and turning it off hides it again."""
import sys
import time
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])
close_settings = catalog.text('accessibility.closeSheet', title=catalog.text('tabs.settings'))
close_composer = catalog.text('accessibility.closeSheet', title='输入框验收')


def present(identifier):
    return any(item.get('AXUniqueId') == identifier for item in ui.state())


def scroll_to(identifier, start='600', end='400'):
    # Grouped lists are native UICollectionViews; offscreen rows are not in the tree.
    for _ in range(10):
        if present(identifier):
            break
        ui.axe('swipe', '--start-x', '200', '--start-y', start, '--end-x', '200', '--end-y', end, '--duration', '.5', '--post-delay', '.5')
    settled = None
    for _ in range(10):
        frame = ui.element(identifier)['frame']
        if frame == settled:
            return frame
        settled = frame
        time.sleep(.3)
    return settled


def open_debug(row, ready):
    for attempt in range(16):
        if present(row):
            break
        start, end = ('700', '500') if attempt < 8 else ('300', '700')
        ui.axe('swipe', '--start-x', '200', '--start-y', start, '--end-x', '200', '--end-y', end, '--duration', '.5', '--post-delay', '.6')
    scroll_to(row)
    ui.axe('tap', '--id', row, '--pre-delay', '.6', '--post-delay', '.8', '--tap-style', 'physical')
    ui.element(ready)


def set_voice(on):
    scroll_to('voice-dictation:toggle')
    value = '1' if on else '0'
    if ui.element('voice-dictation:toggle').get('AXValue') != value:
        ui.axe('tap', '--id', 'voice-dictation:toggle', '--post-delay', '.6')
    ui.wait(lambda _: ui.element('voice-dictation:toggle').get('AXValue') == value, f'Voice switch did not turn {value}')


def focus(input_id):
    ui.axe('tap', '--id', input_id, '--post-delay', '1')
    ui.wait(lambda items: any(item.get('AXUniqueId') == input_id for item in items), f'Missing {input_id}')


def microphone():
    button = ui.element('session-voice')
    assert button.get('AXLabel') == catalog.text('native.voice.dictate'), button
    assert button['frame']['width'] >= 44 and button['frame']['height'] >= 44, button
    send = next(item for item in ui.state() if item.get('AXUniqueId') in ('session-send', 'session-stop'))['frame']
    assert button['frame']['x'] + button['frame']['width'] <= send['x'] + 1, 'Microphone overlaps the send button'
    return button


# Off by default: Settings shows only the switch, and signed out there is no agent to choose.
set_voice(False)
assert not present('voice-agent'), 'The voice agent row appeared while dictation is off'
ui.capture('settings-off')
ui.axe('tap', '--label', close_settings, '--post-delay', '1')

open_debug('composer-preview', 'create-session-input')
focus('create-session-input')
time.sleep(.5)
assert not present('session-voice'), 'The microphone shows while dictation is off'
ui.capture('create-off')
ui.axe('tap', '--label', close_composer, '--post-delay', '1')

open_debug('queued-message-behavior-preview', 'queued-message-behavior')
set_voice(True)
assert not present('voice-agent'), 'Signed out, there is no workspace agent to choose'
ui.capture('settings-on')
ui.axe('tap', '--label', close_settings, '--post-delay', '1')

open_debug('composer-preview', 'create-session-input')
focus('create-session-input')
microphone()
ui.capture('create-on')
ui.axe('tap', '--label', close_composer, '--post-delay', '1')

open_debug('chat-preview', 'session-input')
focus('session-input')
microphone()
ui.capture('chat-on')
# Interactive pop back to Debug.
ui.axe('swipe', '--start-x', '2', '--start-y', '400', '--end-x', '370', '--end-y', '400', '--duration', '.5', '--post-delay', '.8')

# Restore the default so later cases see the production composer.
open_debug('queued-message-behavior-preview', 'queued-message-behavior')
set_voice(False)
ui.capture('settings-restored')
print('PASS: dictation is opt-in from Settings, shows a 44 pt microphone beside send in the create and chat composers, and hides again when turned off.')
