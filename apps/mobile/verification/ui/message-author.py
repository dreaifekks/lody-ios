"""Offline delegated authors retain Role instance/model and VoiceOver provenance."""
import sys
from driver import UI
ui = UI(*sys.argv[1:])
author = ui.element('delegated:user')
assert 'Reviewer · mini · Codex · GPT-6 Sol' in author['AXLabel'], author
assert 'Please review the native changes.' in author['AXLabel']
plain = ui.element('plain:user')
assert plain['AXLabel'] == 'A human message without an author.', plain
assert author['frame']['height'] > plain['frame']['height'], 'Author must occupy its own line'
ui.capture('author-and-human')
print('PASS: author provenance, Role instance/model, separate line and unlabelled human bubble')

for name, expected in [('find-author', 'No results'), ('find-body', '1 / 1')]:
    ui.axe('tap', '--label', 'Pending fixtures')
    ui.axe('tap', '--label', name, '--post-delay', '.4')
    assert expected in str(ui.element('chat-find-count'))
    ui.capture(name)
    ui.axe('tap', '--id', 'chat-find-close', '--post-delay', '.3')
