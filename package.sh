#!/usr/bin/env bash
# Packages a finished build for release (D-045).
#
# Usage, from this repo's root after upstream/build.sh has finished:
#   bash package.sh build.log
#   bash package.sh --check-licences   only the licence checks below; needs no Docker and
#                                      writes nothing (tests/package-licences.sh uses it)
#
# Reads:  build.conf; upstream/artifacts/*.zip (from build.sh); upstream/Dockerfile (which
#         stages were built); upstream/.cache/downloads/ (their pinned sources); the build
#         log (the configure line); the build image (the compiler version); the toolchain's
#         licence texts, fetched from upstream at a pinned commit and checked by SHA-256.
# Writes: dist/ffmpeg-<tag>-r<n>-win64-lgpl.zip   bin/ffmpeg.exe, bin/ffprobe.exe, LICENSE.txt,
#                                                NOTICE.txt, BUILDINFO.txt, licenses/
#         dist/ffmpeg-<tag>-r<n>-source.tar      the complete corresponding source
#         dist/SHA256SUMS
#
# Every check runs before anything is written, and all problems are printed together
# before the script exits 1 (D-308).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="$ROOT/upstream"
LOG="${1:-}"
CHECK_ONLY=""
[[ "$LOG" == "--check-licences" ]] && CHECK_ONLY=1

fail() { echo "package.sh: FAIL: $*" >&2; exit 1; }
say() { echo "package.sh: $*"; }
problems=()
problem() { problems+=("$*"); }
stop_on_problems() {
    [[ "${#problems[@]}" == 0 ]] && return 0
    local p
    for p in "${problems[@]}"; do echo "  FAIL  $p" >&2; done
    fail "${#problems[@]} problem(s); nothing was packaged"
}

tools=(git xz tar sha256sum)
if [[ -z "$CHECK_ONLY" ]]; then
    [[ -f "$LOG" ]] || fail "usage: bash package.sh <build log> | --check-licences"
    LOG="$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")"
    tools+=(docker zip unzip)
fi
for tool in "${tools[@]}"; do
    command -v "$tool" > /dev/null || fail "$tool is not installed"
done

# shellcheck source=build.conf
source "$ROOT/build.conf"
RELEASE="${FFMPEG_TAG}-r${BUILD_NUMBER}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NAME="ffmpeg-${RELEASE}-win64-lgpl"
SOURCE_NAME="ffmpeg-${RELEASE}-source"

# Licence files per stage: stage | library | licence | files inside the stage's source tarball.
# Every stage that was built from downloaded source must have a line here, so a new
# dependency cannot ship without its licence text.
# Paths are relative to the tarball's root. upstream's download.sh tars the folder its
# download commands end in, so a stage whose commands `cd` into a clone (10-mingw,
# 20-libiconv) has that clone's files at the root, with no folder of its own.
LICENCES=(
    "10-mingw|mingw-w64 runtime (CRT, startup code and winpthreads)|ZPL-2.1, with parts in the public domain or under the notices in COPYING.MinGW-w64-runtime.txt (CRT); MIT (winpthreads)|COPYING COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt mingw-w64-libraries/winpthreads/COPYING"
    "10-mingw-std-threads|mingw-std-threads|BSD-2-Clause|LICENSE"
    "20-libiconv|GNU libiconv|LGPL-2.1-or-later|COPYING.LIB"
    "20-zlib|zlib|Zlib|LICENSE"
    "25-fribidi|GNU FriBidi|LGPL-2.1-or-later|COPYING"
    "25-freetype|FreeType|FTL (the FreeType License)|LICENSE.TXT docs/FTL.TXT"
    "45-harfbuzz|HarfBuzz|MIT (\"Old MIT\")|COPYING"
    "50-freetype|FreeType|FTL (the FreeType License)|LICENSE.TXT docs/FTL.TXT"
    "45-libunibreak|libunibreak|Zlib|LICENCE"
    "50-libass|libass|ISC|COPYING"
    "50-dav1d|dav1d|BSD-2-Clause|COPYING"
    "50-libvpx|libvpx|BSD-3-Clause, with an additional patent grant|LICENSE PATENTS"
    "50-libopus|Opus|BSD-3-Clause|COPYING"
    "50-amf|AMD AMF headers|MIT|LICENSE.txt"
    "50-ffnvcodec|nv-codec-headers (NVIDIA Video Codec SDK headers)|MIT|ffnvcodec/include/ffnvcodec/nvEncodeAPI.h"
    "50-onevpl|Intel libvpl|MIT|LICENSE"
    "50-zimg|zimg (with its graphengine submodule)|WTFPL|COPYING graphengine/COPYING"
)

