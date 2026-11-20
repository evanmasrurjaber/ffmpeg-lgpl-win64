#Requires -Version 7.4
<#
.SYNOPSIS
Checks that an FFmpeg build is the LGPL build ClipForge ships (F6, D-045).

.DESCRIPTION
Runs ffmpeg.exe and ffprobe.exe from -FfmpegDir by absolute path (PATH is never searched)
and checks:
  1. both exist and print the expected version (-ExpectedVersion, the release tag);
  2. -buildconf: no gpl, nonfree, version3 or forbidden library; every --enable-* switch
     is one this build expects; --disable-network is present;
  3. -L: LGPL version 2.1 or later;
  4. -encoders: h264_nvenc, h264_qsv, h264_amf, h264_mf, libvpx-vp9, libopus and aac are
     compiled in, and no software H.264, HEVC or VVC encoder is;
  5. -decoders and -filters: libdav1d, h264, hevc, aac, opus; ass, subtitles, zscale;
  6. a one-second test encode with each video encoder (PASS, or UNAVAILABLE on this
     machine; FAIL only for encoders named in -RequireEncoders), and one subtitle frame
     drawn by libass with a fonts folder.
Prints one line per check and a summary, and exits 1 if any check FAILs.
Not part of the gate until W01-T04a Part 2 (D-048).

.EXAMPLE
pwsh -NoProfile -File scripts/verify-ffmpeg.ps1 -FfmpegDir tools/bin -ExpectedVersion n9.0.2-r1

.EXAMPLE
pwsh -NoProfile -File scripts/verify-ffmpeg.ps1 -RequireEncoders h264_nvenc,libvpx-vp9
#>
[CmdletBinding()]
param(
    # Folder holding ffmpeg.exe and ffprobe.exe. Default: CLIPFORGE_FFMPEG_DIR, else tools/bin.
    [string] $FfmpegDir = '',
    # The version both programs must print: the release tag, such as n9.0.2-r1 (D-045).
    [string] $ExpectedVersion = 'n9.0.2-r1',
    # Encoders whose test encode must work on this machine (comma-separated is accepted).
    [string[]] $RequireEncoders = @('libvpx-vp9')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What this build must and must not contain (docs/specs/F06-ffmpeg.md).
$ExpectedEnables = @(
    'pthreads', 'iconv', 'zlib', 'libfribidi', 'libfreetype', 'libharfbuzz', 'libass',
    'libdav1d', 'libvpx', 'libopus', 'libzimg', 'amf', 'ffnvcodec', 'cuda-llvm', 'libvpl'
)
$ForbiddenEnables = @(
    'gpl', 'nonfree', 'version3', 'libx264', 'libx265', 'libopenh264', 'libkvazaar',
    'libvvenc', 'libxvid', 'openssl', 'gmp'
)
$RequiredEncoders = @('h264_nvenc', 'h264_qsv', 'h264_amf', 'h264_mf', 'libvpx-vp9', 'libopus', 'aac')
$RequiredDecoders = @('libdav1d', 'h264', 'hevc', 'aac', 'opus')
$RequiredFilters = @('ass', 'subtitles', 'zscale')
# Video encoders given a real test encode, in ClipForge's preference order (D-022).
$TestEncoders = [ordered]@{
    'h264_nvenc' = @()
    'h264_qsv'   = @()
    'h264_amf'   = @()
    'h264_mf'    = @()
    'libvpx-vp9' = @('-deadline', 'realtime', '-cpu-used', '8', '-b:v', '1M')
}
# Hardware encoder interfaces: an H.264/HEVC/VVC encoder whose name ends otherwise is software.
$HardwareSuffix = '_(nvenc|qsv|amf|mf|d3d12va|vaapi|vulkan|videotoolbox|v4l2m2m|mediacodec|omx|rkmpp|oh)$'

$RequireEncoders = @($RequireEncoders | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })

$Results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Status, [string] $Check, [string] $Detail) {
    $Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail })
    Write-Host ('{0,-11} {1,-11} {2}' -f $Status, $Check, $Detail)
}

# Runs a program by absolute path with an argument list (no shell, no PATH lookup).
function Invoke-Tool {
    param(
        [string] $Exe,
        [string[]] $Arguments,
        [int] $TimeoutSeconds = 60,
        [string] $WorkingDirectory = $PWD.Path
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $WorkingDirectory
    $process = [System.Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Out = ''; Err = "timed out after $TimeoutSeconds s" }
    }
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $false
        Out      = $stdout.GetAwaiter().GetResult()
        Err      = $stderr.GetAwaiter().GetResult()
    }
}

# FFmpeg's first error line names the cause; the later ones are consequences.
function Get-FirstLine([string] $Text) {
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '(no output)' }
    return $lines[0].Trim()
}

# Names from the -encoders / -decoders listings, with the codec each one handles.
function Get-CodecList([string] $Listing) {
    foreach ($line in $Listing -split "`r?`n") {
        if ($line -match '^\s*[VAS][A-Z.]{5}\s+(\S+)\s+(.*)$' -and $Matches[1] -ne '=') {
            $name = $Matches[1]
            $codec = if ($Matches[2] -match '\(codec (\S+)\)\s*$') { $Matches[1] } else { $name }
            [pscustomobject]@{ Name = $name; Codec = $codec }
        }
    }
}

