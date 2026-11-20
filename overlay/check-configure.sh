#!/usr/bin/env bash
# Checks what FFmpeg's configure enables against overlay/allowed-libs.txt (D-045).
#
# Usage:
#   bash overlay/check-configure.sh flags   upstream/Dockerfile   # after generate.sh
#   bash overlay/check-configure.sh summary build.log             # after build.sh
#
# flags:   reads FF_CONFIGURE from the generated Dockerfile (every --enable-... switch).
# summary: reads configure's "External libraries" summaries from the build log, which also
#          shows what configure autodetected on its own, and the configure command line that
#          build.sh traces as "+ ./configure ...".
# Fails if anything is enabled that the list does not allow, if a required name is missing,
# if a forbidden licence switch or library appears, or if the configure line has
# --enable-libmfx or (summary) lacks --enable-libvpl (D-306).
set -euo pipefail

OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
INPUT="${2:-}"

fail() { echo "check-configure.sh: FAIL: $*" >&2; exit 1; }
norm() { tr '-' '_'; }

[[ "$MODE" == flags || "$MODE" == summary ]] || fail "usage: check-configure.sh flags|summary <file>"
[[ -f "$INPUT" ]] || fail "no such file: $INPUT"

# Names that must never be enabled, whatever allowed-libs.txt says.
FORBIDDEN="gpl nonfree version3 libopenh264 libx264 libx265 libkvazaar libvvenc libxvid openssl gmp"

# Read allowed-libs.txt: name and requirement (yes, summary, no).
declare -A ALLOWED=()
while read -r name need _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    case "$need" in yes|summary|no) ;; *) fail "allowed-libs.txt: '$name' has requirement '$need'" ;; esac
    ALLOWED["$(norm <<< "$name")"]="$need"
done < <(sed 's/#.*//' "$OVERLAY/allowed-libs.txt")

# Collect what is enabled.
declare -a ENABLED=()
if [[ "$MODE" == flags ]]; then
    line="$(grep -m1 '^ *FF_CONFIGURE="' "$INPUT" || true)"
    [[ -n "$line" ]] || fail "no FF_CONFIGURE line in $INPUT (run generate.sh first)"
    configure="${line#*FF_CONFIGURE=\"}"
    configure="${configure%%\"*}"
    echo "FF_CONFIGURE: $configure"
    for word in $configure; do
        if [[ "$word" == --enable-* ]]; then
            ENABLED+=("$(norm <<< "${word#--enable-}")")
        fi
    done
    for need in --disable-network --disable-ffplay; do
        if [[ " $configure " != *" $need "* ]]; then
            fail "FF_CONFIGURE lacks $need"
        fi
    done
else
    section="$(awk '
        /^External libraries:$/ { on = 1; next }
        /^External libraries providing hardware acceleration:$/ { next }
        /^Libraries:$/ { if (on) exit }
        on { print }' "$INPUT")"
    grep -q '^External libraries:$' "$INPUT" || fail "configure summary not found in $INPUT"
    line="$(grep -m1 -E '^\++ \./configure ' "$INPUT" || true)"
    [[ -n "$line" ]] || fail "no '+ ./configure ...' line in $INPUT"
    configure="${line#*./configure }"
    echo "configure: $configure"
    echo "configure summary (external libraries, then hardware acceleration):"
    echo "$section" | sed '/^[[:space:]]*$/d; s/^/  /'
    for word in $section; do
        ENABLED+=("$(norm <<< "$word")")
    done
fi
[[ "${#ENABLED[@]}" -gt 0 ]] || fail "nothing enabled was found in $INPUT"

problems=0
problem() { echo "  FAIL  $*"; problems=$((problems + 1)); }

# D-306: --enable-libvpl makes configure check the oneVPL dispatcher (pkg-config "vpl") under
# the name libmfx, so the summary lists libmfx beside libvpl. That is allowed; the old Intel
# Media SDK (--enable-libmfx) never is.
if [[ " $configure " == *" --enable-libmfx "* ]]; then
    problem "--enable-libmfx is on the configure line (the old Intel Media SDK, D-306)"
fi
if [[ "$MODE" == summary && " $configure " != *" --enable-libvpl "* ]]; then
    problem "the configure line lacks --enable-libvpl, the only way libmfx may be enabled (D-306)"
fi

declare -A SEEN=()
for name in "${ENABLED[@]}"; do
    SEEN["$name"]=1
    for bad in $FORBIDDEN; do
        if [[ "$name" == "$(norm <<< "$bad")" ]]; then
            problem "$name is forbidden"
        fi
    done
    if [[ ! -v ALLOWED["$name"] ]]; then
        problem "$name is enabled but not in allowed-libs.txt"
    fi
done
for name in "${!ALLOWED[@]}"; do
    need="${ALLOWED[$name]}"
    if [[ "$need" == yes || ( "$need" == summary && "$MODE" == summary ) ]]; then
        if [[ ! -v SEEN["$name"] ]]; then
            problem "$name is required but not enabled"
        fi
    fi
done

echo "enabled ($MODE): $(printf '%s\n' "${ENABLED[@]}" | sort -u | tr '\n' ' ')"
if [[ "$problems" -gt 0 ]]; then
    fail "$problems problem(s) against allowed-libs.txt"
fi
echo "check-configure.sh: PASS ($MODE): ${#ENABLED[@]} enabled, all allowed, all required present"
