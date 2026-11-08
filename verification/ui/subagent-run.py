"""A task opens its entire run, keeps historical tool targets and follows rev edits."""
import json
import sys
from driver import UI
import catalog
ui = UI(*sys.argv[1:])

def probe(items=None):
    item = next((i for i in (items or ui.state()) if i.get('AXUniqueId') == 'subagent-run-probe'), None)
    return json.loads((item or {}).get('AXValue') or '{}')

first = 'run-parent:["task-run","first"]'
tool = 'run-parent:["task-run","old-tool"]'
card = ui.element('run-parent:task-run')
assert '2 agents · 1 running · 1 done' in card['AXLabel'], card
assert 'Latest step revision 1.' in card.get('AXValue', ''), card
assert 'Completed' in ui.element('run-parent:task-done').get('AXValue', '')
ui.capture('subagent-group-running')
ui.axe('tap', '--id', 'run-parent:task-run', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('reads') == 1, 'The page did not read a full run once')
assert 'Earlier full report revision 1.' in ui.element(first)['AXLabel']
ui.element(tool)
assert 'Model-X' in ui.element('subagent-run-meta')['AXLabel']
ui.element('subagent-run-incomplete')
ui.capture('subagent-full-history')
ui.axe('tap', '--id', tool, '--post-delay', '.4')
ui.wait(lambda items: any('Historical tool detail: ["task-run","old-tool"]' in (i.get('AXLabel') or '') for i in items), 'Historical composite tool target did not open')
ui.capture('subagent-historical-tool')
ui.axe('tap', '--label', catalog.text('common.done'), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('details') == ['["task-run","old-tool"]'], 'Wrong historical item ID')
ui.axe('tap', '--id', 'subagent-run-update', '--post-delay', '.4')
ui.wait(lambda items: 'Earlier full report revision 2.' in next((i.get('AXLabel', '') for i in items if i.get('AXUniqueId') == first), ''), 'Same-count earlier steps did not refresh by rev')
ui.wait(lambda items: probe(items).get('reads') == 2, 'A task rev did not trigger exactly one complete read')
assert not any(i.get('AXUniqueId') == 'subagent-run-incomplete' for i in ui.state()), 'New run metadata did not replace incomplete state'
ui.capture('subagent-revised-full-history')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('host') == 'session' and probe(items).get('observers') == 0, 'Closed run kept its subscription')
assert '2 agents · 2 done' in ui.element('run-parent:task-run')['AXLabel']
ui.capture('subagent-group-done')
print('PASS: run-state groups/latest step, full history, original historical tool ID, same-count rev updates, metadata and subscription release')