# 0. Where the binaries are.
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $FfmpegDir) {
    $FfmpegDir = if ($env:CLIPFORGE_FFMPEG_DIR) { $env:CLIPFORGE_FFMPEG_DIR } else { Join-Path $RepoRoot 'tools/bin' }
}
$FfmpegDir = [System.IO.Path]::GetFullPath($FfmpegDir, $PWD.Path)
$ffmpeg = Join-Path $FfmpegDir 'ffmpeg.exe'
$ffprobe = Join-Path $FfmpegDir 'ffprobe.exe'
Write-Host "verify-ffmpeg: $FfmpegDir (by absolute path; PATH is never searched)"
Write-Host "verify-ffmpeg: expected version $ExpectedVersion; required encoders: $($RequireEncoders -join ', ')"
Write-Host ''

$missing = @($ffmpeg, $ffprobe | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missing.Count -gt 0) {
    Add-Result 'FAIL' 'files' "missing: $($missing -join ', ')"
    Write-Host ''
    Write-Host 'VERIFY: FAIL (binaries not found)'
    exit 1
}
Add-Result 'PASS' 'files' 'ffmpeg.exe and ffprobe.exe present'

# 1. Version.
foreach ($tool in @(@{ Name = 'ffmpeg'; Path = $ffmpeg }, @{ Name = 'ffprobe'; Path = $ffprobe })) {
    $run = Invoke-Tool $tool.Path @('-hide_banner', '-version')
    $first = ($run.Out -split "`r?`n")[0]
    $want = "$($tool.Name) version $ExpectedVersion "
    if ($run.ExitCode -eq 0 -and $first.StartsWith($want, [StringComparison]::Ordinal)) {
        Add-Result 'PASS' 'version' "$($tool.Name) prints $ExpectedVersion"
    }
    else {
        Add-Result 'FAIL' 'version' "$($tool.Name) prints '$first', expected '$($want.Trim())'"
    }
}

# 2. Build configuration.
$buildconf = (Invoke-Tool $ffmpeg @('-hide_banner', '-buildconf')).Out
$switches = @([regex]::Matches($buildconf, '(?m)^\s*(--\S+)') | ForEach-Object { $_.Groups[1].Value })
$enabled = @($switches | Where-Object { $_ -like '--enable-*' } | ForEach-Object { $_.Substring(9) })
$buildconfOk = $true
foreach ($name in $ForbiddenEnables) {
    if ($enabled -contains $name) {
        Add-Result 'FAIL' 'buildconf' "--enable-$name is forbidden"
        $buildconfOk = $false
    }
}
$unexpected = @($enabled | Where-Object { $_ -notin $ExpectedEnables -and $_ -notin $ForbiddenEnables })
if ($unexpected.Count -gt 0) {
    Add-Result 'FAIL' 'buildconf' "enabled but not part of this build: $($unexpected -join ' ')"
    $buildconfOk = $false
}
$absent = @($ExpectedEnables | Where-Object { $_ -notin $enabled })
if ($absent.Count -gt 0) {
    Add-Result 'FAIL' 'buildconf' "expected but not enabled: $($absent -join ' ')"
    $buildconfOk = $false
}
if ($switches -notcontains '--disable-network') {
    Add-Result 'FAIL' 'buildconf' '--disable-network is missing'
    $buildconfOk = $false
}
if ($buildconfOk) {
    Add-Result 'PASS' 'buildconf' "$($enabled.Count) --enable switches, all expected; --disable-network"
}

# 3. Licence.
$licence = (Invoke-Tool $ffmpeg @('-hide_banner', '-L')).Out -replace '\s+', ' '
if ($licence.Contains('GNU Lesser General Public License') -and
    $licence.Contains('either version 2.1 of the License, or (at your option) any later version') -and
    -not $licence.Contains('version 3 of the License')) {
    Add-Result 'PASS' 'licence' 'LGPL version 2.1 or later'
}
else {
    $said = if ($licence -match 'either version (\S+) of the License') { "version $($Matches[1])" } else { 'no LGPL version' }
    $kind = if ($licence.Contains('Lesser General Public License')) { 'LGPL' } else { 'not the LGPL' }
    Add-Result 'FAIL' 'licence' "-L says $kind, $said; expected LGPL version 2.1 or later"
}

# 4. Encoders.
$encoders = @(Get-CodecList (Invoke-Tool $ffmpeg @('-hide_banner', '-encoders')).Out)
$encoderNames = @($encoders | ForEach-Object Name)
$noEncoder = @($RequiredEncoders | Where-Object { $_ -notin $encoderNames })
if ($noEncoder.Count -gt 0) {
    Add-Result 'FAIL' 'encoders' "not compiled in: $($noEncoder -join ' ')"
}
else {
    Add-Result 'PASS' 'encoders' "compiled in: $($RequiredEncoders -join ' ')"
}
$software = @($encoders | Where-Object { $_.Codec -in @('h264', 'hevc', 'vvc') -and $_.Name -notmatch $HardwareSuffix })
foreach ($encoder in $software) {
    Add-Result 'FAIL' 'encoders' "software $($encoder.Codec) encoder $($encoder.Name) is forbidden"
}
if ($software.Count -eq 0) {
    Add-Result 'PASS' 'encoders' 'no software H.264, HEVC or VVC encoder'
}

