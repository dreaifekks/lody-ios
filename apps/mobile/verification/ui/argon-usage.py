"""Independent Antigravity quotas use production settings rows, offline."""
import sys
from driver import UI
ui = UI(*sys.argv[1:])
gemini = ui.element('usage:m1:antigravity-acp:gemini:0')
argon = ui.element('usage:m1:antigravity-acp:argon:0')
assert 'Gemini' in str(gemini) and '30% used' in str(gemini)
assert 'Argon' in str(argon) and '40% used' in str(argon)
assert not any('third-party' in (i.get('AXUniqueId') or '') for i in ui.state())
assert abs(argon['frame']['y'] - gemini['frame']['y']) >= 44
ui.capture('gemini-and-argon')
print('PASS: Gemini and Argon independent windows with semantic usage labels; third-party excluded')
