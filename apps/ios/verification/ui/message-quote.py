"""Quote comment sheet layout and the compact composer quote card."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])
excerpt = 'What can I help you with?'

commit = ui.element('quote-commit')['frame']
snapshot = ui.element('quote-snapshot')['frame']
comment = ui.element('quote-comment')['frame']
ui.capture('sheet')
header_gap = snapshot['y'] - (commit['y'] + commit['height'])
assert 0 <= header_gap <= 32, f'Header stretched above the quoted passage: {header_gap}pt'
comment_gap = comment['y'] - (snapshot['y'] + snapshot['height'])
assert comment_gap >= 12, f'Quoted passage crowds the comment field: {comment_gap}pt'
print('PASS: quote sheet header hugs its bar and the passage stands apart from the comment', flush=True)

ui.axe('type', 'hi')
ui.axe('tap', '--id', 'quote-commit', '--post-delay', '.8')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'quote-sheet' for i in items), 'Quote sheet did not close')
ui.axe('tap', '--id', 'session-input', '--post-delay', '.8')
card_label = catalog.text('native.chat.quote.card', **{'quoted passage': excerpt})
card = ui.wait(lambda items: next((i for i in items if i.get('AXLabel') == card_label), None), 'Missing composer quote card')['frame']
ui.capture('card')
assert card['height'] <= 52, f'Quote card is not compact: {card["height"]}pt'
print('PASS: a quote alone sits in a compact composer card', flush=True)
