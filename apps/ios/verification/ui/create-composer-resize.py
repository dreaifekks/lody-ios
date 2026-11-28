"""New-session composer auto-grows while typing until context rows reach the header, then scrolls internally;
dragging the grabber upward expands over the context rows up to just below the header and drags back down."""
import sys
from driver import UI
import catalog

ui = UI(*sys.argv[1:])


def frame(identifier):
    return ui.element(identifier)['frame']


def visible(identifier):
    return any(item.get('AXUniqueId') == identifier and item.get('frame', {}).get('height', 0) > 0 for item in ui.state())


def nav_bottom(items):
    close_label = catalog.text('accessibility.closeSheet', title=catalog.text('create.title'))
    candidates = [
        item['frame']['y'] + item['frame']['height']
        for item in items
        if item.get('AXLabel') in (close_label, catalog.text('create.title'), catalog.text('common.back'))
        and item.get('frame', {}).get('y', 999) < 200
        and item.get('frame', {}).get('height', 0) > 0
    ]
    return max(candidates) if candidates else 100


def context_rows(items, composer_top):
    return [
        item for item in items
        if item.get('type') == 'Button'
        and item.get('AXValue') in ('Fixture Mac', 'Alpha')
        and item.get('frame', {}).get('height', 0) > 20
        and item['frame']['y'] + item['frame']['height'] <= composer_top + 2
    ]


def drag_grabber(to_y, duration='.5'):
    grip = frame('session-grabber')
    x = grip['x'] + grip['width'] / 2
    y = grip['y'] + grip['height'] / 2
    ui.axe('drag', '--start-x', str(x), '--start-y', str(y), '--end-x', str(x), '--end-y', str(to_y),
           '--duration', duration, '--post-delay', '.8')


ui.element('create-session-input')
ui.wait(lambda items: any(i.get('AXValue') == 'Fixture Mac' for i in items), 'Creation options did not load')
ui.capture('resting')

# Focus the composer and verify multi-line default height with grabber visible.
ui.axe('tap', '--id', 'create-session-input', '--tap-style', 'physical', '--post-delay', '.8')
ui.wait_for_keyboard('create-session-input')
ui.wait(lambda items: visible('session-grabber'), 'Focused new-session composer must show its grabber')
default_input = frame('create-session-input')
default_grabber = frame('session-grabber')
assert default_input['height'] >= 60, f'Default editing input shrank below multi-line height: {default_input}'
ui.capture('focused-default')

# Type many words via type_into (restores the software keyboard afterward):
# composer must auto-grow until Machine/Project reach the header, then stop growing and scroll internally.
long_prompt = ' '.join(f'word{index}' for index in range(90))
ui.type_into('create-session-input', long_prompt)
ui.wait_for_keyboard('create-session-input')
ui.wait(lambda items: frame('create-session-input')['height'] > default_input['height'] + 40,
        'Typing many lines did not auto-grow the new-session composer')
items = ui.state()
grown_input = frame('create-session-input')
grown_grabber = frame('session-grabber')
header_bottom = nav_bottom(items)
rows = context_rows(items, grown_grabber['y'])
assert len(rows) >= 2, f'Context rows must remain visible above the auto-grown composer; got {rows}'
top_row = min(rows, key=lambda item: item['frame']['y'])
assert top_row['frame']['y'] >= header_bottom - 4, \
    f'Auto-grow pushed the top context row under the header: row={top_row["frame"]}, header_bottom={header_bottom}'
assert top_row['frame']['y'] <= header_bottom + 48, \
    f'Auto-grow stopped too early before context rows reached the header: row={top_row["frame"]}, header_bottom={header_bottom}'
ui.capture('auto-grown-cap')

# Drag the grabber upward to cover the context rows up to just below the header.
drag_grabber(header_bottom + 12)
ui.wait(lambda items: frame('session-grabber')['y'] < grown_grabber['y'] - 50,
        'Dragging the grabber upward did not expand over the context rows')
full_input = frame('create-session-input')
full_grabber = frame('session-grabber')
assert full_input['height'] > grown_input['height'] + 50, \
    f'Full-screen input did not reclaim the context height: inline={grown_input}, full={full_input}'
assert full_grabber['y'] >= header_bottom - 2, \
    f'Full-screen grabber overlapped the navigation bar: grabber={full_grabber}, header_bottom={header_bottom}'
assert full_grabber['y'] <= top_row['frame']['y'] + 10, \
    f'Full-screen composer did not cover the top context row: grabber={full_grabber}, top_row={top_row["frame"]}'
ui.capture('drag-fullscreen')

# Drag back down to return to inline height and uncover the context rows.
drag_grabber(grown_grabber['y'] + 60)
ui.wait(lambda items: abs(frame('session-grabber')['y'] - grown_grabber['y']) <= 12,
        'Dragging the grabber down did not return to inline height')
assert visible('session-send'), 'Dragging down from full screen must keep editing active'
ui.capture('collapsed-inline')
print('PASS: new-session composer auto-grows to header ceiling, scrolls internally, and grabber covers context rows')
