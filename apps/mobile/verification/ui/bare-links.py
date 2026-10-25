"""Bare files/session URIs and the desktop inline-code boundary, offline."""
import sys
from driver import UI
ui = UI(*sys.argv[1:])
ui.axe('tap', '--label', 'Pending fixtures')
ui.axe('tap', '--label', 'links', '--post-delay', '.5')
ui.element('bare:file')
ui.capture('bare-links')
for identifier, expected in [('unicode', 'file:notes/准备.md:0'), ('home', 'file:~/out/report.md:12'), ('session', 'missingSession:lody://session/review?workspace=fixture'), ('legacy', 'missingSession:session://review'), ('code', 'file:docs/sample.swift:0')]:
    frame = ui.element('bare:' + identifier)['frame']
    ui.axe('tap', '-x', str(frame['x'] + min(70, frame['width'] / 2)), '-y', str(frame['y'] + min(20, frame['height'] / 2)), '--post-delay', '.3')
    assert ui.element('pending-opened')['AXLabel'] == expected
    ui.capture('opened-' + identifier)
frame = ui.element('bare:file')['frame']
ui.axe('tap', '-x', str(frame['x'] + min(70, frame['width'] / 2)), '-y', str(frame['y'] + min(20, frame['height'] / 2)), '--post-delay', '.5')
ui.element('file-document')
ui.capture('production-file-preview')
ui.axe('tap', '--id', 'BackButton', '--post-delay', '.5')
literal = ui.element('bare:literal')
assert not literal.get('custom_actions'), 'Literal code must not have file actions'
before = ui.element('pending-opened')['AXLabel']
frame = literal['frame']
for y in [frame['y'] + 20, frame['y'] + 65]:
    ui.axe('tap', '-x', str(frame['x'] + 70), '-y', str(y), '--post-delay', '.3')
    assert ui.element('pending-opened')['AXLabel'] == before, 'Code literal opened a link'
ui.capture('literal-code-retained')
print('PASS: bare file/Unicode/home/line/session links route through production handlers; whole-file inline code links, other code stays literal')