# Licence files of the toolchain's runtime libraries linked statically into the binaries,
# whose source is not kept in the build image (D-308, D-330): name | library | licence |
# version the image's compiler must report | git repository | commit | file=sha256 ...
TOOLCHAIN_LICENCES=(
    "gcc|GCC runtime libraries (libgcc, libstdc++, libatomic)|GPL-3.0-or-later WITH GCC-exception-3.1 (the GCC Runtime Library Exception)|16.2.0|https://gcc.gnu.org/git/gcc.git|78d4ac73dd391005b895a6148cd9831e28e1208b|COPYING3=8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903 COPYING.RUNTIME=9d6b43ce4d8de0c878bf16b54d8e7a10d9bd42b75178153e3af6a815bdc90f74"
)
licence_line() {
    local entry
    for entry in "${LICENCES[@]}"; do
        [[ "${entry%%|*}" == "$1" ]] && { echo "$entry"; return 0; }
    done
    return 1
}

pkg="$WORK/pkg/$NAME"
src="$WORK/src/$SOURCE_NAME"
mkdir -p "$pkg/bin" "$pkg/licenses" "$src/deps"
notice_libs=""
sources_list=""
declare -A listed=()

# 1. The stages that were built, from the generated Dockerfile, and their licence texts.
stage_scripts=()
if [[ -f "$UPSTREAM/Dockerfile" ]]; then
    mapfile -t stage_scripts < <(grep -o 'SELF="scripts.d/[^"]*"' "$UPSTREAM/Dockerfile" | sed 's/^SELF="//; s/"$//' | sort -u)
fi
[[ "${#stage_scripts[@]}" -gt 0 ]] || problem "no stages found in upstream/Dockerfile"

script_value() { grep -m1 "^$2=" "$UPSTREAM/$1" | cut -d'"' -f2; }

for script in "${stage_scripts[@]}"; do
    stage="$(basename "$script" .sh)"
    tarball="$UPSTREAM/.cache/downloads/$stage.tar.xz"
    if [[ ! -e "$tarball" ]]; then
        # A stage without downloaded source only configures the build (base, finalize steps).
        dl="$(cd "$UPSTREAM" && bash -c 'source util/dl_functions.sh; source "$1"; ffbuild_dockerdl' _ "$script")"
        [[ -z "$dl" ]] || problem "stage $stage downloads source but .cache/downloads/$stage.tar.xz is missing"
        continue
    fi
    entry="$(licence_line "$stage")" || { problem "stage $stage was built but has no licence entry in package.sh"; continue; }
    IFS='|' read -r _ library licence files <<< "$entry"
    repo="$(script_value "$script" SCRIPT_REPO)"
    commit="$(script_value "$script" SCRIPT_COMMIT)"

    cp -L "$tarball" "$src/deps/$stage.tar.xz"
    sources_list+="deps/$stage.tar.xz  $library  $repo @ $commit"$'\n'

    mkdir -p "$WORK/x/$stage"
    tar -xJf "$tarball" -C "$WORK/x/$stage" || { problem "stage $stage: .cache/downloads/$stage.tar.xz does not unpack"; continue; }
    slug="${stage#[0-9][0-9]-}"
    for file in $files; do
        found="$WORK/x/$stage/$file"
        [[ -f "$found" ]] || { problem "stage $stage: licence file $file not found in its source"; continue; }
        mkdir -p "$pkg/licenses/$slug/$(dirname "$file")"
        if [[ "$file" == *.h ]]; then
            # A header that carries its licence as the opening comment: keep only that comment.
            sed -n '1,/\*\//p' "$found" > "$pkg/licenses/$slug/$file"
        else
            cp "$found" "$pkg/licenses/$slug/$file"
        fi
    done
    if [[ ! -v listed["$library"] ]]; then
        listed["$library"]=1
        notice_libs+="  $library"$'\n'"      licence: $licence"$'\n'"      source:  $repo @ $commit"$'\n'"      text:    licenses/$slug/"$'\n'
    fi
done

