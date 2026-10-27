#!/bin/sh
# Rebuild only the pronunciation assets shipped by OpenRead. Neural weights are
# separate, optional downloads. This is a development tool, not an install step.
set -eu
openread_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
openread_revision=699e79690f23e2558d990a3a78b0050745b96932
openread_source=${1:-"$openread_root/.local/espeak-source"}
openread_build="$openread_root/.local/espeak-data-build"
openread_cmake=${OPENREAD_CMAKE:-cmake}
if [ ! -d "$openread_source" ]; then
    mkdir -p "$openread_source"
    git -C "$openread_source" init
    git -C "$openread_source" remote add origin https://github.com/espeak-ng/espeak-ng.git
    git -C "$openread_source" fetch --depth 1 origin "$openread_revision"
    git -C "$openread_source" checkout --detach FETCH_HEAD
fi
test "$(git -C "$openread_source" rev-parse HEAD)" = "$openread_revision" || {
    echo "Expected eSpeak NG $openread_revision" >&2; exit 1;
}
git -C "$openread_source" diff --exit-code HEAD -- . >/dev/null || {
    echo 'Use an unchanged upstream checkout.' >&2; exit 1;
}
"$openread_cmake" -S "$openread_source" -B "$openread_build" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DUSE_ASYNC=OFF \
    -DUSE_LIBPCAUDIO=OFF -DUSE_LIBSONIC=OFF -DUSE_MBROLA=OFF \
    -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF
"$openread_cmake" --build "$openread_build" --target data --parallel 2
openread_destination="$openread_root/app/mobile/shared/speech/espeak-ng-data"
mkdir -p "$openread_destination/lang/gmw"
for openread_file in en_dict phontab phonindex phondata intonations; do
    cp "$openread_build/espeak-ng-data/$openread_file" "$openread_destination/$openread_file"
done
for openread_voice in en en-US; do
    cp "$openread_source/espeak-ng-data/lang/gmw/$openread_voice" "$openread_destination/lang/gmw/$openread_voice"
done
echo 'English pronunciation data rebuilt. Review the asset diff before committing.'
