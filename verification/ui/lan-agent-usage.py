"""Production agent settings: account-scoped quota, old quota fallback, Gemini and Argon."""
import json
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def spoken(item):
    return ' '.join(str(item.get(key) or '') for key in ('AXLabel', 'AXValue')) + ' ' + ' '.join(spoken(child) for child in item.get('children') or [])


def reveal(identifier):
    for _ in range(12):
        items = ui.state()
        row = next((i for i in items if i.get('AXUniqueId') == identifier), None)
        if row and 110 < row['frame']['y'] and row['frame']['y'] + row['frame']['height'] < items[0]['frame']['height'] - 40:
            return row
        ui.axe('drag', '--start-x', '180', '--start-y', '700', '--end-x', '180', '--end-y', '300', '--duration', '.4', '--post-delay', '.3')
    raise AssertionError(f'Missing quota {identifier}')


personal = reveal('usage:scoped:codex:personal:0')
assert catalog.text('settings.usage.used', percent=13) in spoken(personal)
assert not any('Other account quota' in spoken(i) or 'Legacy quota' in spoken(i) for i in ui.state()), 'A scoped account borrowed another quota'
ui.capture('config-scoped')
legacy = reveal('usage:legacy:codex:legacy:0')
assert catalog.text('settings.usage.used', percent=29) in spoken(legacy)
ui.capture('legacy-provider')
for group, percent in [('gemini', 17), ('argon', 62)]:
    ring = reveal(f'usage:agy:antigravity-acp:{group}:0')
    assert group.capitalize() in spoken(ring), spoken(ring)
    assert catalog.text('settings.usage.used', percent=percent) in spoken(ring)
assert not any('Old model name' in spoken(i) or i.get('AXUniqueId') == 'usage:agy:antigravity-acp:other:0' for i in ui.state())
ui.capture('gemini-and-argon')
print(json.dumps({'configScoped': True, 'legacyFallback': True, 'geminiArgon': True}))
