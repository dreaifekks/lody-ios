"""Finish a real session projection, then inspect its production process page."""
import json
import sys
from driver import UI
ui = UI(*sys.argv[1:])
screen = next(i['frame'] for i in ui.state() if i.get('type') == 'Application')
assert (ui.output / 'run-video-started').exists(), 'Answer folding requires the run video'

def probe(items=None):
    node = next((i for i in (items if items is not None else ui.state()) if i.get('AXUniqueId') == 'answer-folding-probe'), None)
    return json.loads((node or {}).get('AXValue') or '{}')

def enter(scenario):
    if probe():
        buttons = ui.wait(lambda items: [i for i in items
            if i.get('AXUniqueId') == 'answer-folding-close' and i.get('type') == 'Button'
            and i['frame']['height'] > 0
            and screen['y'] <= i['frame']['y'] + i['frame']['height'] / 2 < screen['y'] + screen['height']],
            'Missing foreground fixture close')
        frame = max(buttons, key=lambda item: item['frame']['y'])['frame']
        ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2))
        ui.wait(lambda items: not probe(items), 'Previous folding scene did not close')
    ui.open_case('answer-folding-' + scenario)
    ui.wait(lambda items: probe(items).get('scenario') == scenario and not probe(items).get('finished'), 'Scene did not reset')
    ui.wait(lambda items: len(probe(items).get('mainTextIDs', [])) == 6, 'Live prose was folded early')

for scenario, kept, process in [
    ('postscript', ['earlier', 'answer1', 'answer2', 'closing'], ['narration', 'read', 'verify', 'bridge', 'poll', 'finish']),
    ('structured', ['earlier', 'closing'], ['narration', 'read', 'verify', 'bridge', 'poll', 'answer1', 'answer2', 'finish']),
    ('tail-work', ['closing'], ['narration', 'read', 'earlier', 'verify', 'bridge', 'poll', 'answer1', 'answer2', 'finish', 'cleanup']),
]:
    enter(scenario)
    ui.capture(scenario + '-live')
    ui.axe('tap', '--id', 'answer-folding-finish', '--post-delay', '.6')
    ui.wait(lambda items: probe(items).get('mainTextIDs') == kept, 'Wrong answer text survived completion')
    for item in kept:
        ui.element('fold:' + item)
    assert not any(i.get('AXUniqueId') in ('fold:narration', 'fold:bridge') for i in ui.state())
    ui.capture(scenario + '-folded')
    ui.axe('tap', '--id', 'fold:process')
    ui.wait(lambda items: probe(items).get('host') == 'process', 'Native process sheet did not open')
    for item in process:
        ui.element('fold:' + item)
    assert probe()['processItemIDs'] == process, 'Process repeated an answer kept outside or lost a work item'
    ui.capture(scenario + '-process')
print('PASS: live prose, postscript runs, earlier substantive text, work tail, stable production process without duplicated answers')
