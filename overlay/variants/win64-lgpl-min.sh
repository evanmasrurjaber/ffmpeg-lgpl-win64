#!/bin/bash
# The lgpl-min variant (D-045): static Windows x64 build of ffmpeg.exe and ffprobe.exe under
# LGPL-2.1-or-later. overlay/apply.sh copies this file into upstream/variants/.
#
# The name starts with "lgpl", so every upstream `[[ $VARIANT == lgpl* ]]` exclusion (x264,
# x265, avisynth, ...) still applies. Unlike upstream's defaults-lgpl.sh there is no
# --enable-version3: every library that would force LGPLv3 is dropped in
# overlay/disabled-stages.txt.
#
#   --disable-network  no network protocols; the app that ships this build is offline
#   --disable-ffplay   only ffmpeg and ffprobe are shipped
#   --disable-bzlib    nothing we keep needs it; stops the toolchain's copy being autodetected
source "$(dirname "$BASH_SOURCE")"/windows-install-static.sh

FF_CONFIGURE="--disable-debug --disable-network --disable-ffplay --disable-bzlib"
FF_CFLAGS=""
FF_CXXFLAGS=""
FF_LDFLAGS=""
GIT_BRANCH="master"
LICENSE_FILE="COPYING.LGPLv2.1"
