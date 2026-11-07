"""Offline LAN media uses the native gallery/Quick Look and retains a failed draft."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])

def tap(identifier):
    frame = ui.element(identifier)['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.3')


def status_contains(text):
    return ui.wait(lambda items: any(item.get('AXUniqueId') == 'lan-files-status' and text in (item.get('AXLabel') or '') for item in items), 'LAN status missing: ' + text)


status_contains('1 image fetch')
ui.element('lan-agent:photo:image:0')
ui.element('lan-user:attachment:photo-1')
ui.capture('lan-local-pictures')
tap('lan-agent:photo:image:0')
ui.element('chat-image-preview')
ui.capture('lan-gallery')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
status_contains('1 image fetch')
tap('lan-user:attachment:notes')
ui.wait(lambda items: any('Offline member unavailable' in (item.get('AXLabel') or '') for item in items), 'Member failure not shown')
ui.capture('lan-file-failed')
ui.axe('tap', '--label', catalog.text('native.attachment.preview.retry'), '--post-delay', '.3')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'QLOverlayMarkupButtonAccessibilityIdentifier' for item in items), 'Retry did not open native Quick Look')
ui.capture('lan-file-retried')
frame = ui.element('QLPreviewControllerView')['frame']
ui.axe('drag', '--start-x', str(frame['x'] + frame['width'] / 2), '--start-y', str(frame['y'] + 16), '--end-x', str(frame['x'] + frame['width'] / 2), '--end-y', str(frame['y'] + frame['height'] - 24), '--duration', '.5', '--post-delay', '.4')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'QLPreviewControllerView' for item in items), 'Quick Look did not dismiss')
tap('session-input')
assert ui.element('session-input').get('AXValue') == 'Retain LAN text and file'
tap('session-send')
status_contains('1 restored')
assert ui.element('session-input').get('AXValue') == 'Retain LAN text and file'
ui.capture('lan-failed-draft-restored')
tap('lan-files-edit')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'edit-message-input' and item.get('AXValue') == 'Edit this LAN prompt' for item in items), 'LAN editor did not restore the prepared prompt')
tap('session-send')
ui.element('edit-message-error')
assert ui.element('edit-message-input').get('AXValue') == 'Edit this LAN prompt'
ui.capture('lan-edit-failed-draft-restored')
ui.axe('tap', '--label', catalog.text('common.cancel'), '--post-delay', '.4')
# Re-enter through a deep link for an independent reset; this provider returns late.
ui.open_case('lan-files-late')
tap('lan-files-switch')
ui.wait(lambda items: not any((item.get('AXUniqueId') or '').startswith('lan-agent:') for item in items), 'Old account rows retained')
status_contains('1 finished')
assert not any((item.get('AXUniqueId') or '').startswith('lan-agent:') for item in ui.state()), 'Late old-account picture returned'
ui.capture('lan-account-switched')
print('PASS: local user/agent pictures, one digest fetch across gallery, retryable kept file, failed text+file draft and account switch')
