"""Software shortcut geometry and wire bytes on the credential-free terminal fixture."""
import catalog


def check_shortcuts(ui):
    ui.wait_for_keyboard('terminal-view')
    scroll = ui.element('terminal-keyboard-scroll')['frame']
    order = ['escape', 'control', 'tab', 'tilde', 'pipe', 'slash', 'dash',
        'left', 'down', 'up', 'right', 'mouse'] + [f'f{i}' for i in range(1, 11)]

    def type_text(text):
        ui.axe('type', text)
        ui.restore_software_keyboard()
        ui.wait_for_keyboard('terminal-view')

    def key(name):
        identifier = 'terminal-key-' + name
        if name == 'hide':
            item = ui.element(identifier)
            assert round(item['frame']['width'], 6) >= 44 and round(item['frame']['height'], 6) >= 44, item
            return item
        for _ in range(8):
            items = ui.state()
            item = next((i for i in items if i.get('AXUniqueId') == identifier), None)
            if item:
                f = item['frame']
                assert round(f['width'], 6) >= 44 and round(f['height'], 6) >= 44, item
                if f['x'] >= scroll['x'] - .5 and f['x'] + f['width'] <= scroll['x'] + scroll['width'] + .5:
                    return item
            y = scroll['y'] + scroll['height'] / 2
            left, right = scroll['x'] + 24, scroll['x'] + scroll['width'] - 24
            visible = [order.index(i['AXUniqueId'].removeprefix('terminal-key-')) for i in items
                if (i.get('AXUniqueId') or '').removeprefix('terminal-key-') in order
                and i['frame']['x'] >= scroll['x'] - .5
                and i['frame']['x'] + i['frame']['width'] <= scroll['x'] + scroll['width'] + .5]
            backwards = bool(visible) and order.index(name) < min(visible)
            start, end = (left, right) if backwards else (right, left)
            ui.axe('drag', '--start-x', str(start), '--start-y', str(y),
                   '--end-x', str(end), '--end-y', str(y), '--duration', '.4')
        raise AssertionError(f'Could not expose full-size shortcut {name}')

    def tap(name, expected=None):
        item = key(name)
        ui.axe('tap', '--id', 'terminal-key-' + name)
        if expected:
            ui.wait(lambda items: any(i.get('AXUniqueId') == 'terminal-fixture-input-hex'
                and i.get('AXValue') == expected for i in items), f'{name} did not send {expected}')
        return item

    expected_labels = {'escape': 'escape', 'control': 'control', 'tab': 'tab',
        'tilde': 'tilde', 'pipe': 'pipe', 'slash': 'slash', 'dash': 'dash',
        'left': 'left', 'down': 'down', 'up': 'up', 'right': 'right', 'mouse': 'mouse',
        'hide': 'hideKeyboard'}
    for name, label in expected_labels.items():
        assert key(name).get('AXLabel') == catalog.text('terminal.key.' + label), name
    for number in range(1, 11):
        assert key(f'f{number}').get('AXLabel') == catalog.text('terminal.key.function').replace('%lld', str(number))

    tap('escape', '1b')
    tap('tab', '09')
    for name, value in [('tilde', '7e'), ('pipe', '7c'), ('slash', '2f'), ('dash', '2d')]:
        tap(name, value)
    tap('control')
    assert key('control').get('AXValue') == catalog.text('terminal.key.on')
    ui.capture('shortcut-control-on')
    # Punctuation, Esc and Tab bypass the software Ctrl modifier in SwiftTerm.
    tap('tilde', '7e')
    assert key('control').get('AXValue') == catalog.text('terminal.key.on')
    type_text('c')
    ui.wait(lambda items: any(i.get('AXUniqueId') == 'terminal-fixture-input-hex'
        and i.get('AXValue') == '03' for i in items), 'Ctrl-C conversion failed')
    assert key('control').get('AXValue') == catalog.text('terminal.key.off')
    for name, suffix in [('left', '44'), ('down', '42'), ('up', '41'), ('right', '43')]:
        tap(name, '1b5b' + suffix)
    tap('control')
    type_text('c')
    type_text('fixture-app-cursor\n')
    for name, suffix in [('left', '44'), ('down', '42'), ('up', '41'), ('right', '43')]:
        tap(name, '1b4f' + suffix)
    tap('mouse')
    assert key('mouse').get('AXValue') == catalog.text('terminal.key.off')
    tap('mouse')
    assert key('mouse').get('AXValue') == catalog.text('terminal.key.on')
    ui.capture('shortcut-mouse-on')
    for number, value in enumerate(['1b4f50', '1b4f51', '1b4f52', '1b4f53',
        '1b5b31357e', '1b5b31377e', '1b5b31387e', '1b5b31397e', '1b5b32307e', '1b5b32317e'], 1):
        tap(f'f{number}', value)
    ui.capture('shortcut-targets')
    tap('hide')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'terminal-key-hide' for i in items), 'Hide keyboard did not dismiss accessory')
    ui.axe('tap', '--id', 'terminal-view')
    ui.wait_for_keyboard('terminal-view')
    # Restore the production fixture prompt for the surrounding lifecycle checks.
    tap('control')
    type_text('c')
    type_text('fixture-reset-shortcuts\n')
    key('escape')
    ui.capture('shortcut-restored')
