"""Capture the production external-open boundary without installing Telegram."""
import subprocess
import sys
from pathlib import Path
from driver import UI, BUNDLE_ID
ui = UI(*sys.argv[1:])
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', ui.udid, BUNDLE_ID, 'data'], text=True).strip())
record = container / 'tmp/lody-opened-url.txt'
record.unlink(missing_ok=True)
ui.axe('tap', '--label', 'Pending fixtures')
ui.axe('tap', '--label', 'tg', '--post-delay', '.5')
frame = ui.element('tg:link')['frame']
ui.capture('telegram-link')
ui.axe('tap', '-x', str(frame['x'] + min(70, frame['width'] / 2)), '-y', str(frame['y'] + min(20, frame['height'] / 2)), '--post-delay', '.4')
ui.wait(lambda _: record.exists(), 'Telegram link did not reach system open boundary')
assert record.read_text() == 'tg://resolve?domain=lody_fixture'
assert not any(i.get('AXUniqueId') == 'pending-opened' for i in ui.state()), 'tg fell through to catalog routing'
ui.capture('telegram-open-requested')
print('PASS: tg reaches UIApplication open boundary; offline fixture records intent only')
