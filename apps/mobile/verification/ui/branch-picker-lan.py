"""A LAN's branch picker takes a typed name when its hub lists none; offline, no hub or credential."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def tap(identifier):
    ui.element(identifier)
    ui.axe('tap', '--id', identifier, '--post-delay', '.6')


def search(value):
    f = ui.element('list-search')['frame']
    ui.axe('tap', '-x', str(f['x'] + f['width'] / 2), '-y', str(f['y'] + f['height'] / 2), '--tap-style', 'physical', '--post-delay', '.4')
    ui.axe('type', value)
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'list-search' and (i.get('AXValue') or '').casefold() == value.casefold() for i in items), 'Search lost characters during list refresh')


def typed_rows():
    return [i for i in ui.state() if (i.get('AXUniqueId') or '').startswith('typed:')]


ui.element('create-session-input')
ui.element('branch')
tap('branch')
# The fixture LAN has no hub to ask, so the list fails without a request leaving the device.
ui.element('branches-more')
ui.wait(lambda items: any(catalog.text('create.branch.failed') in (i.get('AXLabel') or '') for i in items), 'Missing failed-load retry')
assert not typed_rows(), 'An empty search must not offer a branch'
ui.capture('load-failed')
search('release-next')
row = ui.wait(lambda items: next((i for i in items if (i.get('AXUniqueId') or '').casefold() == 'typed:release-next'), None), 'A LAN must offer the typed name')
assert catalog.text('create.branch.use', name='release-next').casefold() in (row.get('AXLabel') or '').casefold(), row.get('AXLabel')
assert row['frame']['y'] < ui.element('branches-more')['frame']['y'], 'The typed name must head the list'
ui.capture('typed-branch')
ui.axe('tap', '--id', row['AXUniqueId'], '--post-delay', '.6')
ui.element('create-session-input')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'branch' and 'release-next' in (str(i.get('AXLabel', '')) + str(i.get('AXValue', ''))).casefold() for i in items), 'Typed branch did not reach the form')
ui.capture('selected-branch')
print('PASS: a LAN whose branch list fails to load keeps its retry row and takes a typed base branch')
