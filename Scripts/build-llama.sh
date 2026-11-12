#!/bin/bash
# Pass 58: llama.cpp built from source for PodSkipper's CPU
# reader, as Packages/LlamaCPU/llama.xcframework (git-ignored; rebuilt when
# missing). llama.cpp's own Apple release is compiled for the oldest ARM: its
# iOS slice has no dot-product instructions at all, and on the Mac lab its
# framework read Qwen3.5 4B at 1.3 tokens/s where a native build reads ~20.
#
#   iOS (device): ARMv8.4 + dot product + int8 matrix multiply (the int8
#                 kernels are chosen at run time only on chips that have them)
#   macOS (lab):  this Mac's own CPU
# CPU and Accelerate only: no Metal (iOS refuses the GPU off screen anyway).
set -euo pipefail
cd "$(dirname "$0")/.."
# Pass 63: b12110 → b12283 (11 Nov 2026), for Liquid's LFM3 1.7B. The source
# and both builds live in a folder named after the release, so changing TAG
# rebuilds everything from that release and never mixes two.
TAG=b12283
OUT=Packages/LlamaCPU/llama.xcframework
STAMP="$OUT/.built-$TAG"
[ -f "$STAMP" ] && { echo "llama.xcframework ($TAG) present"; exit 0; }
command -v cmake >/dev/null || { echo "cmake is needed (brew install cmake)"; exit 1; }
WORK=build/llama/$TAG
mkdir -p "$WORK"
if [ ! -d "$WORK/src/.git" ]; then
  rm -rf "$WORK/src"
  git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK/src"
fi
COMMON=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple
        -DGGML_OPENMP=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF
        -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF)
build() { # name, extra cmake args…
  local name=$1; shift
  cmake -S "$WORK/src" -B "$WORK/$name" "${COMMON[@]}" "$@" > "$WORK/$name.cmake.log" 2>&1
  cmake --build "$WORK/$name" --config Release --target llama -j "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)" \
    > "$WORK/$name.build.log" 2>&1 || { tail -30 "$WORK/$name.build.log"; exit 1; }
  local libs=("$WORK/$name/src/libllama.a" "$WORK/$name/ggml/src/libggml.a" "$WORK/$name/ggml/src/libggml-base.a"
              "$WORK/$name/ggml/src/libggml-cpu.a" "$WORK/$name/ggml/src/ggml-blas/libggml-blas.a")
  libtool -static -no_warning_for_no_symbols -o "$WORK/$name/libllama-cpu.a" "${libs[@]}"
  rm -rf "$WORK/$name/headers"; mkdir -p "$WORK/$name/headers"
  cp "$WORK/src/include/llama.h" "$WORK/src/ggml/include/"*.h "$WORK/$name/headers/"
  cat > "$WORK/$name/headers/module.modulemap" <<'EOF'
module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-backend.h"
    header "ggml-cpu.h"
    link "c++"
    link framework "Accelerate"
    export *
}
EOF
}
build ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DCMAKE_OSX_SYSROOT=iphoneos -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod+i8mm
SLICES=(-library "$WORK/ios/libllama-cpu.a" -headers "$WORK/ios/headers")
# The Mac slice is for Tools/CPULab only; CI's IPA build skips it (LLAMA_IOS_ONLY=1).
if [ "${LLAMA_IOS_ONLY:-0}" != 1 ]; then
  build macos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DGGML_NATIVE=ON
  SLICES+=(-library "$WORK/macos/libllama-cpu.a" -headers "$WORK/macos/headers")
fi
rm -rf "$OUT"
xcodebuild -create-xcframework "${SLICES[@]}" -output "$OUT" > "$WORK/xcframework.log" 2>&1 \
  || { cat "$WORK/xcframework.log"; exit 1; }
touch "$STAMP"
echo "built $OUT ($TAG): iOS $(otool -tV "$WORK/ios/libllama-cpu.a" 2>/dev/null | grep -c -w sdot) dot-product instructions"
