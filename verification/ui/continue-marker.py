"""Settled Continue is compact; unsettled delivery keeps the real recovery prompt."""
import json
import sys
import catalog
from driver import UI
ui = UI(*sys.argv[1:])
prompt = 'Continue from where you left off. The previous turn was cut off before it finished; check the current state before repeating anything that may already have been done.'

def probe(items=None):
    node = next((i for i in (items if items is not None else ui.state()) if i.get('AXUniqueId') == 'continue-marker-probe'), None)
    return json.loads((node or {}).get('AXValue') or '{}')

def enter(scenario):
    if probe():
        ui.axe('tap', '--id', 'continue-marker-close')
        ui.wait(lambda items: not probe(items), 'Previous Continue scene did not close')
    ui.open_case('continue-marker-' + scenario)
    ui.wait(lambda items: probe(items).get('scenario') == scenario, 'Continue scene did not reset')

def kind(items=None):
    return next((r['kind'] for r in probe(items).get('rows', []) if r['id'] == 'continue:user'), None)

def original():
    ui.wait(lambda items: kind(items) == 'user', 'Unsettled prompt was replaced')
    assert ui.element('continue:user')['AXLabel'] == prompt
    assert probe()['sends'] == 0, 'Reading a recovered turn replayed a send'

enter('settled')
ui.wait(lambda items: kind(items) == 'continued', 'Missing Continue marker')
marker = ui.element('continue:user')
assert marker['AXLabel'] == catalog.text('native.chat.message.continued') and marker['frame']['height'] < 60, marker
assert probe()['rows'][0]['symbol'] == 'play.circle'
ui.capture('settled-marker')
for scenario in ['unknown', 'delivery-unknown', 'delivery-rejected', 'delivery-confirming', 'delivery-waiting', 'delivery-accepted', 'ordinary']:
    enter(scenario)
    original()
    if scenario.startswith('delivery-') and scenario != 'delivery-accepted':
        ui.element('continue:delivery')
    if scenario == 'unknown':
        unknown_height = ui.element('continue:user')['frame']['height']
    ui.capture(scenario)
enter('queued')
ui.wait(lambda items: probe(items).get('rows') == [], 'Queued input changed its existing transcript exclusion')
assert kind() is None
ui.axe('tap', '--id', 'continue-marker-advance')
original()
ui.wait(lambda items: abs(next((i['frame']['height'] for i in items if i.get('AXUniqueId') == 'continue:user'), 0) - unknown_height) < 1,
        'Queued-to-uncertain prompt did not recover the normal readable preview height')
ui.capture('queued-to-uncertain-prompt')
ui.axe('tap', '--id', 'continue:user')
ui.wait(lambda items: next((i['frame']['height'] for i in items if i.get('AXUniqueId') == 'continue:user'), 0) > unknown_height + 44,
        'Uncertain recovery prompt did not expand to its complete text')
ui.capture('queued-to-uncertain-expanded')
enter('transition')
original()
ui.axe('tap', '--id', 'continue-marker-advance')
ui.wait(lambda items: kind(items) == 'continued', 'Settling did not replace the same row with a marker')
assert ui.element('continue:user')['AXLabel'] == catalog.text('native.chat.message.continued')
assert probe()['sends'] == 0
ui.capture('settled-without-replay')
enter('restart')
row = ui.element('restart:error:title')
assert catalog.text('native.chat.error.daemon_restart') in row['AXLabel'], row
assert not ui.element('restart:error:retry')['enabled'], 'Offline recovery action should remain present and disabled'
assert probe()['sends'] == 0
ui.capture('restart-explanation')
print('PASS: compact settled Continue, exact unknown/delivery/queued rules, stable row replacement, no replay and restart title')
