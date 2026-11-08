"""Exercise the integrated UIKit client on the owned synthetic tailnet hub."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ui'))
from driver import UI, configure_app
import catalog

root = Path('.artifacts/home-tailnet')
udid = os.environ['LODY_VERIFY_UDID']
app = sys.argv[1]
bundle, _ = configure_app(app)
ui = UI(udid, root / 'ui')
state = json.loads((root / 'state.json').read_text())
assert state['base'].startswith('http://100.122.16.85:')
video = subprocess.Popen(['xcrun', 'simctl', 'io', udid, 'recordVideo', '--force', '--codec=h264', str(root / 'integrate.mp4')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def tap(identifier):
    ui.element(identifier)
    ui.axe('tap', '--id', identifier, '--post-delay', '.4')


def events():
    return [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]


def send(name):
    prior = {event['userTurnId'] for event in events() if event['event'] == 'durable_turn_before_dispatch'}
    tap('session-send')
    result = ui.wait(lambda _: next((event for event in events() if event['event'] == 'durable_turn_before_dispatch' and event['userTurnId'] not in prior), None), 'No durable turn dispatched', timeout=60)
    turn = result['userTurnId']
    ui.wait(lambda items: any((item.get('AXUniqueId') or '').startswith('home-answer-' + turn + ':') for item in items), 'No synchronized synthetic reply', timeout=60)
    ui.capture(name)
    return result


try:
    subprocess.run([sys.executable, str(Path(__file__).with_name('live.py')), app], check=True)
    # Connection -> account -> settings, then refresh each production settings page.
    tap('BackButton')
    tap('BackButton')
    for identifier, expected, name in [
        ('remote-machine', 'Online Mini', 'machines'),
        ('remote-agent', 'Synthetic Claude', 'agents'),
        ('remote-mcp', 'Synthetic MCP', 'mcp'),
        ('agent-roles', 'Synthetic Role', 'roles'),
        ('memory-settings', 'Synthetic Memory', 'memory'),
    ]:
        tap(identifier)
        ui.wait(lambda items: any(expected in (item.get('AXLabel') or '') for item in items), expected + ' did not load', timeout=60)
        # Pull to refresh through the production controller, then require its rows again.
        ui.axe('drag', '--start-x', '200', '--start-y', '230', '--end-x', '200', '--end-y', '650', '--duration', '.8', '--post-delay', '1')
        ui.wait(lambda items: any(expected in (item.get('AXLabel') or '') for item in items), expected + ' did not refresh', timeout=60)
        ui.capture('tailnet-settings-' + name)
        tap('BackButton')
    ui.axe('tap', '--label', catalog.text('accessibility.closeSheet', title=catalog.text('tabs.settings')), '--post-delay', '.5')
    # By Machine keeps both groups expanded after the connection check.
    tap('home-mini-session')
    author = ui.element('home-mini-session-delegated:user', timeout=60)
    assert author.get('AXLabel') == 'iosDev · Mini · Planner · GPT\nSynthetic author on tailnet.', author
    board = ui.wait(lambda items: next((item for item in items if (item.get('AXUniqueId') or '').startswith('home-mini-session-board:')), None), 'Projected Board row missing')
    assert board.get('AXLabel') == '2 task results\nLayout check · Completed\nWire check · Failed', board
    link = ui.wait(lambda items: next((item for item in items if (item.get('AXUniqueId') or '').startswith('home-mini-session-link:')), None), 'Projected session link missing')
    assert 'Open synthetic session' in link.get('AXLabel', '') and link.get('custom_actions'), link
    ui.capture('tailnet-chat-author-board-link')
    # Tap the rendered link text, then prove native navigation uses the catalog target.
    frame = link['frame']
    ui.axe('tap', '-x', str(frame['x'] + 80), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.5')
    ui.wait(lambda items: any('Offline NUC synthetic history is readable.' in (item.get('AXLabel') or '') for item in items), 'Session link did not open the catalog target', timeout=60)
    ui.capture('tailnet-session-link-opened')
    tap('BackButton')
    tap('home-mini-session')
    tap('session-input')
    ui.axe('type', 'Integrated tailnet text turn')
    send('tailnet-text-send-completed')
    tap('session-input')
    tap('session-mention')
    tap('mention-item:role')
    first = ui.element('mention-picker-item:home-role@home-mini@home-instance-mini')
    second = ui.element('mention-picker-item:home-role@home-mini@home-instance-mini-two')
    remote = ui.element('mention-picker-item:home-role@home-nuc')
    assert max(first['frame']['y'], second['frame']['y']) < remote['frame']['y'], 'Local instances must sort before offline NUC'
    ui.capture('tailnet-role-instances')
    tap('mention-picker-item:home-role@home-mini@home-instance-mini-two')
    assert '@role:home-role@home-mini@home-instance-mini-two' in ui.element('session-input').get('AXValue', '')
    ui.axe('type', 'Integrated instance role turn')
    result = send('tailnet-role-send-completed')
    text = json.dumps(result['turn'])
    assert 'home-instance-mini-two' in text and 'agentRoleInstanceId' in text and 'home-mini' in text, text
    outcome = json.loads((root / 'outcome.json').read_text())
    outcome.update(settingsRefresh=True, author=True, board=True, sessionLink=True, plainSend=True, instanceRoleSend=True)
    (root / 'outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
    print('PASS: integrated tailnet settings, author, Board, catalog link, durable plain/instance Role sends', flush=True)
finally:
    video.send_signal(signal.SIGINT)
    video.wait(timeout=20)
