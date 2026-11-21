#!/usr/bin/env bash
# Offline tests for package.sh's licence step (D-308, D-330).
#
# Usage: bash tests/package-licences.sh <FFmpeg-Builds clone at UPSTREAM_COMMIT>
#
# Builds a fake upstream/ tree whose download cache holds every licence file named in
# package.sh's map, at the map's paths, and serves the toolchain's fetched files through a
# stand-in for `git` on PATH, so nothing touches the network. Then runs
# `package.sh --check-licences` four times:
#   1. the full tree                         -> passes
#   2. two licence files removed             -> fails and names both
#   3. a fetched GCC file with other content -> fails on its SHA-256
#   4. a stage missing from the map          -> fails (a new dependency cannot ship silently)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="$(dirname "$HERE")"
CLONE="${1:?usage: bash tests/package-licences.sh <FFmpeg-Builds clone>}"
CLONE="$(cd "$CLONE" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

# The map, read from package.sh itself so the test follows it.
map_lines() { sed -n "/^$1=(/,/^)/p" "$RECIPE/package.sh" | grep '^    "' | sed 's/^    "//; s/"$//; s/\\"/"/g'; }
mapfile -t STAGES < <(map_lines LICENCES)
mapfile -t TOOLCHAIN < <(map_lines TOOLCHAIN_LICENCES)
[[ "${#STAGES[@]}" -gt 0 && "${#TOOLCHAIN[@]}" -gt 0 ]] || { echo "could not read the maps from package.sh"; exit 1; }

# One recipe copy per case: package.sh, build.conf and a fake upstream/.
make_case() {
    local dir="$WORK/$1" entry stage script files file
    mkdir -p "$dir/upstream/util" "$dir/upstream/scripts.d" "$dir/upstream/.cache/downloads"
    cp "$RECIPE/package.sh" "$RECIPE/build.conf" "$dir/"
    cp "$CLONE/util/dl_functions.sh" "$dir/upstream/util/"
    : > "$dir/upstream/Dockerfile"
    for entry in "${STAGES[@]}"; do
        stage="${entry%%|*}"
        files="${entry##*|}"
        # The stage script at the pin (its SCRIPT_REPO and SCRIPT_COMMIT lines).
        script="$(cd "$CLONE" && find scripts.d -maxdepth 2 -name "$stage.sh" | head -1)"
        [[ -n "$script" ]] || { echo "stage $stage is not in $CLONE/scripts.d"; exit 1; }
        mkdir -p "$dir/upstream/$(dirname "$script")"
        cp "$CLONE/$script" "$dir/upstream/$script"
        echo "ENV SELF=\"$script\" STAGENAME=\"$stage\"" >> "$dir/upstream/Dockerfile"
        mkdir -p "$dir/tree/$stage"
        for file in $files; do
            mkdir -p "$dir/tree/$stage/$(dirname "$file")"
            if [[ "$file" == *.h ]]; then
                printf '/*\n * licence of %s\n */\nint code;\n' "$stage" > "$dir/tree/$stage/$file"
            else
                echo "licence of $stage: $file" > "$dir/tree/$stage/$file"
            fi
        done
        tar -cJf "$dir/upstream/.cache/downloads/$stage.tar.xz" -C "$dir/tree/$stage" .
    done
    # A stage that only configures the build (no download) must be skipped, as upstream's are.
    cp "$CLONE/scripts.d/15-base.sh" "$dir/upstream/scripts.d/"
    echo 'ENV SELF="scripts.d/15-base.sh" STAGENAME="15-base"' >> "$dir/upstream/Dockerfile"
}

# Stand-in for git: `git init`, `git -C <d> fetch ... <repo> <commit>`, `git -C <d> rev-parse
# FETCH_HEAD` and `git -C <d> show FETCH_HEAD:<file>`, served from $FAKE_GIT_FILES/<commit>/.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="."
if [[ "$1" == "-C" ]]; then dir="$2"; shift 2; fi
case "$1" in
    init) mkdir -p "${@: -1}" ;;
    fetch) commit="${@: -1}"; [[ -d "$FAKE_GIT_FILES/$commit" ]] || { echo "fake git: no $commit" >&2; exit 128; }
           echo "$commit" > "$dir/FETCH_HEAD.fake" ;;
    rev-parse) cat "$dir/FETCH_HEAD.fake" ;;
    show) commit="$(cat "$dir/FETCH_HEAD.fake")"; f="$FAKE_GIT_FILES/$commit/${2#FETCH_HEAD:}"
          [[ -f "$f" ]] || { echo "fatal: path '${2#FETCH_HEAD:}' does not exist" >&2; exit 128; }; cat "$f" ;;
    *) echo "fake git: unexpected: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/git"

