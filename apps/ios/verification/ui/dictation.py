"""Composer dictation through the scripted `--ui-verify-dictation` engine; no real microphone claim."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])
dictate = catalog.text('native.chat.composer.dictate')
stop = catalog.text('native.chat.composer.stopDictation')
send = catalog.text('native.chat.composer.send')
spoken = 'Check the failing build log'


def action(label):
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'session-send' and i.get('AXLabel') == label for i in items), f'Send button is not {label}')


def draft(predicate, message):
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'session-input' and predicate(i.get('AXValue') or '') for i in items), message)


ui.axe('tap', '--id', 'session-input', '--post-delay', '.8')
action(dictate)
ui.capture('offer')
ui.axe('tap', '--id', 'session-send', '--post-delay', '.3')
action(stop)
draft(lambda value: value == spoken, 'Volatile results did not reach the draft')
ui.capture('listening')
ui.axe('tap', '--id', 'session-send', '--post-delay', '.3')
draft(lambda value: value == spoken + '.', 'Stop did not land the final result')
action(send)
ui.capture('final')
print('Dictation: mic offer, live volatile text, stop and final result passed')
