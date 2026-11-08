"""Production transcript -> owner router -> deterministic URL/navigation targets, offline."""
import json
import sys
from driver import UI

ui = UI(*sys.argv[1:])
screen = next(i['frame'] for i in ui.state() if i.get('type') == 'Application')

def probe(items=None):
    node = next((x for x in items or ui.state() if x.get('AXUniqueId') == 'message-links-probe'), None)
    return json.loads((node or {}).get('AXValue') or '{}')

def enter(scenario):
    if probe():
        buttons = ui.wait(lambda items: [i for i in items
            if i.get('AXUniqueId') == 'message-links-close' and i.get('type') == 'Button'
            and i['frame']['height'] > 0
            and screen['y'] <= i['frame']['y'] + i['frame']['height'] / 2 < screen['y'] + screen['height']],
            'Missing fixture close button')
        # The presenting chat stays visible above a half-height process sheet.
        # Its bar item shares this fixture action; tap the foreground sheet's copy.
        frame = max(buttons, key=lambda item: item['frame']['y'])['frame']
        ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.4')
        ui.wait(lambda items: not probe(items), 'Previous fixture did not close')
    ui.open_case('message-links-' + scenario)
    ui.wait(lambda items: probe(items).get('host') == 'session' and probe(items).get('scenario') == scenario, 'Message-links scene did not reset')
    ui.wait(lambda items: probe(items).get('events') == [], 'A fresh scene has effects')
    # Wait for the rendered cell as well as the fixture probe.
    ui.element('links:body')

def tap_target(href, expected, host='session'):
    target = ui.wait(lambda items: next((x for x in probe(items).get('targets', []) if x['href'] == href), None),
                     'Missing rendered link: ' + href)
    ui.axe('tap', '-x', str(target['x']), '-y', str(target['y']), '--post-delay', '.6')
    events = ui.wait(lambda items: probe(items).get('events'), 'Tap did not reach the routing service')
    assert events == [dict(kind=expected[0], target=expected[1], host=host)], events
    # A later layout must not dispatch the same tap again.
    assert probe()['events'] == events

for scenario, href in [('session', 'lody://session/target?workspace=links_ws'), ('legacy', 'session://target'), ('streaming', 'session://target'),
                       ('tab', 'lody://session/base?workspace=links_ws&tab=tab')]:
    enter(scenario)
    assert ui.element('links:body').get('custom_actions'), 'Session link has no VoiceOver action'
    tap_target(href, ('session', 'tab' if scenario == 'tab' else 'target'))
    ui.capture(scenario)

for scenario, href in [('workspace', 'lody://session/target?workspace=other'),
                       ('missing-tab', 'lody://session/base?tab=missing'), ('missing', 'session://missing')]:
    enter(scenario)
    tap_target(href, ('notice', 'That session is not in this workspace'))

for scenario, href, path in [('file', 'src/link.swift:12', 'origin:src/link.swift:12'),
                             ('unicode', 'notes/準備.md', 'origin:notes/準備.md:0'),
                             ('explicit-code', 'src/explicit.swift:3', 'origin:src/explicit.swift:3')]:
    enter(scenario)
    tap_target(href, ('file', path))
    ui.capture(scenario)

for scenario in ['inline-code', 'code-fence']:
    enter(scenario)
    ui.wait(lambda items: probe(items).get('parsedLinks') == [], 'Code acquired parsed links')
    assert not probe()['targets'], probe()
    node = ui.element('links:body')
    assert not node.get('custom_actions'), node
    row = node['frame']
    ui.axe('tap', '-x', str(row['x'] + row['width'] / 2), '-y', str(row['y'] + row['height'] / 2), '--post-delay', '.6')
    assert probe()['events'] == [], probe()
    ui.capture(scenario)

rewritten = 'http://192.0.2.42:5173/a%20b?x=1&y=2#frag'
for scenario, hostname in [('localhost', 'localhost'), ('ipv4', '127.0.0.1'), ('zero', '0.0.0.0'), ('ipv6', '[::1]')]:
    enter(scenario)
    tap_target(f'http://{hostname}:5173/a%20b?x=1&y=2#frag', ('url', rewritten), host='system')
for scenario in ['nohost', 'cloud-localhost']:
    enter(scenario)
    tap_target('http://localhost:5173/', ('notice', 'This address is on the computer running the session, and that computer has no LAN address to reach it by'))

systems = [('http', 'http://example.invalid/path?q=1#frag'), ('https', 'https://example.invalid/path?q=1#frag'),
           ('file-url', 'file:///tmp/report%20one.md#L12'), ('tg', 'tg://resolve?domain=lody'),
           ('mailto', 'mailto:reader@example.invalid'), ('tel', 'tel:+15550100')]
for scenario, href in systems + [('bare-' + name, href) for name, href in systems if name in ('file-url', 'tg', 'mailto', 'tel')]:
    enter(scenario)
    tap_target(href, ('url', href), host='system')

for scenario, row, host, href, expected in [
    ('process', 'links:process', 'process', 'session://target', ('session', 'target')),
    ('subagent', 'links:task', 'subagent', 'session://target', ('session', 'target')),
    ('process-file', 'links:process', 'process', 'src/child.swift:4', ('file', 'origin:src/child.swift:4')),
    ('subagent-file', 'links:task', 'subagent', 'src/child.swift:4', ('file', 'origin:src/child.swift:4')),
    ('process-url', 'links:process', 'process', 'http://localhost:5173/a%20b?x=1&y=2#frag', ('url', rewritten)),
    ('subagent-url', 'links:task', 'subagent', 'file:///tmp/report%20one.md#L12', ('url', 'file:///tmp/report%20one.md#L12')),
]:
    enter(scenario)
    ui.axe('tap', '--id', row)
    ui.wait(lambda items: probe(items).get('host') == host, 'Child transcript did not open: ' + host)
    tap_target(href, expected, host=host if expected[0] in ('session', 'file') else 'system')
    ui.capture(scenario)
for scenario, row, host, result in [('process-code', 'links:process', 'process', 'links:thought'),
                                    ('subagent-code', 'links:task', 'subagent', 'subagent-detail-result')]:
    enter(scenario)
    ui.axe('tap', '--id', row)
    ui.wait(lambda items: probe(items).get('host') == host, 'Code host did not open')
    assert probe()['parsedLinks'] == [] and probe()['targets'] == [], probe()
    frame = ui.element(result)['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.6')
    assert probe()['events'] == [], probe()
    ui.capture(scenario)
print('PASS: exact catalog IDs, legacy tab and workspace, bare paths, literal code, machine loopback rewrite, system schemes, process/subagent callbacks')
