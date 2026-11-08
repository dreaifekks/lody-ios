"""Board events retain their projected, read-only meaning in a native chat."""
import sys
from driver import UI

ui = UI(*sys.argv[1:])
expected = {
    'results:batch': '2 task results\nLayout check · Completed\nWire check · Failed',
    'results:single': '1 task results · delivery uncertain\nAgent reply · Waiting for you',
    'maintenance:compact': 'Context compaction · Completed',
    'maintenance:limit': 'Autonomous chain reached its limit. Send a message to continue.',
    'proposal:role': 'Update Role: iosDev\nDescription: Review native chat\nDefault instruction: Use UIKit.\nSaved',
}
for identifier, text in expected.items():
    row = ui.element(identifier)
    assert row['AXLabel'] == text, row
    assert row['type'] != 'Button', row
assert not any((item.get('AXUniqueId') or '').startswith('idle:') for item in ui.state())
ui.capture('board-events')
print('PASS: completion batch/single, maintenance divider, chain limit, read-only Role proposal; interrupted idle maintenance hidden')