# 2. The toolchain's runtime licence texts: fetched at the pinned commit, each file checked
#    against its pinned SHA-256 (D-308, D-330). Any fetch error or mismatch is a problem.
toolchain_notice=""
for entry in "${TOOLCHAIN_LICENCES[@]}"; do
    IFS='|' read -r slug library licence version repo commit pairs <<< "$entry"
    clone="$WORK/toolchain/$slug"
    if ! { git init --quiet "$clone" && git -C "$clone" fetch --quiet --depth=1 --filter=blob:none "$repo" "$commit"; } > /dev/null 2>&1; then
        problem "toolchain $slug: could not fetch $repo at $commit"
        continue
    fi
    fetched="$(git -C "$clone" rev-parse FETCH_HEAD)"
    [[ "$fetched" == "$commit" ]] || { problem "toolchain $slug: fetched $fetched, the map pins $commit"; continue; }
    mkdir -p "$pkg/licenses/$slug"
    for pair in $pairs; do
        file="${pair%%=*}"
        want="${pair#*=}"
        if ! git -C "$clone" show "FETCH_HEAD:$file" > "$pkg/licenses/$slug/$file" 2> /dev/null; then
            problem "toolchain $slug: $file is not in $repo at $commit"
            continue
        fi
        got="$(sha256sum "$pkg/licenses/$slug/$file" | cut -d' ' -f1)"
        [[ "$got" == "$want" ]] || problem "toolchain $slug: $file has SHA-256 $got, the map pins $want"
    done
    toolchain_notice+="  $library"$'\n'"      licence: $licence"$'\n'"      source:  $repo @ $commit (GCC $version, the build toolchain)"$'\n'"      text:    licenses/$slug/"$'\n'
done

if [[ -n "$CHECK_ONLY" ]]; then
    stop_on_problems
    say "PASS (licences): ${#stage_scripts[@]} stages, ${#listed[@]} libraries with downloaded source, ${#TOOLCHAIN_LICENCES[@]} toolchain entries"
    (cd "$pkg/licenses" && find . -type f | sort | sed 's|^\./|  licenses/|')
    exit 0
fi

# 3. The upstream build output.
shopt -s nullglob
zips=("$UPSTREAM"/artifacts/ffmpeg-*-"${TARGET}-${VARIANT}-${ADDIN}".zip)
shopt -u nullglob
built=""
if [[ "${#zips[@]}" != 1 ]]; then
    problem "expected one upstream/artifacts/ffmpeg-*-${TARGET}-${VARIANT}-${ADDIN}.zip, found ${#zips[@]}"
elif ! unzip -q "${zips[0]}" -d "$WORK/upstream-zip"; then
    problem "the upstream zip does not unpack"
