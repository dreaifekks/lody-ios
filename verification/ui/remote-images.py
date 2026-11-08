"""LAN share/large preview load real HTTP bytes without Cloud authorization."""
import json
import sys
import catalog
from driver import UI
ui = UI(*sys.argv[1:])

def probe(items=None):
    item = next((i for i in (items if items is not None else ui.state()) if i.get('AXUniqueId') == 'remote-images-probe'), None)
    return json.loads((item or {}).get('AXValue') or '{}')

ui.wait(lambda items: probe(items).get('cloudReferenceBlocked') is True, 'LAN protected image did not retain its boundary')
assert probe()['requests'] == [], probe()
ui.axe('tap', '--id', 'remote-images-share', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('paperReady') is True, 'HTTP Markdown pictures did not generate a share image')
assert ui.element('message-share-preview').get('AXValue', '').startswith('1080 × ')
requests = probe()['requests']
assert {x['url'] for x in requests} == {'http://offline-image.invalid/picture.png', 'https://offline-image.invalid/picture.png'}, requests
assert len(requests) == 2 and not any(x['authorized'] for x in requests), requests
ui.capture('lan-http-share-image')
ui.axe('tap', '--label', catalog.text('accessibility.closeSheet', title=catalog.text('native.chat.message.preview')), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Share preview did not close')
ui.axe('tap', '--id', 'remote-images-gallery', '--post-delay', '.5')
ui.wait(lambda items: probe(items).get('galleryReady') is True, 'Markdown external picture did not load in the large preview')
ui.element('chat-image-preview')
requests = probe()['requests']
assert len(requests) == 3 and not any(x['authorized'] for x in requests), requests
assert requests[-1]['url'] == 'https://offline-image.invalid/picture.png', requests
ui.capture('lan-markdown-large-image')
ui.axe('tap', '--label', catalog.text('native.chat.image.closePreview'), '--post-delay', '.4')
ui.wait(lambda items: probe(items).get('host') == 'fixture', 'Large preview did not close')
print('PASS: LAN HTTP/HTTPS share JPEG, Markdown large preview, no Cloud bearer on public URLs and protected references remain blocked')
