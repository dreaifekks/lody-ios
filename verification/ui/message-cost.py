"""Provider cost is shown by the production details sheet and refreshes in place."""
import json
import re
import sys
import catalog
from driver import UI
ui = UI(*sys.argv[1:])

def probe(items=None):
    node = next((i for i in (items if items is not None else ui.state()) if i.get('AXUniqueId') == 'message-cost-probe'), None)
    return json.loads((node or {}).get('AXValue') or '{}')

def enter(scenario):
    if probe().get('host') == 'details':
        ui.axe('tap', '--label', catalog.text('common.done'))
        ui.wait(lambda items: probe(items).get('host') == 'session', 'Details sheet did not close')
    if probe():
        ui.axe('tap', '--id', 'message-cost-close')
        ui.wait(lambda items: not probe(items), 'Previous cost scene did not close')
    ui.open_case('message-cost-' + scenario)
    ui.wait(lambda items: probe(items).get('scenario') == scenario, 'Cost scene did not reset')
    ui.element('cost-turn:meta:details')
    ui.axe('tap', '--id', 'cost-turn:meta:details')
    ui.wait(lambda items: probe(items).get('host') == 'details', 'Production details sheet did not open')

def tokens():
    assert '12' in str(ui.element('input'))
    assert '3' in str(ui.element('output'))
    ui.element('cacheRead')
    ui.element('cacheWrite')

def cost(amount):
    def exact(row):
        spoken = str(row.get('AXLabel') or '') + ' ' + str(row.get('AXValue') or '')
        match = re.search(r'(?:USD|US\$|\$)\s*([0-9][0-9,]*\.[0-9]+)', spoken)
        return match is not None and match.group(1) == amount
    row = ui.wait(lambda items: next((i for i in items if i.get('AXUniqueId') == 'cost' and exact(i)), None), 'Wrong USD cost: ' + amount)
    assert catalog.text('message.details.cost') in str(row), row
    assert catalog.text('message.details.costHint') in str(row), row
    assert '$' in str(row) or 'USD' in str(row), row
    tokens()

for scenario, amount in [('tiny', '0.00000001'), ('zero', '0.00'), ('fraction', '0.1235'), ('normal', '12.35')]:
    enter(scenario)
    cost(amount)
    ui.capture(scenario)
for scenario in ['missing', 'null', 'invalid']:
    enter(scenario)
    tokens()
    assert not any(i.get('AXUniqueId') == 'cost' for i in ui.state()), 'Absent/invalid cost was estimated'
    ui.capture(scenario)
enter('late')
tokens()
assert not any(i.get('AXUniqueId') == 'cost' for i in ui.state())
ui.capture('late-before')
for step, amount in [(1, '0.00000001'), (2, '0.00')]:
    ui.axe('tap', '--id', 'message-cost-advance')
    ui.wait(lambda items: probe(items).get('step') == step, 'Usage update was not published')
    cost(amount)
    ui.capture('late-' + str(step))
ui.axe('tap', '--id', 'message-cost-advance')
ui.wait(lambda items: probe(items).get('step') == 3 and not any(i.get('AXUniqueId') == 'cost' for i in items), 'Removed cost remained in the open details sheet')
tokens()
ui.capture('late-removed')
print('PASS: tiny/zero/fraction/normal USD, missing/null/invalid omission with tokens retained, open-sheet late add/update/remove')
