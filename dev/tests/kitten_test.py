from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'app/voice'))
import kitten
import features


class AlignmentTests(unittest.TestCase):
    def test_silence_trimming_never_clips_audible_word_endings(self):
        audible = [.2] * 7200
        self.assertEqual(kitten.trim_silence(audible), audible)
        padded = audible + [0.] * 9000
        trimmed = kitten.trim_silence(padded)
        self.assertEqual(trimmed[:len(audible)], audible)
        self.assertGreaterEqual(len(trimmed), len(audible) + 2400)
        self.assertGreaterEqual(len(trimmed), len(padded) - 4800)
        self.assertEqual(kitten.trim_silence([.2] * 500), [.2] * 500)

    def test_short_speech_without_whisper_words_keeps_estimated_timings(self):
        words, source = kitten.speech_alignment('I', [], .75)
        self.assertEqual(source, 'estimated-duration')
        self.assertEqual(words, [{'offset': 0, 'length': 1, 'start': 0, 'end': .75, 'estimated': True}])
        words, _ = kitten.speech_alignment('🌊 Yes, see you there.', [], 2)
        self.assertEqual(words[0]['offset'], 3)
        self.assertTrue(all(word['end'] > word['start'] for word in words))

    def test_long_unrecognized_or_unreadable_speech_still_reports_alignment_failure(self):
        for text, duration in [('one two three four five six', 3), ('Hi', 9), ('…', 1)]:
            with self.assertRaises(kitten.VoiceError) as failure:
                kitten.speech_alignment(text, [], duration)
            self.assertEqual(failure.exception.code, 'voice_alignment_failed')

    def test_recognized_short_speech_keeps_whisper_timing_source(self):
        words, source = kitten.speech_alignment('Yes.', [SimpleNamespace(word='Yes.', start=.2, end=.7)], 1)
        self.assertEqual(source, 'whisper-word-alignment')
        self.assertEqual(words[0]['start'], .2)

    def test_unrecognized_run_does_not_freeze_first_word(self):
        words = kitten.align_transcript('One small missed phrase ends.', [
            SimpleNamespace(word='One', start=0, end=.4),
            SimpleNamespace(word='ends.', start=2, end=2.5)], 2.5)
        self.assertEqual(words[0]['end'], .4)
        self.assertEqual(words[-1]['start'], 2)
        self.assertTrue(all(w['end'] > w['start'] for w in words))
        self.assertTrue(all(a['end'] <= b['start'] for a, b in zip(words, words[1:])))

    def test_leading_and_trailing_gaps_keep_utf16_offsets(self):
        words = kitten.align_transcript('🌊 First two anchor last words', [
            SimpleNamespace(word='anchor', start=1, end=1.5)], 3)
        self.assertEqual(words[0]['offset'], 3)
        self.assertEqual(words[2]['start'], 1)
        self.assertTrue(all(w['end'] > w['start'] for w in words))
        self.assertEqual(words[-1]['end'], 3)

    def test_whisper_does_not_use_source_as_previous_transcript(self):
        model = SimpleNamespace(transcribe=lambda *a, **kw: ([], None))
        with patch.object(features, 'whisper_model', return_value=model):
            with patch.object(model, 'transcribe', return_value=([], None)) as call:
                features.whisper_word_timings([], 'A long source ending in repeated words.')
        self.assertNotIn('initial_prompt', call.call_args.kwargs)
        self.assertTrue(call.call_args.kwargs['word_timestamps'])


if __name__ == '__main__':
    unittest.main()
