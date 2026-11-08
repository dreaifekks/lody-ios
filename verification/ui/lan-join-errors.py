"""Join form preserves distinct actionable failure causes, without credentials/network."""
import sys
from driver import UI
import catalog
ui = UI(sys.argv[1], sys.argv[2])
ui.axe('tap', '--id', 'lan-invite')
ui.axe('type', 'lody-lan://offline-fixture@offline.invalid')
for cause in ['invalidInvite', 'unauthorized', 'unreachable']:
    ui.axe('tap', '--id', 'lan-join-submit')
    expected = catalog.text('lan.error.' + cause)
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'lan-join-error' and i.get('AXLabel') == expected for i in items), cause)
    ui.capture('join-' + cause)
ui.axe('tap', '--id', 'lan-join-submit')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'join-lan-form' for i in items), 'Successful retry closes form')