# The real texts for the fetched entries, from the folder given in GCC_FILES (COPYING3 and
# COPYING.RUNTIME of the pinned GCC commit), so their pinned hashes are checked for real.
GCC_FILES="${GCC_FILES:?set GCC_FILES to a folder holding COPYING3 and COPYING.RUNTIME of the pinned GCC commit}"
serve_fetched() {
    local root="$1" entry commit pair
    for entry in "${TOOLCHAIN[@]}"; do
        IFS='|' read -r _ _ _ _ _ commit pairs <<< "$entry"
        mkdir -p "$root/$commit"
        for pair in $pairs; do cp "$GCC_FILES/${pair%%=*}" "$root/$commit/"; done
    done
}

run_case() { # name expect(pass|fail) patterns...
    local name="$1" expect="$2" out rc=0
    shift 2
    out="$(cd "$WORK/$name" && PATH="$WORK/bin:$PATH" FAKE_GIT_FILES="$WORK/$name/fetched" \
        bash package.sh --check-licences 2>&1)" || rc=$?
    echo "=== $name (exit $rc)"
    echo "$out"
    local ok=1 pattern
    [[ "$expect" == pass && "$rc" -eq 0 ]] || [[ "$expect" == fail && "$rc" -eq 1 ]] || ok=0
    for pattern in "$@"; do grep -qF -- "$pattern" <<< "$out" || { echo "    missing: $pattern"; ok=0; }; done
    if [[ "$ok" == 1 ]]; then echo "--- $name: OK"; else echo "--- $name: WRONG"; failures=$((failures + 1)); fi
}

# 1. Everything present.
make_case full
serve_fetched "$WORK/full/fetched"
run_case full pass "PASS (licences)"

# 2. Two licence files of two different stages removed.
make_case two-missing
serve_fetched "$WORK/two-missing/fetched"
for stage_file in "10-mingw|mingw-w64-libraries/winpthreads/COPYING" "20-libiconv|COPYING.LIB"; do
    stage="${stage_file%%|*}"
    file="${stage_file##*|}"
    rm "$WORK/two-missing/tree/$stage/$file"
    tar -cJf "$WORK/two-missing/upstream/.cache/downloads/$stage.tar.xz" -C "$WORK/two-missing/tree/$stage" .
done
run_case two-missing fail \
    "stage 10-mingw: licence file mingw-w64-libraries/winpthreads/COPYING not found in its source" \
    "stage 20-libiconv: licence file COPYING.LIB not found in its source" \
    "2 problem(s)"

# 3. The fetched COPYING.RUNTIME differs from the pinned text by one line.
make_case wrong-hash
serve_fetched "$WORK/wrong-hash/fetched"
commit="$(IFS='|' read -r _ _ _ _ _ c _ <<< "${TOOLCHAIN[0]}"; echo "$c")"
echo "one line more" >> "$WORK/wrong-hash/fetched/$commit/COPYING.RUNTIME"
run_case wrong-hash fail "toolchain gcc: COPYING.RUNTIME has SHA-256" "1 problem(s)"

# 4. A built stage without a map entry.
make_case unlisted
serve_fetched "$WORK/unlisted/fetched"
cp "$CLONE/scripts.d/25-libogg.sh" "$WORK/unlisted/upstream/scripts.d/"
echo 'ENV SELF="scripts.d/25-libogg.sh" STAGENAME="25-libogg"' >> "$WORK/unlisted/upstream/Dockerfile"
echo x > "$WORK/unlisted/x" && tar -cJf "$WORK/unlisted/upstream/.cache/downloads/25-libogg.tar.xz" -C "$WORK/unlisted" x
run_case unlisted fail "stage 25-libogg was built but has no licence entry in package.sh" "1 problem(s)"

echo
if [[ "$failures" == 0 ]]; then echo "package-licences: PASS (4 cases)"; else echo "package-licences: FAIL ($failures of 4 cases)"; exit 1; fi