# 5. Decoders and filters.
$decoderNames = @(Get-CodecList (Invoke-Tool $ffmpeg @('-hide_banner', '-decoders')).Out | ForEach-Object Name)
$noDecoder = @($RequiredDecoders | Where-Object { $_ -notin $decoderNames })
if ($noDecoder.Count -gt 0) { Add-Result 'FAIL' 'decoders' "missing: $($noDecoder -join ' ')" }
else { Add-Result 'PASS' 'decoders' "present: $($RequiredDecoders -join ' ')" }

$filterNames = @([regex]::Matches((Invoke-Tool $ffmpeg @('-hide_banner', '-filters')).Out, '(?m)^\s*[A-Z.|]{2,4}\s+(\S+)\s+\S*->') |
        ForEach-Object { $_.Groups[1].Value })
$noFilter = @($RequiredFilters | Where-Object { $_ -notin $filterNames })
if ($noFilter.Count -gt 0) { Add-Result 'FAIL' 'filters' "missing: $($noFilter -join ' ')" }
else { Add-Result 'PASS' 'filters' "present: $($RequiredFilters -join ' ')" }

# 6. Real encodes on this machine.
$encodeResults = [ordered]@{}
$toTest = @($TestEncoders.Keys) + @($RequireEncoders | Where-Object { $_ -notin $TestEncoders.Keys })
foreach ($name in $toTest) {
    $required = $name -in $RequireEncoders
    if ($name -notin $encoderNames) {
        $encodeResults[$name] = 'NOT BUILT'
        if ($required) { Add-Result 'FAIL' 'encode' "$name is required but not compiled in" }
        continue
    }
    $extra = if ($TestEncoders.Contains($name)) { $TestEncoders[$name] } else { @() }
    $arguments = @('-hide_banner', '-nostdin', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc2=size=960x540:rate=30:duration=1',
        '-c:v', $name) + $extra + @('-f', 'null', '-')
    $run = Invoke-Tool $ffmpeg $arguments -TimeoutSeconds 30
    if ($run.ExitCode -eq 0) {
        $encodeResults[$name] = 'PASS'
        Add-Result 'PASS' 'encode' "$name works on this machine"
    }
    else {
        $why = Get-FirstLine $run.Err
        $encodeResults[$name] = 'UNAVAILABLE'
        if ($required) { Add-Result 'FAIL' 'encode' "$name is required but failed: $why" }
        else { Add-Result 'UNAVAILABLE' 'encode' "${name}: $why" }
    }
}

# libass: one frame with a subtitle, fonts taken from a fonts folder (how ClipForge calls it).
$work = Join-Path ([System.IO.Path]::GetTempPath()) "verify-ffmpeg-$([guid]::NewGuid().ToString('N'))"
try {
    $fonts = Join-Path $work 'fonts'
    New-Item -ItemType Directory -Path $fonts -Force | Out-Null
    $arial = Join-Path $env:WINDIR 'Fonts\arial.ttf'
    if (Test-Path -LiteralPath $arial) { Copy-Item -LiteralPath $arial -Destination $fonts }
    $ass = @(
        '[Script Info]', 'ScriptType: v4.00+', 'PlayResX: 640', 'PlayResY: 360', '',
        '[V4+ Styles]',
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
        'Style: Default,Arial,32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1', '',
        '[Events]',
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
        'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Verify'
    )
    Set-Content -LiteralPath (Join-Path $work 'test.ass') -Value $ass -Encoding utf8NoBOM
    $run = Invoke-Tool $ffmpeg @('-hide_banner', '-nostdin', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=640x360:d=1',
        '-vf', 'subtitles=filename=test.ass:fontsdir=fonts', '-frames:v', '1', '-f', 'null', '-') -TimeoutSeconds 30 -WorkingDirectory $work
    if ($run.ExitCode -eq 0) { Add-Result 'PASS' 'libass' 'subtitles filter drew a frame with fontsdir' }
    else { Add-Result 'FAIL' 'libass' "subtitles filter failed: $(Get-FirstLine $run.Err)" }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Summary.
$failed = @($Results | Where-Object Status -EQ 'FAIL').Count
Write-Host ''
Write-Host ('Encoders on this machine: ' + (($encodeResults.Keys | ForEach-Object { "$_ $($encodeResults[$_])" }) -join ', '))
if ($failed -gt 0) {
    Write-Host "VERIFY: FAIL ($failed of $($Results.Count) checks failed)"
    exit 1
}
Write-Host "VERIFY: PASS ($($Results.Count) checks)"
exit 0
