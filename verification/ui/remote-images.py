"""Real Markdown image taps enter the production gallery using public HTTP bytes."""
import json
import sys
import catalog
from driver import UI
ui = UI(*sys.argv[1:])
HTTP = 'http://offline-image.invalid/picture.png'
HTTPS = 'https://offline-image.invalid/picture.png'

def probe(items=None):
    item = next((i for i in (items if items is not None else ui.state()) if i.get('AXUniqueId') == 'remote-images-probe'), None)
    return json.loads((item or {}).get('AXValue') or '{}')

def target(href, image, row='remote-images:answer'):
    return ui.wait(lambda items: next((x for x in probe(items).get('targets', [])
                                      if x['href'] == href and x['image'] == image and x['row'] == row), None),
                   'Missing rendered Markdown run: ' + row + ' ' + href)

def tap(point):
    ui.axe('tap', '-x', str(point['x']), '-y', str(point['y']), '--post-delay', '.5')

def public_requests(count):
    requests = probe()['requests']
    assert len(requests) == count and not any(x['authorized'] for x in requests), requests
    assert all(x['url'] in (HTTP, HTTPS) for x in requests), requests
    return requests

ui.wait(lambda items: probe(items).get('cloudReferenceBlocked') is True, 'LAN protected image did not retain its boundary')
assert probe()['requests'] == [], probe()
first_image = target(HTTP, True)
assert first_image['start'] == 0, 'The first image must exercise the synthetic range-zero boundary'
body = ui.element('remote-images:answer')
for source in [HTTP, HTTPS]:
    action = catalog.text('native.chat.image.label', name=source) + ' · ' + catalog.text('native.chat.image.openPreview')
    assert action in body.get('custom_actions', []), body
assert len(body.get('custom_actions', [])) == 4, 'Code image syntax acquired an action'
ui.capture('markdown-image-and-same-url-link')

# An ordinary link with exactly the image href must remain an ordinary link.
tap(target(HTTP, False))
ui.wait(lambda items: probe(items).get('links') == [HTTP], 'Same-href text link was treated as a parsed image')
assert probe()['host'] == 'fixture' and probe()['requests'] == [], probe()
# The production file icon calls linkHandler with (0,0), while an image occupies offset 0.
icon = ui.wait(lambda items: probe(items).get('fileIcon'), 'Missing production file link icon')
tap(icon)
ui.wait(lambda items: probe(items).get('files') == ['docs/README.md'], 'File icon was mistaken for the image at offset zero')
assert probe()['host'] == 'fixture' and probe()['requests'] == [], probe()
# Inline Markdown image syntax is still literal, including its URL.
code = ui.wait(lambda items: next(iter(probe(items).get('code', [])), None), 'Missing literal inline code')
tap(code)
assert probe()['host'] == 'fixture' and probe()['requests'] == [] and probe()['links'] == [HTTP], probe()

ui.axe('tap', '--id', 'remote-images-share', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('paperReady') is True, 'HTTP Markdown pictures did not generate a share image')
assert ui.element('message-share-preview').get('AXValue', '').startswith('1080 × ')
requests = public_requests(2)
assert {x['url'] for x in requests} == {HTTP, HTTPS}, requests
ui.capture('lan-http-share-image')
ui.axe('tap', '--label', catalog.text('accessibility.closeSheet', title=catalog.text('native.chat.message.preview')), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Share preview did not close')

# These are actual Litext run coordinates; the fixture never constructs a gallery item.
for count, href, row, name in [(3, HTTP, 'remote-images:answer', 'http'),
                               (4, HTTPS, 'remote-images:answer', 'https'),
                               (5, HTTPS, 'remote-images:plan', 'plan')]:
    tap(target(href, True, row))
    ui.wait(lambda items: probe(items).get('galleryReady') is True, 'Parsed image tap did not load in the production gallery')
    ui.element('chat-image-preview')
    requests = public_requests(count)
    assert requests[-1]['url'] == href, requests
    assert probe()['links'] == [HTTP] and probe()['files'] == ['docs/README.md'], probe()
    ui.capture('lan-markdown-large-image-' + name)
    ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
    ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Large preview did not close')
print('PASS: production Markdown HTTP/HTTPS and plan image taps, same-href ordinary link, file icon range zero, literal code, share JPEG, no public bearer and protected references blocked')

def table_link(row, host):
    before = probe()
    count = len(before['links'])
    tap(target(HTTP, False, row=row))
    def routed(items):
        added = probe(items).get('links', [])[count:]
        return bool(added) and all(href == HTTP for href in added)
    ui.wait(routed, 'Table link did not route its own href')
    after = probe()
    assert after['host'] == host and after['files'] == before['files'], after
    assert after['requests'] == before['requests'] and not after['galleryReady'], after

# A cell-local range can be much larger than the body attachment label.
ui.axe('tap', '--label', catalog.text('accessibility.closeSheet', title='External images'), '--post-delay', '.4')
ui.wait(lambda items: not probe(items), 'Body fixture did not close')
ui.open_case('remote-images-table')
ui.wait(lambda items: probe(items).get('scenario') == 'table' and probe(items).get('cloudReferenceBlocked'), 'Table fixture did not load')
table_link('remote-images:answer', 'fixture')
tap(target(HTTPS, True))
ui.wait(lambda items: probe(items).get('galleryReady'), 'Inline table picture did not open')
public_requests(1)
ui.capture('inline-table-image')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Inline table image did not close')
ui.axe('tap', '--label', 'Expand', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('host') == 'table', 'Expanded table did not open')
table_link('', 'table')
tap(target(HTTPS, True, row=''))
ui.wait(lambda items: probe(items).get('galleryReady'), 'Expanded table picture did not open')
public_requests(2)
ui.capture('expanded-table-image')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'table', 'Expanded table image did not return')
ui.capture('expanded-table-return')
ui.axe('tap', '--label', 'More', '--post-delay', '.3')
ui.axe('tap', '--label', 'Close', '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Expanded table did not close')
print('PASS: inline and expanded table links use their own highlight payloads, with no body-range indexing')
