# English pronunciation engine

Portable eSpeak NG C sources and Unicode tables from
https://github.com/espeak-ng/espeak-ng/tree/699e79690f23e2558d990a3a78b0050745b96932
(GPL-3.0-or-later; Unicode tables retain their BSD/UCD notices).
Sources in `vendor/` are unmodified. OpenRead adds `config.h` for the synchronous
build and `endian.h` for Apple's byte-order aliases. Only the synchronous library is compiled; eSpeak never produces the
listening voice. Kitten Mini remains the neural speech model.

`espeak-ng-data/` contains the English dictionary and shared phoneme/intonation
files compiled from that exact source with CMake's `data` target. English voice
files are copied unchanged. Rebuild with `dev/scripts/mobile-speech-data.sh`
from the repository root (Git, CMake 3.22+ and a host C/C++ compiler required).
The script retrieves the exact corresponding upstream source into `.local/`;
pass an existing clean checkout as its first argument to build without a download.
The small pronunciation assets ship in both apps; neural weights still download
only when the user chooses to install voices.

`openread_speech.cpp` is OpenRead's thread-safe C adapter. It retains clause
punctuation for the neural model. No subprocess, system TTS or network is used.
