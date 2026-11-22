"""The conversation's run-config sheet gains Model once the computer's options arrive after it opened."""
import sys
from driver import UI

ui = UI(*sys.argv[1:])


def present(identifier):
    return next((item for item in ui.state() if item.get('AXUniqueId') == identifier and item.get('frame', {}).get('height', 0) > 0), None)


ui.element('session-model-collapsed')
ui.axe('tap', '--id', 'session-model-collapsed', '--post-delay', '.6')
ui.element('run-config-agent')
model = ui.wait(lambda items: present('run-config-model'), 'The open run-config sheet did not gain Model when the options arrived')
assert 'GPT-5' in (model.get('AXLabel') or '') + (model.get('AXValue') or ''), f'Model row does not name the current model: {model}'
ui.capture('late-options')
print('PASS: the open run-config sheet refreshes its rows when the computer options arrive')
