#!/usr/bin/env bash
# Applies the lgpl-min overlay to the pinned FFmpeg-Builds checkout (D-045).
#
# Usage: bash overlay/apply.sh [UPSTREAM_DIR]      (default: upstream/ next to build.conf)
#
# Every edit first checks that its target exists and looks exactly as expected, and the
# script stops with a non-zero exit at the first mismatch. A pin bump that renames or
# rewrites a file touched here therefore fails in seconds, not hours into the build.
# It runs once, on a clean checkout of the pinned commit.
#
# Edits: add the variant; disable the stages in disabled-stages.txt; libass without
# fontconfig; NVENC headers from Video SDK 12.2; the version suffix r<build>.
set -euo pipefail

OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$OVERLAY")"

fail() { echo "apply.sh: FAIL: $*" >&2; exit 1; }
say() { echo "apply.sh: $*"; }

UPSTREAM="${1:-$ROOT/upstream}"
[[ -d "$UPSTREAM/scripts.d" ]] || fail "no FFmpeg-Builds checkout at $UPSTREAM (run: git submodule update --init)"
UPSTREAM="$(cd "$UPSTREAM" && pwd)"

# shellcheck source=../build.conf
source "$ROOT/build.conf"
[[ "$FFMPEG_TAG" =~ ^n[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "build.conf: FFMPEG_TAG '$FFMPEG_TAG' is not a release tag like n9.0.2"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "build.conf: BUILD_NUMBER '$BUILD_NUMBER' is not a positive integer"
[[ "$UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "build.conf: UPSTREAM_COMMIT is not a full commit SHA"

# 1. The checkout is the pinned commit, unmodified.
head="$(git -C "$UPSTREAM" rev-parse HEAD)"
[[ "$head" == "$UPSTREAM_COMMIT" ]] || fail "upstream is at $head but build.conf pins $UPSTREAM_COMMIT"
[[ -z "$(git -C "$UPSTREAM" status --porcelain)" ]] || fail "upstream has local changes; apply the overlay to a clean checkout (it runs once)"

# 2. The files this recipe relies on without changing them.
grep -q '^package_variant()' "$UPSTREAM/variants/windows-install-static.sh" \
    || fail "variants/windows-install-static.sh no longer defines package_variant"
grep -qxF "GIT_BRANCH=\"release/${ADDIN}\"" "$UPSTREAM/addins/${ADDIN}.sh" 2>/dev/null \
    || fail "addins/${ADDIN}.sh is missing or no longer selects release/${ADDIN}"
grep -qF 'GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"' "$UPSTREAM/build.sh" \
    || fail "build.sh no longer honours GIT_BRANCH_OVERRIDE, which pins the FFmpeg tag"

# 3. Our variant, copied in without overwriting anything upstream.
variant="${TARGET}-${VARIANT}.sh"
[[ -f "$OVERLAY/variants/$variant" ]] || fail "missing overlay/variants/$variant"
[[ ! -e "$UPSTREAM/variants/$variant" ]] || fail "upstream already has variants/$variant"
cp "$OVERLAY/variants/$variant" "$UPSTREAM/variants/$variant"
say "added variants/$variant"

# 4. Dropped stages: append an ffbuild_enabled that always says no. In bash the last
#    definition wins, and generate.sh then emits the stage's --disable-... flag.
disabled=0
while IFS= read -r line || [[ -n "$line" ]]; do
    stage="${line%%#*}"
    stage="${stage//[[:space:]]/}"
    [[ -n "$stage" ]] || continue
    script="$UPSTREAM/scripts.d/$stage"
    [[ -f "$script" ]] || fail "disabled-stages.txt: scripts.d/$stage does not exist"
    [[ "$(grep -c '^ffbuild_enabled() {$' "$script")" == 1 ]] \
        || fail "scripts.d/$stage does not define ffbuild_enabled exactly once"
    printf '\n# Added by overlay/apply.sh: not part of the lgpl-min build.\nffbuild_enabled() {\n    return -1\n}\n' >> "$script"
    disabled=$((disabled + 1))
done < "$OVERLAY/disabled-stages.txt"
[[ "$disabled" -gt 0 ]] || fail "disabled-stages.txt lists no stages"
say "disabled $disabled stages"

# 5. libass without fontconfig: DirectWrite is its font provider on Windows.
libass="$UPSTREAM/scripts.d/50-libass.sh"
[[ "$(grep -cF -e '-Dfontconfig=enabled' "$libass")" == 1 ]] \
    || fail "50-libass.sh does not contain '-Dfontconfig=enabled' exactly once"
grep -qF -e '-Ddirectwrite=enabled' "$libass" || fail "50-libass.sh no longer enables DirectWrite"
sed -i 's/-Dfontconfig=enabled/-Dfontconfig=disabled/' "$libass"
[[ "$(grep -cF -e '-Dfontconfig=disabled' "$libass")" == 1 ]] || fail "50-libass.sh edit did not apply"
say "libass builds without fontconfig"

# 6. NVENC headers from Video SDK 12.2 (tag n12.2.72.0) instead of 13.1, so NVENC works with
#    NVIDIA drivers 551.76 and newer rather than 610.00 (D-060). FFmpeg 9 builds from the
#    stage's first checkout ("cd ffnvcodec"), whose commit is SCRIPT_COMMIT.
nvc="$UPSTREAM/scripts.d/50-ffnvcodec.sh"
nvc_old='SCRIPT_COMMIT="f2053071ea93137255b6dcf42e9b4c9e0965a44e"'
nvc_new='SCRIPT_COMMIT="c69278340ab1d5559c7d7bf0edf615dc33ddbba7"'
[[ "$(grep -cxF -e "$nvc_old" "$nvc")" == 1 ]] || fail "50-ffnvcodec.sh does not pin exactly $nvc_old"
grep -qxF -e '        cd ffnvcodec' "$nvc" || fail "50-ffnvcodec.sh no longer builds FFmpeg 9 from its ffnvcodec checkout"
sed -i "s/^${nvc_old}\$/${nvc_new}/" "$nvc"
[[ "$(grep -cxF -e "$nvc_new" "$nvc")" == 1 ]] || fail "50-ffnvcodec.sh edit did not apply"
say "NVENC headers pinned to n12.2.72.0 (NVIDIA driver 551.76 or newer)"

# 7. The version suffix: `ffmpeg -version` prints <tag>-r<build> instead of a build date.
build="$UPSTREAM/build.sh"
old='--extra-version="\$(date +%Y%m%d)"'
new="--extra-version=\"r${BUILD_NUMBER}\""
[[ "$(grep -cF -e "$old" "$build")" == 1 ]] || fail "build.sh does not contain '$old' exactly once"
content="$(< "$build")"
printf '%s\n' "${content/"$old"/"$new"}" > "$build"
[[ "$(grep -cF -e "$new" "$build")" == 1 ]] || fail "build.sh edit did not apply"
say "FFmpeg version suffix is r${BUILD_NUMBER} (ffmpeg -version: ${FFMPEG_TAG}-r${BUILD_NUMBER})"

say "overlay applied to FFmpeg-Builds $UPSTREAM_COMMIT"
