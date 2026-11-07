"""Offline LAN media uses the native gallery/Quick Look and retains a failed draft."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])

def tap(identifier):
    frame = ui.element(identifier)['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.3')


def editor_attachments():
    for name in ['notes.txt', 'photo.png']:
        label = catalog.text('native.chat.attachment.preview', name=name)
        ui.wait(lambda items: any(item.get('AXLabel') == label for item in items), 'Editor lost attachment: ' + name)


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
editor_attachments()
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

# Independent reset. Transport generations change while the synthetic account,
# LAN id and catalog workspace remain constant; identity uses the production key helper.
ui.open_case('lan-files-recovery')
failed = catalog.text('native.chat.image.failed')
loaded = catalog.text('native.chat.image.loaded')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'lan-agent:photo:image:0' and item.get('AXValue') == failed for item in items), 'Initial member failure not shown on the thumbnail')
tap('lan-agent:photo:image:0')
ui.element('chat-image-retry')
ui.capture('lan-gallery-runtime-error')
tap('chat-image-retry')
ui.wait(lambda items: not any(item.get('AXUniqueId') in ['chat-image-retry', 'chat-image-loading'] for item in items), 'Gallery stayed busy/failed after explicit retry')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'lan-agent:photo:image:0' and item.get('AXValue') == loaded for item in items), 'A didCache notification did not refresh the failed thumbnail')
status_contains('3 image fetch')
ui.capture('lan-thumbnail-notification-refreshed')
# A new runtime with an offline member must still open the existing cached digest.
tap('lan-files-recover')
tap('lan-agent:photo:image:0')
ui.element('chat-image-preview')
ui.wait(lambda items: not any(item.get('AXUniqueId') in ['chat-image-retry', 'chat-image-loading'] for item in items), 'Warm cached gallery required the offline member')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
status_contains('3 image fetch')
ui.capture('lan-warm-cache-after-recovery')
# Quick Look's first read fails after an epoch change, then offers native Retry.
tap('lan-user:attachment:notes')
ui.wait(lambda items: any('Offline member unavailable' in (item.get('AXLabel') or '') for item in items), 'Quick Look recovery did not finish with a retryable error')
ui.axe('tap', '--label', catalog.text('native.attachment.preview.retry'), '--post-delay', '.3')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'QLOverlayMarkupButtonAccessibilityIdentifier' for item in items), 'Quick Look retry did not load')
ui.capture('lan-quicklook-runtime-retry')
frame = ui.element('QLPreviewControllerView')['frame']
ui.axe('drag', '--start-x', str(frame['x'] + frame['width'] / 2), '--start-y', str(frame['y'] + 16), '--end-x', str(frame['x'] + frame['width'] / 2), '--end-y', str(frame['y'] + frame['height'] - 24), '--duration', '.5', '--post-delay', '.4')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'QLPreviewControllerView' for item in items), 'Quick Look did not dismiss')
# Preparation fails during recovery, then succeeds on explicit retry.
tap('lan-files-edit')
ui.element('edit-message-retry')
ui.capture('lan-edit-prepare-runtime-error')
tap('edit-message-retry')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'edit-message-input' and item.get('AXValue') == 'Edit this LAN prompt' for item in items), 'Editor did not recover the prepared text and files')
tap('session-send')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'edit-message-retry' and item.get('AXLabel') == catalog.text('chat.edit.check') for item in items), 'Sending after epoch replacement did not leave the busy phase')
assert ui.element('edit-message-input').get('AXValue') == 'Edit this LAN prompt'
editor_attachments()
ui.capture('lan-edit-send-runtime-draft-restored')
tap('edit-message-retry')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'edit-message-retry' and item.get('AXLabel') == catalog.text('chat.edit.check') and item.get('enabled') for item in items), 'Confirmation epoch replacement left the editor busy')
ui.axe('tap', '--label', catalog.text('common.cancel'), '--post-delay', '.4')
ui.wait(lambda items: not any(item.get('AXUniqueId') == 'edit-message-input' for item in items), 'Recovered editor could not be cancelled')
status_contains('1 edit sends')
ui.capture('lan-edit-runtime-cancelled')
print('PASS: stable account identity, cached offline recovery, thumbnail notification, gallery/Quick Look retry and editable/cancellable recovery without replay')
