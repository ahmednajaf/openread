import http.client
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("server", Path(__file__).resolve().parents[2] / "app/voice/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class SecurityTests(unittest.TestCase):
    def test_origin_policy(self):
        self.assertTrue(server.allowed_origin("safari-web-extension://example"))
        self.assertFalse(server.allowed_origin("https://example.com"))
        self.assertFalse(server.allowed_origin("http://127.0.0.1:4173"))
        self.assertTrue(server.allowed_origin("http://127.0.0.1:4173", True))
        self.assertFalse(server.allowed_origin("http://127.0.0.1.evil.com:4173", True))

    def test_payload_limits(self):
        self.assertEqual(server.validate_payload({"text": " hello "}), "hello")
        for payload in [{}, [], {"text": 3}, {"text": " "}, {"text": "a" * 1601}, {"text": "hello", "voice": []}, {"text": "hello", "voice": "unknown"}]:
            with self.assertRaises(ValueError):
                server.validate_payload(payload)

    def test_word_alignment_uses_utf16_offsets_and_handles_number_expansion(self):
        text = '🙂 In 2026, read.'
        sounds = ['', 'ɪn', 'twɛnti twɛnti sɪks,', 'ɹiːd.']
        actual = ''.join(sounds)
        timings = [SimpleNamespace(phoneme=c, start=i * .1, end=(i + 1) * .1) for i, c in enumerate(actual)]
        words = server.align_words(text, sounds, timings, len(actual) * .1)
        self.assertEqual([w['offset'] for w in words], [3, 6, 12])
        self.assertEqual([w['length'] for w in words], [2, 5, 5])
        self.assertTrue(all(not w['estimated'] for w in words))
        self.assertTrue(all(a['start'] <= b['start'] for a, b in zip(words, words[1:])))

    def test_unmatched_pronunciation_is_explicitly_marked(self):
        words = server.align_words('new word', ['', 'wɜːd'], [SimpleNamespace(phoneme=c, start=i * .1, end=(i + 1) * .1) for i, c in enumerate('wɜːd')], 1)
        self.assertTrue(words[0]['estimated'])
        self.assertFalse(words[1]['estimated'])


class EndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        class FakeVoice:
            def synthesize(self, text, voice):
                return {'audio': 'fake-wav', 'voice': voice, 'words': [{'offset': 0, 'length': len(text), 'start': 0, 'end': 1}]}
        cls.http = server.make_server(FakeVoice(), port=0)
        cls.thread = threading.Thread(target=cls.http.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown()
        cls.http.server_close()
        cls.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.http.server_port)
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        result = (response.status, dict(response.getheaders()), response.read())
        connection.close()
        return result

    def test_health_and_generation(self):
        status, _, body = self.request("GET", "/health", headers={"X-OpenRead": "1"})
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["ready"])
        status, headers, body = self.request("POST", "/synthesize", json.dumps({"text": "hello"}), {"X-OpenRead": "1", "Content-Type": "application/json", "Origin": "safari-web-extension://fixture"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["audio"], "fake-wav")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Access-Control-Allow-Origin"], "safari-web-extension://fixture")

    def test_voice_choice_reaches_synthesis(self):
        status, _, body = self.request('POST', '/synthesize', json.dumps({'text': 'hello', 'voice': 'bf_emma'}), {'X-OpenRead': '1', 'Content-Type': 'application/json'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['voice'], 'bf_emma')

    def test_reading_app_serves_built_local_assets_without_opening_api_access(self):
        status, headers, body = self.request('GET', '/')
        self.assertEqual(status, 200)
        self.assertIn(b'id="root"', body)
        self.assertIn(b'src="/app.js"', body)
        self.assertNotIn(b'openread-api-prefix', body)
        self.assertIn("script-src 'self';", headers['Content-Security-Policy'])
        self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
        self.assertEqual(self.request('GET', '/app.js')[0], 200)
        self.assertEqual(self.request('GET', '/', headers={'Origin': 'https://example.com'})[0], 403)
        self.assertEqual(self.request('GET', '/health')[0], 403)

    def test_website_and_headerless_requests_are_rejected(self):
        self.assertEqual(self.request("GET", "/health")[0], 403)
        self.assertEqual(self.request("GET", "/health", headers={"X-OpenRead": "1", "Origin": "https://example.com"})[0], 403)
        self.assertEqual(self.request("OPTIONS", "/synthesize", headers={"Origin": "https://example.com"})[0], 403)

    def test_rebinding_and_oversize_rejected(self):
        self.assertEqual(self.request("GET", "/health", headers={"X-OpenRead": "1", "Host": "attacker.example"})[0], 403)
        self.assertEqual(self.request("POST", "/synthesize", json.dumps({"text": "x" * 1601}), {"X-OpenRead": "1", "Content-Type": "application/json"})[0], 400)