else
    folders=("$WORK"/upstream-zip/*/)
    if [[ "${#folders[@]}" != 1 ]]; then
        problem "the upstream zip does not hold exactly one folder"
    else
        built="${folders[0]%/}"
        [[ -f "$built/bin/ffmpeg.exe" && -f "$built/bin/ffprobe.exe" ]] || problem "the upstream zip lacks bin/ffmpeg.exe or bin/ffprobe.exe"
        [[ ! -e "$built/bin/ffplay.exe" ]] || problem "the upstream zip contains ffplay.exe; this build must not"
        grep -q 'Version 2.1, February 1999' "$built/LICENSE.txt" 2> /dev/null || problem "LICENSE.txt is not the LGPL version 2.1"
    fi
fi

# 4. Facts for BUILDINFO.txt.
configure_line="$(grep -m1 -E '^\+ \./configure ' "$LOG" | sed 's/^+ //' || true)"
[[ -n "$configure_line" ]] || problem "the configure command line is not in $LOG"
image="$(cd "$UPSTREAM" && set +u && source util/vars.sh "$TARGET" "$VARIANT" "$ADDIN" && echo "$IMAGE")"
compiler="$(docker run --rm "$image" bash -c '"$CC" --version' | sed -n 1p || true)"
if [[ -z "$compiler" ]]; then
    problem "could not read the compiler version from $image"
else
    # The fetched toolchain texts must be those of the compiler that built the binaries.
    for entry in "${TOOLCHAIN_LICENCES[@]}"; do
        IFS='|' read -r slug _ _ version _ <<< "$entry"
        [[ " $compiler " == *" $version "* ]] \
            || problem "toolchain $slug: the image's compiler is \"$compiler\", the map's texts are for $version"
    done
fi
ffmpeg_commit=""
if git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$WORK/ffmpeg"; then
    ffmpeg_commit="$(git -C "$WORK/ffmpeg" rev-parse HEAD)"
else
    problem "could not clone FFmpeg $FFMPEG_TAG"
fi
upstream_commit="$(git -C "$UPSTREAM" rev-parse HEAD)"
[[ "$upstream_commit" == "$UPSTREAM_COMMIT" ]] || problem "upstream is at $upstream_commit, build.conf pins $UPSTREAM_COMMIT"

stop_on_problems

REPOSITORY="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to owner/repo of this repository}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RELEASE_URL="$SERVER/$REPOSITORY/releases/tag/$RELEASE"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
recipe_commit="$(git -C "$ROOT" rev-parse HEAD)"
recipe_hash="$(cd "$ROOT" && cat build.conf package.sh overlay/apply.sh overlay/check-configure.sh \
    overlay/disabled-stages.txt overlay/allowed-libs.txt overlay/variants/*.sh | sha256sum | cut -d' ' -f1)"
year="$(date -u +%Y)"
run_url="$SERVER/$REPOSITORY/actions/runs/${GITHUB_RUN_ID:-local}"

# 5. The binary package.
cp "$built/bin/ffmpeg.exe" "$built/bin/ffprobe.exe" "$pkg/bin/"
cp "$built/LICENSE.txt" "$pkg/LICENSE.txt"

cat > "$pkg/NOTICE.txt" << EOF
FFmpeg ${RELEASE} for Windows x64

This package contains ffmpeg.exe and ffprobe.exe built from FFmpeg ${FFMPEG_TAG}
(https://ffmpeg.org). FFmpeg is free software licensed under the GNU Lesser General Public
License version 2.1 or (at your option) any later version; the licence text is in
LICENSE.txt. This build was configured without --enable-gpl, --enable-nonfree and
--enable-version3, and contains no OpenH264 and no x264.

The complete corresponding source code of this build (FFmpeg, every library linked into
it, and the scripts that built it) is published with the release at:
  ${RELEASE_URL}
  file: ${SOURCE_NAME}.tar

Libraries and SDK headers compiled into ffmpeg.exe and ffprobe.exe:
${notice_libs}${toolchain_notice}
Portions of this software are copyright (c) ${year} The FreeType Project
(https://freetype.org). All rights reserved.
EOF

cat > "$pkg/BUILDINFO.txt" << EOF
release:           ${RELEASE}
ffmpeg:            ${FFMPEG_TAG} (commit ${ffmpeg_commit})
target:            ${TARGET} ${VARIANT} ${ADDIN}
ffmpeg-builds:     https://github.com/FFmpeg-Builds/FFmpeg-Builds @ ${upstream_commit}
recipe:            ${SERVER}/${REPOSITORY} @ ${recipe_commit}
recipe sha256:     ${recipe_hash}
compiler:          ${compiler}
built (UTC):       $(date -u +%Y-%m-%dT%H:%M:%SZ)
workflow run:      ${run_url}
configure:         ${configure_line}
EOF

(cd "$WORK/pkg" && zip -q -9 -r "$DIST/$NAME.zip" "$NAME")

# 6. The source archive.
git -C "$WORK/ffmpeg" archive --format=tar --prefix="ffmpeg-${FFMPEG_TAG}/" HEAD | xz -T0 > "$src/ffmpeg-${FFMPEG_TAG}.tar.xz"
git -C "$ROOT" archive --format=tar --prefix="recipe/" HEAD | xz -T0 > "$src/recipe.tar.xz"
git -C "$UPSTREAM" archive --format=tar --prefix="recipe/upstream/" HEAD | xz -T0 > "$src/ffmpeg-builds.tar.xz"
cp "$pkg/BUILDINFO.txt" "$src/BUILDINFO.txt"
cat > "$src/SOURCES.txt" << EOF
Complete corresponding source for FFmpeg ${RELEASE} (Windows x64, LGPL-2.1-or-later).

ffmpeg-${FFMPEG_TAG}.tar.xz  FFmpeg ${FFMPEG_TAG}, https://github.com/FFmpeg/FFmpeg.git @ ${ffmpeg_commit}
recipe.tar.xz             this build's scripts: ${SERVER}/${REPOSITORY} @ ${recipe_commit}
ffmpeg-builds.tar.xz      FFmpeg-Builds scripts (unpacks into recipe/upstream/) @ ${upstream_commit}
${sources_list}
To rebuild: unpack recipe.tar.xz and ffmpeg-builds.tar.xz into one folder and follow
recipe/README.md ("Building without GitHub Actions"). The overlay is applied by
recipe/overlay/apply.sh; the toolchain is built from recipe/upstream/images/.
EOF
tar -cf "$DIST/$SOURCE_NAME.tar" -C "$WORK/src" "$SOURCE_NAME"

# 7. Checksums.
(cd "$DIST" && sha256sum "$NAME.zip" "$SOURCE_NAME.tar" > SHA256SUMS)
say "release $RELEASE packaged:"
(cd "$DIST" && ls -l && cat SHA256SUMS)
