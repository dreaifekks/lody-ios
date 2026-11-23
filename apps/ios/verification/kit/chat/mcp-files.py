"""MCP files open native previews without credentials or an online machine."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ui'))
from driver import UI
import catalog

ui = UI(*sys.argv[1:])
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', ui.udid, 'ai.lody.mobile', 'data'], text=True).strip())
movie = container / 'Documents/ui-verify-attachment.mp4'

SWIFT_GEN_MP4 = r'''
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outURL)
let width = 320, height = 180, fps: Int32 = 15, seconds = 8
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let settings: [String: Any] = [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: width,
  AVVideoHeightKey: height,
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
  assetWriterInput: input,
  sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
  ]
)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let totalFrames = Int(fps) * seconds
for i in 0..<totalFrames {
  while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
  guard let buffer = pb else { continue }
  CVPixelBufferLockBaseAddress(buffer, [])
  if let ctx = CGContext(
    data: CVPixelBufferGetBaseAddress(buffer),
    width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
  ) {
    let t = CGFloat(i) / CGFloat(totalFrames)
    ctx.setFillColor(red: 0.1 + 0.7 * t, green: 0.25, blue: 0.9 - 0.7 * t, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(red: 1, green: 0.9, blue: 0.1, alpha: 1)
    let barX = CGFloat(i) / CGFloat(totalFrames) * CGFloat(width - 40)
    ctx.fill(CGRect(x: barX, y: 40, width: 40, height: 100))
  }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let sema = DispatchSemaphore(value: 0)
writer.finishWriting { sema.signal() }
sema.wait()
'''


def generate_synthetic_mp4(dest: Path):
    res = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                          'testsrc2=size=320x180:rate=15', '-t', '8', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(dest)])
    if res.returncode == 0 and dest.exists() and dest.stat().st_size > 0:
        return
    subprocess.run(['swift', '-', str(dest)], input=SWIFT_GEN_MP4, text=True, check=True)


generate_synthetic_mp4(movie)


def close():
    if any(item.get('AXLabel') == catalog.text('native.close') for item in ui.state()):
        ui.axe('tap', '--label', catalog.text('native.close'), '--post-delay', '.5')
        ui.element('mcp-files:text')
        return
    if not any(item.get('type') == 'Button' and (item.get('AXLabel') or '').lower() in ['done', 'close'] for item in ui.state()):
        frame = ui.element('QLPreviewControllerView')['frame']
        ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.2')
    button = ui.wait(lambda items: next((item for item in items if item.get('type') == 'Button'
                    and (item.get('AXLabel') or '').lower() in ['done', 'close']), None), 'Quick Look must offer Close')
    ui.axe('tap', '--label', button['AXLabel'], '--post-delay', '.5')
    ui.element('mcp-files:text')


def loaded(container_id='QLPreviewControllerView'):
    ui.element(container_id)
    ui.wait(lambda items: not any(item.get('AXLabel') == catalog.text('native.attachment.preview.loading') for item in items), 'File loading never finished')
    time.sleep(.8)
    assert not any(item.get('AXLabel') == catalog.text('native.attachment.preview.retry') for item in ui.state()), 'Preview failed to load'


def frame_hash(name):
    src = Path(sys.argv[2]) / name
    with tempfile.NamedTemporaryFile(suffix='.bmp', delete=False) as tmp:
        out = Path(tmp.name)
    try:
        # Crop central region via macOS sips (zero ffmpeg dependency) and hash raw BMP pixels.
        info = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(src)], text=True)
        w = int(next(line.split()[-1] for line in info.splitlines() if 'pixelWidth:' in line))
        h = int(next(line.split()[-1] for line in info.splitlines() if 'pixelHeight:' in line))
        subprocess.run(['sips', '-c', str(int(h * 0.2)), str(int(w * 0.6)), '-s', 'format', 'bmp', str(src), '--out', str(out)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return hashlib.sha256(out.read_bytes()).hexdigest()
    finally:
        out.unlink(missing_ok=True)


def reveal_video_controls():
    items = ui.state()
    if any((item.get('AXLabel') or '') in ('Pause', 'Play') for item in items):
        return items
    frame = ui.element('session-video-preview')['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.3')
    return ui.state()


ui.axe('tap', '--label', 'MCP Attachments', '--post-delay', '.5')
for file in ['text', 'pdf', 'video', 'retry', 'missing', 'pending', 'cancel']:
    assert ui.element('mcp-files:' + file)['type'] == 'Button'
ui.capture('files-inline')
for file in ['text', 'pdf', 'video']:
    ui.axe('tap', '--id', 'mcp-files:' + file, '--post-delay', '.2')
    loaded('session-video-preview' if file == 'video' else 'QLPreviewControllerView')
    ui.capture(file + '-preview')
    if file == 'video':
        time.sleep(.8)
        ui.capture('video-playing')
        assert frame_hash('video-preview.png') != frame_hash('video-playing.png'), 'Video frames did not advance'

        items = reveal_video_controls()
        pause_btn = next((i for i in items if i.get('type') == 'Button' and (i.get('AXLabel') or '') == 'Pause'), None)
        assert pause_btn is not None, f'System Pause button not found in AVPlayerViewController: {[ (i.get("type"), i.get("AXLabel"), i.get("AXUniqueId")) for i in items ]}'
        pf = pause_btn['frame']
        ui.axe('tap', '-x', str(pf['x'] + pf['width'] / 2), '-y', str(pf['y'] + pf['height'] / 2), '--post-delay', '.4')
        ui.capture('video-paused')
        time.sleep(.8)
        ui.capture('video-paused-check')
        assert frame_hash('video-paused.png') == frame_hash('video-paused-check.png'), 'Video did not pause after tapping Pause'

        items = reveal_video_controls()
        slider = next((i for i in items if i.get('type') == 'Slider' or 'scrubber' in (i.get('AXLabel') or '').lower() or 'timeline' in (i.get('AXLabel') or '').lower()), None)
        assert slider is not None, f'System timeline scrubber not found: {[ (i.get("type"), i.get("AXLabel"), i.get("AXUniqueId")) for i in items ]}'
        sf = slider['frame']
        y = sf['y'] + sf['height'] / 2
        ui.axe('drag', '--start-x', str(sf['x'] + sf['width'] * 0.15), '--start-y', str(y),
               '--end-x', str(sf['x'] + sf['width'] * 0.75), '--end-y', str(y), '--duration', '.4', '--post-delay', '.5')
        ui.capture('video-seeked')
        assert frame_hash('video-paused-check.png') != frame_hash('video-seeked.png'), 'Video frame did not change after seeking'

        items = reveal_video_controls()
        play_btn = next((i for i in items if i.get('type') == 'Button' and (i.get('AXLabel') or '') == 'Play'), None)
        assert play_btn is not None, 'System Play button not found after pause/seek'
        plf = play_btn['frame']
        ui.axe('tap', '-x', str(plf['x'] + plf['width'] / 2), '-y', str(plf['y'] + plf['height'] / 2), '--post-delay', '.8')
        ui.capture('video-resumed')
        assert frame_hash('video-seeked.png') != frame_hash('video-resumed.png'), 'Video did not resume after tapping Play'
    close()

ui.axe('tap', '--id', 'mcp-files:retry', '--post-delay', '.2')
ui.wait(lambda items: any(item.get('AXLabel') == catalog.text('native.attachment.error.download') for item in items), 'Download failure was swallowed')
ui.capture('failed-download')
ui.axe('tap', '--label', catalog.text('native.attachment.preview.retry'), '--post-delay', '.2')
loaded()
ui.capture('retry-loaded')
close()
for file in ['missing', 'pending']:
    ui.axe('tap', '--id', 'mcp-files:' + file, '--post-delay', '.2')
    key = 'unavailable' if file == 'missing' else 'pending'
    ui.wait(lambda items: any(item.get('AXLabel') == catalog.text('native.attachment.error.' + key) for item in items), 'Missing file state: ' + file)
    ui.capture(file)
    close()
ui.axe('tap', '--id', 'user-file:attachment:text', '--post-delay', '.2')
loaded()
ui.capture('user-file-preview')
close()
ui.axe('tap', '--id', 'mcp-files:cancel', '--post-delay', '.2')
ui.wait(lambda items: any(item.get('AXLabel') == catalog.text('native.attachment.preview.loading') for item in items), 'Loading state missing')
ui.capture('loading')
close()
time.sleep(4.5)
assert not any(item.get('AXUniqueId') == 'QLPreviewControllerView' for item in ui.state()), 'Cancelled download reopened the preview'
ui.capture('cancelled')
movie.unlink()
print('PASS: MCP text/PDF/video previews, playback, retry, unavailable/pending states, user attachments and cancelled download')
