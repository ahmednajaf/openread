from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'app/voice'))
import kitten
from alignment import align_words


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

    def test_model_durations_include_special_and_separator_tokens(self):
        # [BOS, a, separator, punctuation, EOS-1, EOS-2]. Speech starts
        # after BOS; separators still consume time, without becoming words.
        timing = kitten.model_timings('a!', {c:i for i,c in enumerate(kitten.SYMBOLS)}, [1, 2, 1, 3, 1, 2], 24000, 24000)
        self.assertEqual([t.phoneme for t in timing], ['a', ' ', '!'])
        self.assertAlmostEqual(timing[0].start, .1)
        self.assertAlmostEqual(timing[0].end, .3)
        self.assertAlmostEqual(timing[2].start, .4)
        self.assertAlmostEqual(timing[2].end, .7)

    def test_invalid_durations_fail_instead_of_guessing_highlights(self):
        vocab = {c:i for i,c in enumerate(kitten.SYMBOLS)}
        for frames in ([1], [0]*6, [1,2,-1,3,1,2], [100000]*6):
            with self.assertRaises(kitten.VoiceError):
                kitten.model_timings('a!', vocab, frames, 24000, 24000)

    def test_chunks_keep_global_times_and_original_utf16_offsets(self):
        vocab = {c:i for i,c in enumerate(kitten.SYMBOLS)}
        first = kitten.model_timings('haɪ', vocab, [1,2,1,2,1,1], 24000, 24000)
        second = kitten.model_timings('haɪ', vocab, [1,2,1,2,1,1], 24000, 24000, offset=1)
        words = align_words('🌊 Hi hi', ['', 'haɪ', 'haɪ'], first + second, 2)
        self.assertEqual([w['offset'] for w in words], [3,6])
        self.assertEqual([w['length'] for w in words], [2,2])
        self.assertTrue(all(not w['estimated'] and w['end'] > w['start'] for w in words))
        self.assertLessEqual(words[0]['end'], words[1]['start'])

    def test_unmatched_run_shares_a_gap_without_overlapping_or_freezing(self):
        from types import SimpleNamespace
        timing = [SimpleNamespace(phoneme=c,start=1+i*.1,end=1+(i+1)*.1) for i,c in enumerate('end')]
        words = align_words('🌊 two missed end', ['', '', '', 'end'], timing, 2)
        self.assertEqual([w['offset'] for w in words], [3,7,14])
        self.assertTrue(all(w['end'] > w['start'] for w in words))
        self.assertTrue(all(a['end'] <= b['start'] for a,b in zip(words,words[1:])))
        self.assertTrue(words[0]['estimated']); self.assertFalse(words[-1]['estimated'])

    def test_trimmed_audio_does_not_rescale_earlier_word_times(self):
        vocab = {c:i for i,c in enumerate(kitten.SYMBOLS)}
        full = kitten.model_timings('a!', vocab, [1,2,1,3,1,2], 24000, 24000)
        trimmed = kitten.model_timings('a!', vocab, [1,2,1,3,1,2], 24000, 12000)
        self.assertEqual(full[0].end, trimmed[0].end)
        self.assertEqual(trimmed[-1].end, .5)


if __name__ == '__main__':
    unittest.main()
