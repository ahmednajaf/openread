#!/bin/sh
# Build the pinned optional Apple runtime; model weights are never bundled.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
revision=2b9912e72245f5597c664d2be44a6e7ba0a3f293
runtime_root=${OPENREAD_KITTEN2_BUILD_ROOT:-"$repo_root/build/kitten2-runtime"}
source_root=${OPENREAD_KITTEN2_SOURCE:-"$runtime_root/source"}
if [ ! -d "$source_root/.git" ]; then
  mkdir -p "$runtime_root"
  git clone --filter=blob:none https://github.com/KittenML/kitten-tts-2-cpp.git "$source_root"
  git -C "$source_root" checkout --detach "$revision"
fi
if [ "$(git -C "$source_root" rev-parse HEAD)" != "$revision" ]; then
  echo 'The Kitten runtime checkout does not match its pinned revision.' >&2
  exit 1
fi
mkdir -p "$runtime_root/headers"
cp "$repo_root/app/mobile/shared/kitten2/include/Kitten2Runtime.h" "$repo_root/app/mobile/shared/kitten2/include/module.modulemap" "$runtime_root/headers/"
for platform in ${OPENREAD_KITTEN2_PLATFORMS:-macos simulator iphone}; do
  case "$platform" in
    macos) sdk=macosx; system=Darwin; minimum=14.0; metal=ON ;;
    simulator) sdk=iphonesimulator; system=iOS; minimum=17.0; metal=OFF ;;
    iphone) sdk=iphoneos; system=iOS; minimum=17.0; metal=ON ;;
    *) echo 'Unknown Apple platform.' >&2; exit 1 ;;
  esac
  directory="$runtime_root/$platform"
  cmake -S "$repo_root/app/mobile/shared/kitten2" -B "$directory" \
    -DOPENREAD_KITTEN2_SOURCE="$source_root" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DGGML_METAL="$metal" \
    -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_BLAS=OFF -DGGML_OPENMP=OFF
  cmake --build "$directory" --target OpenReadKitten2 -j "${OPENREAD_BUILD_JOBS:-3}"
  # Build paths are task-owned; quote each library instead of expanding shell text.
  mkdir -p "$runtime_root/$platform-artifact"
  find "$directory" -name '*.a' -type f -print0 | xargs -0 xcrun libtool -static -o "$runtime_root/$platform-artifact/libKitten2Runtime.a"
done
if [ -f "$runtime_root/macos-artifact/libKitten2Runtime.a" ] && [ -f "$runtime_root/simulator-artifact/libKitten2Runtime.a" ] && [ -f "$runtime_root/iphone-artifact/libKitten2Runtime.a" ]; then
  destination="$repo_root/app/mobile/shared/kitten2/Kitten2Runtime.xcframework"
  if [ -e "$destination" ]; then
    # Keep the previous build recoverable until its replacement is complete.
    mv "$destination" "$runtime_root/previous-$(date +%s).xcframework"
  fi
  xcodebuild -create-xcframework \
    -library "$runtime_root/macos-artifact/libKitten2Runtime.a" -headers "$runtime_root/headers" \
    -library "$runtime_root/simulator-artifact/libKitten2Runtime.a" -headers "$runtime_root/headers" \
    -library "$runtime_root/iphone-artifact/libKitten2Runtime.a" -headers "$runtime_root/headers" \
    -output "$destination"
fi
