"""Offline orchestration summaries and read-only Board notices."""
import sys
from driver import UI
ui = UI(*sys.argv[1:])
ui.axe('tap', '--label', 'Pending fixtures')
ui.axe('tap', '--label', 'board', '--post-delay', '.5')
assert '52 task results' in ui.element('batch:results')['AXLabel']
assert 'Native review' in ui.element('batch:results')['AXLabel']
assert 'Board thread finished' in ui.element('report:result')['AXLabel']
assert 'Context compaction · Completed' in ui.element('maintenance:notice')['AXLabel']
assert 'chain reached its limit' in ui.element('chain:notice')['AXLabel']
assert not any((i.get('AXUniqueId') or '').startswith('silent:') for i in ui.state()), 'Idle interrupted maintenance drew a row'
proposal = ui.element('proposal:notice')
assert 'Reviewer' in proposal['AXLabel'] and 'Review native code' in proposal['AXLabel'] and 'Read-only review' in proposal['AXLabel']
assert proposal['type'] != 'Button', 'Role proposal must remain read-only'
assert not any(i.get('AXLabel') in ['Save', 'Approve'] for i in ui.state())
ui.capture('board-summary-and-notices')
print('PASS: batch/report summaries, silent maintenance, dividers and read-only Role fields')
