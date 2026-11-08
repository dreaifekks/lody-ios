"""Delegated identity is displayed separately from the unchanged message body."""
import sys
from driver import UI

ui = UI(*sys.argv[1:])
row = ui.element('delegated:user')
assert row['AXLabel'] == 'iosDev · Mini · Planner · GPT\nCheck the native chat layout.', row
human = ui.element('human:user')
assert human['AXLabel'] == 'A message without an author stays unchanged.', human
ui.capture('delegated-author')
print('PASS: projected Role, instance, agent name and model; unchanged authorless message')
