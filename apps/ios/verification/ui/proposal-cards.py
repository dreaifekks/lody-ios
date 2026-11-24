"""Offline proposal/file cards through the production transcript and controls."""
import sys
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])


def text(value):
    ui.wait(lambda items: any(value in str(i.get('AXLabel') or '') for i in items),
            f'Missing rendered text: {value}')


def scene(name):
    ui.open_case('session-preview-cards-' + name)
    ui.wait(lambda items: any(
        i.get('AXUniqueId') == 'session-preview-probe'
        and i.get('AXLabel') == 'Offline card review: cards-' + name
        and 'live' in str(i.get('AXValue') or '').split(',') for i in items),
        f'Card scene did not become live: {name}')


def button(item, action='confirm', enabled=True):
    control = ui.element(f'preview-answer:{item}:{action}')
    assert control.get('enabled') is enabled, control
    return control


def tap(item, action='confirm'):
    ui.axe('tap', '--id', f'preview-answer:{item}:{action}')


def absent_buttons():
    ui.wait(lambda items: not any(
        str(i.get('AXUniqueId') or '').endswith((':confirm', ':dismiss'))
        for i in items), 'Decided proposal still exposes decision buttons')


scene('role-create')
text('Reviewer')
button('create')
button('create', 'dismiss')
ui.capture('role-create')
tap('create')
text(catalog.text('native.chat.proposal.role.saved'))
absent_buttons()
ui.capture('role-create-saved')

scene('role-update')
text('Release reviewer')
text('Reviews changes.')
button('update')
ui.capture('role-update-before-after')
tap('update', 'dismiss')
text(catalog.text('native.chat.proposal.dismissed'))
absent_buttons()

scene('owner-only')
text(catalog.text('native.chat.proposal.role.ownerOnly'))
button('owner', enabled=False)
button('owner', 'dismiss', enabled=False)
ui.capture('owner-only-disabled')

scene('receipts')
text(catalog.text('native.chat.proposal.role.saved'))
text(catalog.text('native.chat.proposal.dismissed'))
absent_buttons()
ui.capture('saved-dismissed')

scene('states')
text(catalog.text('native.chat.proposal.error.failed'))
button('error')
button('pending', enabled=False)
button('pending', 'dismiss', enabled=False)
ui.capture('error-pending-spinner')

scene('files')
text('report.pdf')
text('notes.md')
text('PDF · 240 KB')
text('MD · 3 KB')
ui.capture('two-files')

scene('schedule-edit')
text(catalog.text('native.chat.proposal.edit.title'))
text('Morning review')
text('+ Post in the team chat with owners.')
text('− Post in the team chat.')
assert button('edit-pending')['AXLabel'] == catalog.text('native.chat.proposal.edit.apply')
button('edit-pending', 'open')
button('edit-pending', 'dismiss')
assert button('edit-applied')['AXLabel'] == catalog.text('native.chat.proposal.open')
ui.capture('schedule-edit-pending-applied')
tap('edit-pending')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'preview-answer:edit-pending:confirm'
                         and i.get('AXLabel') == catalog.text('native.chat.proposal.open')
                         for i in items),
        'Applied edit did not become a receipt with Open')
text(catalog.text('native.chat.proposal.edit.applied'))
ui.capture('schedule-edit-applied')

scene('schedule-edit-states')
text(catalog.text('native.chat.proposal.edit.stale'))
text(catalog.text('native.chat.proposal.edit.unavailable'))
text(catalog.text('native.chat.proposal.edit.notOwner'))
button('edit-stale', enabled=False)
button('edit-stale', 'dismiss')
button('edit-deleted', enabled=False)
button('edit-deleted', 'dismiss')
button('edit-teammate', enabled=False)
button('edit-teammate', 'dismiss', enabled=False)
ui.capture('schedule-edit-refused')

scene('notices')
text('This conversation was forked from Fix the login redirect')
text(catalog.text('native.chat.notice.resumeHistoryTruncated'))
text(catalog.text('native.chat.warning.stopTimedOut'))
text(catalog.text('native.chat.warning.stopTimedOutGuidance'))
ui.element('preview-answer:warning:details')
text('worktree setup')
ui.wait(lambda items: not any('never shown' in str(i.get('AXLabel') or '') for i in items),
        'An unknown notice rendered')
text(catalog.text('native.chat.error.acp_auth_required'))
ui.capture('system-notices')


def close_sheet(gone):
    """Pull the sheet down by its header: the system dismissal, whatever the page's own close control is."""
    ui.axe('drag', '--start-x', '200', '--start-y', '110', '--end-x', '200', '--end-y', '800', '--duration', '.4')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == gone for i in items), f'Sheet did not close: {gone}')


# Sign in opens the machine sign-in flow (synthetic provider); Details opens the warning text.
tap('auth', 'signIn')
ui.element('provider-auth-status')
ui.capture('agent-sign-in')
close_sheet('provider-auth-status')
tap('warning', 'details')
text('SIGTERM sent; the process is still running.')
ui.capture('agent-warning-details')
close_sheet('agent-error-report')

# Open ends in a sheet; keep navigation last so it cannot cover later root scenes.
scene('schedules')
assert button('schedule-pending')['AXLabel'] == catalog.text('native.chat.proposal.create')
assert button('schedule-created')['AXLabel'] == catalog.text('native.chat.proposal.open')
ui.capture('schedule-pending-created')
tap('schedule-pending')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'preview-answer:schedule-pending:confirm'
                         and i.get('AXLabel') == catalog.text('native.chat.proposal.open')
                         and i.get('enabled') is True for i in items),
        'Created schedule did not expose Open')
ui.capture('schedule-create-receipt')
tap('schedule-created')
# Open goes straight to that schedule's editor, over the Schedules list.
ui.element('schedule-frequency')
ui.capture('schedule-open')

