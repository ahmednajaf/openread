"""Opt-in real local engines; produces only disposable fixtures under test-results."""
import base64
import io
import json
from pathlib import Path
import sys
import wave
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'app/voice'))
import features
from server import KokoroVoice, CATALOG

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'test-results'
OUT.mkdir(exist_ok=True)


def scan_fixtures():
    import Quartz as Q
    import AppKit as A
    import Foundation as F
    width, height = 1200, 500
    context = Q.CGBitmapContextCreate(None, width, height, 8, width * 4, Q.CGColorSpaceCreateDeviceRGB(), Q.kCGImageAlphaPremultipliedLast)
    Q.CGContextSetRGBFillColor(context, 1, 1, 1, 1)
    Q.CGContextFillRect(context, ((0, 0), (width, height)))
    text = 'Reading should be accessible to everyone.'
    def draw_text(target):
        A.NSGraphicsContext.saveGraphicsState()
        A.NSGraphicsContext.setCurrentContext_(A.NSGraphicsContext.graphicsContextWithCGContext_flipped_(target, False))
        F.NSString.stringWithString_(text).drawAtPoint_withAttributes_((55, 270), {A.NSFontAttributeName: A.NSFont.systemFontOfSize_(40), A.NSForegroundColorAttributeName: A.NSColor.blackColor()})
        A.NSGraphicsContext.restoreGraphicsState()
    draw_text(context)
    image = Q.CGBitmapContextCreateImage(context)
    output = F.NSMutableData.data()
    destination = Q.CGImageDestinationCreateWithData(output, 'public.png', 1, None)
    Q.CGImageDestinationAddImage(destination, image, None)
    assert Q.CGImageDestinationFinalize(destination)
    png = bytes(output)
    (OUT / 'scan-fixture.png').write_bytes(png)
    assert 'accessible to everyone' in features.ocr_image(png)
    for scanned in (False, True):
        path = OUT / ('scanned-fixture.pdf' if scanned else 'text-fixture.pdf')
        url = F.NSURL.fileURLWithPath_(str(path))
        pdf = Q.CGPDFContextCreateWithURL(url, ((0, 0), (width, height)), None)
        Q.CGPDFContextBeginPage(pdf, None)
        if scanned:
            Q.CGContextDrawImage(pdf, ((0, 0), (width, height)), image)
        else:
            draw_text(pdf)
        Q.CGPDFContextEndPage(pdf)
        Q.CGPDFContextClose(pdf)
        result = features.import_document({'name': path.name, 'data': base64.b64encode(path.read_bytes()).decode()})
        assert 'accessible to everyone' in result['text'], result['text']
    print('Real macOS Vision OCR: image and scanned PDF; real pypdf: text PDF — passed.', flush=True)


def voice_and_transcription():
    voice = KokoroVoice()
    samples = {'en-us': 'Reading should be accessible to everyone.', 'en-gb': 'Reading should be accessible to everyone.', 'es': 'La lectura debe ser accesible para todos.', 'fr-fr': 'La lecture devrait être accessible à tous.', 'hi': 'पढ़ना सभी के लिए सुलभ होना चाहिए।', 'it': 'La lettura dovrebbe essere accessibile a tutti.', 'pt-br': 'A leitura deve ser acessível a todos.'}
    results = []
    for item in CATALOG:
        if item.get('pack') and not __import__('kitten').ready():
            continue
        result = voice.synthesize(samples[item['lang']], item['id'])
        assert result['words'] and result['duration'] > .3
        results.append({'voice': item['id'], 'duration': result['duration'], 'timings': len(result['words'])})
    (OUT / 'voice-checks.json').write_text(json.dumps(results, indent=2))
    print(f'Real Kokoro: {len(results)} voices generated nonempty timed audio across six languages — passed. Pronunciation quality still varies by language.', flush=True)
    result = voice.synthesize('Reading should be accessible to everyone. This recording stays on your device. There is no subscription and no account.', 'af_heart')
    wav = base64.b64decode(result['audio']); (OUT / 'dictation-fixture.wav').write_bytes(wav)
    if (ROOT / '.local/whisper-base/model.bin').exists():
        transcript = features.transcribe({'name': 'fixture.wav', 'data': base64.b64encode(wav).decode()})
        assert 'accessible' in transcript['text'].lower(), transcript
        assert 'subscription' in transcript['text'].lower(), transcript
        print('Real Whisper Base: local generated-audio transcription — passed.', flush=True)
    else:
        print('Whisper model not downloaded yet; transcription check pending.', flush=True)


if __name__ == '__main__':
    if '--voices' in sys.argv:
        voice_and_transcription()
    else:
        scan_fixtures()
