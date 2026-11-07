"""Offline production LAN form: repository -> machine/agent -> base branch -> real outbox."""
import json
from pathlib import Path
import subprocess
import sys
import time

import catalog
from driver import BUNDLE_ID, UI

ui = UI(sys.argv[1], sys.argv[2])


def tap(identifier):
    ui.element(identifier)
    ui.axe('tap', '--id', identifier, '--post-delay', '.6')


def back():
    item = ui.wait(lambda items: max((i for i in items if i.get('type') == 'Button' and i.get('AXLabel') in ['Back', catalog.text('create.title')]), key=lambda i: i['frame']['y'], default=None), 'Missing foreground Back')
    f = item['frame']
    ui.axe('tap', '-x', str(f['x'] + min(f['width'], 44) / 2), '-y', str(f['y'] + f['height'] / 2), '--post-delay', '.6')
    ui.element('create-session-input')


def selected(name):
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'branch' and name in str(i.get('AXLabel', '')) + str(i.get('AXValue', '')) for i in items), 'Base branch not ' + name)


def search(value):
    tap('list-search')
    ui.axe('type', value)
    expected = value.strip().casefold()
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'list-search' and (i.get('AXValue') or '').strip().casefold() == expected for i in items), 'Search lost input')


def pick_repo(name, first=False):
    tap('project')
    if first:
        f = ui.element('list-segments')['frame']
        ui.axe('tap', '-x', str(f['x'] + f['width'] * .75), '-y', str(f['y'] + f['height'] / 2), '--post-delay', '.6')
    tap('github:Owner/' + name)
    ui.element('branch')


# Self-resetting scene: all repository/options/branch I/O is injected; no hub or account.
ui.open_case('create-lan')
ui.element('create-session-input')
pick_repo('Paged', first=True)
tap('machine')
tap('lan-mac')
tap('agent')
tap('lan-mac:remote')
selected('trunk')
tap('branch')
assert not any((i.get('AXUniqueId') or '').startswith('typed:') for i in ui.state()), 'Empty search offered a guessed branch'
search('SEARCH-ACROSS')
# Searching follows the next page, including while a manual candidate is available.
tap('branch:feature/search-across-pages')
selected('feature/search-across-pages')
ui.capture('paged-selected')
tap('branch')
search('discard-this')
ui.element('typed:discard-this')
back()
selected('feature/search-across-pages')

pick_repo('Empty')
tap('branch')
ui.element('branches-empty')
assert not any((i.get('AXUniqueId') or '').startswith('typed:') for i in ui.state()), 'Empty repository guessed a branch'
search('release-empty')
ui.element('typed:release-empty')
ui.capture('empty-manual-candidate')
back()
assert 'release-empty' not in str(ui.element('branch')), 'Cancelling committed a manual candidate'

pick_repo('Unavailable')
tap('branch')
ui.element('branches-more')
search('  release-next  ')
row = ui.element('typed:release-next')
assert catalog.text('create.branch.use', name='release-next') in (row.get('AXLabel') or ''), row
assert row['frame']['height'] >= 44, 'Manual branch target must be at least 44 pt'
assert row['frame']['y'] < ui.element('branches-more')['frame']['y']
ui.capture('failed-list-manual')
tap('typed:release-next')
selected('release-next')
# Explicit selection survives a second cancelled candidate and the failed list.
tap('branch')
search('discard-again')
back()
selected('release-next')
ui.capture('manual-selected')
tap('create-session-input')
ui.wait_for_keyboard('create-session-input')
ui.type_into('create-session-input', 'First LAN turn')
ui.capture('ready-to-submit')
tap('session-send')

container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', ui.udid, BUNDLE_ID, 'data'], text=True).strip())
evidence_file = container / 'tmp/lody-lan-create.json'
deadline = time.monotonic() + 15
while not evidence_file.exists():
    assert time.monotonic() < deadline, 'Production submission did not persist an outbox record'
    time.sleep(.2)
evidence = json.loads(evidence_file.read_text())
assert evidence['repositoriesRequested'], 'Repository picker bypassed the service'
assert 'Owner/Paged:2' in evidence['branchRequests'], 'Search never read the later branch page'
assert 'Owner/Unavailable:1' in evidence['branchRequests']
assert 'github:Owner/Unavailable' in evidence['optionProjects']
assert evidence['outbox']['ready'] is True
records = evidence['outbox']['records']
assert len(records) == 1, records
record = records[0]
creation = json.loads(record['send']['creation'])
assert record['send']['phase'] == 'waiting' and record['send']['text'] == 'First LAN turn'
assert record['send']['id'], 'First turn has no id'
assert record['session']['id'] == creation['sessionId'] == 'ui-lan-create'
assert record['session']['projectId'] == creation['projectId'] == 'github:Owner/Unavailable'
assert creation['branch'] == 'release-next', 'Trimmed manual base branch did not reach creation payload'
assert creation['machineId'] == 'lan-mac' and creation['agentConfigId'] == 'remote'
assert creation['workspaceId'] == 'lw_ui-create' and creation['userId'] == 'local:ui-create'
(ui.output / 'outbox.json').write_text(json.dumps(evidence, indent=2))
print('PASS: production LAN repository/machine/agent and paged/manual branch selection submit the first turn through ordinary OutboxSession.put')
