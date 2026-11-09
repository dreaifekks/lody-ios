"""Offline native media/RPC boundaries; no microphone, account, hub or token."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])

def tap(id):
    ui.element(id)
    ui.axe('tap', '--id', id, '--post-delay', '.35')

def calls(value):
    ui.wait(lambda _: ui.element('voice-calls').get('AXLabel') == value, 'voice RPC sequence: ' + value)

for host, scene in [('chat', 'voice-preview'), ('create', 'voice-create-preview')]:
    if host == 'create':
        ui.open_case(scene)
    tap('voice-input')
    mic = ui.element('session-voice')
    assert mic['frame']['width'] >= 44 and mic['frame']['height'] >= 44
    ui.capture(host + '-idle')
    tap('session-voice'); calls('start')
    ui.capture(host + '-connecting')
    tap('voice-connect'); calls('start,poll')
    assert ui.element('session-voice').get('AXValue') == catalog.text('native.voice.listening')
    ui.capture(host + '-listening')
    tap('voice-transcript')
    assert 'Draft Dictated offline text' in ui.element('voice-input').get('AXValue', '')
    ui.capture(host + '-transcript')
    tap('session-voice'); calls('start,poll,stop')
    ui.capture(host + '-stopped')
    tap('voice-fail'); tap('session-voice'); calls('start,poll,stop,start')
    ui.wait(lambda _: ui.element('session-voice').get('AXLabel') == catalog.text('native.voice.dictate'), 'failed start did not return idle')
    ui.capture(host + '-failed')
    tap('voice-preferences')
    toggle = ui.element('voice-dictation')
    ui.capture(host + '-preferences-enabled')
    f = ui.element('voice-agent')['frame']
    ui.axe('touch', '-x', str(f['x'] + f['width'] - 20), '-y', str(f['y'] + f['height']/2), '--down', '--up', '--delay', '.4')
    ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('settings.voice.needsUpdate', name='Codex', machine='Laptop') for i in items), 'Agent menu missing')
    ui.capture(host + '-agents')
    ui.axe('tap', '--label', catalog.text('settings.voice.needsUpdate', name='Codex', machine='Laptop'), '--post-delay', '.4')
    assert 'Laptop' in ui.element('voice-agent').get('AXValue', '')
    ui.capture(host + '-agent-selected')
    # Native switches are tapped at their trailing edge.
    ui.tap_switch(ui.element('voice-dictation:toggle'))
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'voice-agent' for i in items), 'Agent row remained after disabling')
    ui.capture(host + '-preferences-disabled')
    ui.axe('tap', '--label', 'Close Preferences', '--post-delay', '.4')
    ui.element('voice-input')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'session-voice' and i.get('frame', {}).get('width', 0) > 0 for i in items), 'Microphone remained visible after disabling')
    ui.capture(host + '-button-hidden')

    ui.axe('tap', '--label', catalog.text('accessibility.closeSheet', title='Voice · ' + host), '--post-delay', '.5')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'voice-input' for i in items), 'Previous voice host did not close')
