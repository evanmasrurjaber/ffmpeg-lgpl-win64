# ffmpeg-lgpl-win64

Static `ffmpeg.exe` and `ffprobe.exe` for Windows x64, licensed under the GNU LGPL version
2.1 or later. They are built from FFmpeg's release tag with the
[FFmpeg-Builds](https://github.com/FFmpeg-Builds/FFmpeg-Builds) scripts, plus a small,
checked overlay that drops everything this build does not need.

- No `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.
- No OpenH264, x264, x265, kvazaar or vvenc, so no software encoder for H.264, HEVC or VVC.
- No network protocols (`--disable-network`). No ffplay.
- 15 libraries kept, listed with their licences in each release's `NOTICE.txt`:
  - zlib, libiconv;
  - FriBidi, FreeType, HarfBuzz, libunibreak, libass;
  - dav1d, libvpx, Opus, zimg;
  - the AMD AMF, NVIDIA NVENC and Intel libvpl interfaces;
  - the mingw-w64 runtime.
- Windows' own Media Foundation (`h264_mf`) and D3D11/D3D12/DXVA2 decoding are used as
  configure finds them.
- NVENC is built against the Video SDK 12.2 headers (nv-codec-headers `n12.2.72.0`), so it
  works with NVIDIA drivers **551.76 or newer**. FFmpeg-Builds' default 13.1 headers would
  need 610.00.

Each release carries the zip, the complete corresponding source (`…-source.tar`) and
`SHA256SUMS`. The source archive is this repository's source offer for the LGPL.

## Where this repository comes from

This repository is a copy of `tools/ffmpeg-build/` in the ClipForge repository, at commit
`f4f3614c868d3c59d355f7f7692f9b0639e8924a`. Changes are made and reviewed there first, then copied here.

## Layout

| Path | What it is |
| --- | --- |
| `build.conf` | FFmpeg tag, build number, the FFmpeg-Builds commit, target and variant |
| `upstream/` | FFmpeg-Builds as a git submodule, checked out at `UPSTREAM_COMMIT` |
| `LICENSE` | MIT licence for this repository's own files |
| `overlay/apply.sh` | Applies the overlay to `upstream/`. Every edit is checked first |
| `overlay/variants/win64-lgpl-min.sh` | The variant: LGPL-2.1, static, no network, no ffplay |
| `overlay/disabled-stages.txt` | The FFmpeg-Builds stages this build drops, with reasons |
| `overlay/allowed-libs.txt` | What configure may enable; anything else fails the build |
| `overlay/check-configure.sh` | Checks the configure flags and configure's summary against that list |
| `package.sh` | Makes the release zip, the source archive and `SHA256SUMS` |
| `.github/workflows/build.yml` | check → build → verify → draft release, run by hand |
| `scripts/verify-ffmpeg.ps1` | Checks the binaries on Windows (copied from ClipForge) |

## Making a release

1. Actions → **Build FFmpeg** → **Run workflow** on `main`. The `check` job takes about a
   minute; `build` takes about 1.5–2 hours from scratch.
2. When it finishes, open the **draft** release named `n<version>-r<build>`.
3. Download the zip and run the verify script on a Windows PC:
   `pwsh -NoProfile -File scripts/verify-ffmpeg.ps1 -FfmpegDir <unzipped>\bin -ExpectedVersion <tag>`.
4. Publish the draft. Immutable releases are on, so the tag and files can never change
   afterwards.

## Changing the build

**A rebuild of the same FFmpeg** (a new FFmpeg-Builds pin, a changed library list, a
changed workflow): raise `BUILD_NUMBER` in `build.conf`. The `check` job refuses to build a
tag that is already released.

**A new FFmpeg-Builds pin:**
1. Choose the newest FFmpeg-Builds commit that is at least 14 days old.
2. Run `git -C upstream fetch origin` and `git -C upstream checkout <sha>`.
3. Set `UPSTREAM_COMMIT` in `build.conf` to that SHA and raise `BUILD_NUMBER`.
4. Commit the submodule and `build.conf` together.

`overlay/apply.sh` stops if any script it changes has moved or changed. The configure check
stops if upstream turned on a library that `allowed-libs.txt` doesn't list.

**A new FFmpeg version:** set `FFMPEG_TAG` (and `ADDIN` for a new major.minor), reset
`BUILD_NUMBER` to 1, and review `disabled-stages.txt` against that version's stages.

## Building without GitHub Actions

You need Linux with Docker and buildx, network access, and plenty of free disk.
FFmpeg-Builds' own clean-up script, `upstream/util/free_disk_space.sh`, aims for 80 GB.

```bash
git clone --recursive <this repository> && cd <it>
bash overlay/apply.sh
source build.conf
(cd upstream && ./makeimage.sh "$TARGET" "$VARIANT" "$ADDIN")
(cd upstream && GIT_BRANCH_OVERRIDE="$FFMPEG_TAG" ./build.sh "$TARGET" "$VARIANT" "$ADDIN") 2>&1 | tee build.log
bash overlay/check-configure.sh summary build.log
GITHUB_REPOSITORY=<owner>/<repo> bash package.sh build.log
```

The result is in `dist/`. The toolchain image is built from `upstream/images/`; it is not
pinned (crosstool-NG and the Ubuntu base image move), so two builds can differ.
`BUILDINFO.txt` records the compiler that was used.

## Licences

- **This repository's own files** (the overlay, `package.sh`, the workflow, this README) are MIT-licensed; see `LICENSE`.
- **The FFmpeg-Builds scripts in `upstream/`** are MIT-licensed by their own authors; see `upstream/LICENSE`.
- **The binaries** are LGPL-2.1-or-later; see `LICENSE.txt`, `NOTICE.txt` and `licenses/` inside each release zip.
