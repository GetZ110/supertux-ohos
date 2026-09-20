<#
.SYNOPSIS
  Package the cross-built SuperTux into a HarmonyOS HAP, sign it, and (optionally) install, launch
  and verify it on a connected device.

.DESCRIPTION
  Run scripts/build-supertux-ohos.ps1 first: build/supertux/libmain.so must exist.

  Steps:
    1. walk libmain.so's ELF NEEDED list (recursively) and copy every non-system shared library
       into app/supertux-ohos/entry/libs/arm64-v8a/, which is where hvigor packages prebuilt
       native libraries from. libSDL3.so gets special treatment: ArkTS loads it by the plain
       "libSDL3.so" name (XComponent libraryname + `import sdl from 'libSDL3.so'`), so the
       versioned file must NOT also be present -- with both, HarmonyOS loads the library twice and
       each copy gets its own globals, which makes SDL_CreateWindow fail with "Don't have Native
       XComponent or Native Window" while the XComponent callback happily stores the window in the
       other copy. SDL is built without a SOVERSION here (patches/sdl-ohos.patch) so libmain.so
       asks for "libSDL3.so" too.
    2. build resources/rawfile/data.zip from SuperTux's data/ directory (music/ excluded by
       default: it is ~143 MB of the ~312 MB and optional). The ArkTS shell extracts this into
       the app sandbox at first launch, because PhysFS cannot read the HAP's rawfile space.
    3. hvigorw assembleHap.
    4. sign with hap-sign-tool. hvigor's own signingConfigs want DevEco's encrypted password
       format, so the HAP is signed after the fact instead.
    5. install with hdc, launch, dump hilog, take a screenshot.

  Signing material is never read from the repository: point -Cert/-Profile/-Keystore at your own
  AppGallery Connect debug certificate, provisioning profile and keystore, and pass the password
  via -KeyPwd or the SUPERTUX_OHOS_KEY_PWD environment variable. See docs/signing-howto.md.

.EXAMPLE
  $env:SUPERTUX_OHOS_KEY_PWD = '...'
  .\build-supertux-hap.ps1
  .\build-supertux-hap.ps1 -SkipDataZip -SkipInstall
  .\build-supertux-hap.ps1 -IncludeMusic -LogSeconds 30
#>
[CmdletBinding()]
param(
    [string]$CLT = $(if ($env:OHOS_CLT) { $env:OHOS_CLT } else { 'E:\harmony_os\command-line-tools' }),
    [string]$Project = (Join-Path (Split-Path -Parent $PSScriptRoot) 'app\supertux-ohos'),
    [string]$Build = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\supertux'),
    [string]$Prefix = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ohos-prefix'),
    [string]$DataDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party\SuperTux\data'),
    [string]$SigningDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'signing'),
    [string]$Cert,
    [string]$Profile,
    [string]$Keystore,
    [string]$KeyAlias = 'supertux',
    [string]$KeyPwd = $env:SUPERTUX_OHOS_KEY_PWD,
    [string]$BundleName = 'com.example.supertux2',
    [string]$Ability = 'EntryAbility',
    [int]$LogSeconds = 20,
    [switch]$IncludeMusic,
    [switch]$SkipPackage,
    [switch]$SkipInstall,
    [switch]$SkipDataZip
)

$ErrorActionPreference = 'Continue'

$NATIVE = Join-Path $CLT 'sdk\default\openharmony\native'
$CMAKE = Join-Path $NATIVE 'build-tools\cmake\bin\cmake.exe'
$READELF = Join-Path $NATIVE 'llvm\bin\llvm-readelf.exe'
$HVIGOR = Join-Path $CLT 'bin\hvigorw.bat'
$HDC = Join-Path $CLT 'sdk\default\openharmony\toolchains\hdc.exe'
$JAR = Join-Path $CLT 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$JAVA = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { 'java' }

if (-not $Cert)     { $Cert     = Join-Path $SigningDir 'debug.cer' }
if (-not $Profile)  { $Profile  = Join-Path $SigningDir 'debug.p7b' }
if (-not $Keystore) { $Keystore = Join-Path $SigningDir 'debug.p12' }

$LibOut = Join-Path $Project 'entry\libs\arm64-v8a'
$RawOut = Join-Path $Project 'entry\src\main\resources\rawfile'
$OutDir = Join-Path $Project 'entry\build\default\outputs\default'

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Fail($m) { Write-Host "FAILED: $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------ 1. libs
Step '1. collect shared libraries needed by libmain.so'

$libmain = Join-Path $Build 'libmain.so'
if (-not (Test-Path $libmain)) { Fail "libmain.so not found at $libmain -- run scripts/build-supertux-ohos.ps1 first" }
Write-Host ("libmain.so: {0:N2} MB" -f ((Get-Item $libmain).Length / 1MB))

$searchDirs = @(
    (Join-Path $Prefix 'lib'),
    $Build,
    (Join-Path $Build 'external\simplesquirrel'),
    (Join-Path $NATIVE 'llvm\lib\aarch64-linux-ohos')
)

function Get-Needed([string]$file) {
    & $READELF -d $file 2>$null | Select-String -Pattern 'NEEDED' | ForEach-Object {
        if ($_.Line -match '\[(.+?)\]') { $Matches[1] }
    }
}

New-Item -ItemType Directory -Force -Path $LibOut | Out-Null
Get-ChildItem $LibOut -Filter '*.so*' -ErrorAction SilentlyContinue | Remove-Item -Force

$seen = @{}
$queue = New-Object System.Collections.Queue
$queue.Enqueue($libmain)
while ($queue.Count -gt 0) {
    $cur = $queue.Dequeue()
    foreach ($dep in Get-Needed $cur) {
        if ($seen.ContainsKey($dep)) { continue }
        $seen[$dep] = $true

        # Libraries HarmonyOS provides at runtime.
        if ($dep -match '^lib(c|m|dl|z|unwind|EGL|GLESv3|GLESv2|native_window|hilog|ace|deviceinfo|rawfile|native_image|native_buffer|native_vsync|pixelmap|image|ohaudio|OpenSLES|bundle|ability|ipc|utils|hidumper|hitrace|ffrt|crypto|ssl|xml2|sqlite|webview|display_manager|pasteboard|udmf|ohcamera|ohimage|image_receiver|ohbattery|ohcommonevent|ability_runtime|net|huks|ace_napi|ace_ndk)') {
            continue
        }

        $found = $null
        foreach ($d in $searchDirs) {
            foreach ($cand in @($dep, ($dep -replace '\.so\..*$', '.so'))) {
                $p = Join-Path $d $cand
                if (Test-Path $p) { $found = $p; break }
            }
            if ($found) { break }
        }

        if ($found) {
            Copy-Item $found (Join-Path $LibOut $dep) -Force
            Write-Host ("  + {0}  <- {1}" -f $dep, $found)
            if ($dep -match '^(.*\.so)\.') {
                $plain = $Matches[1]
                if ($plain -eq 'libSDL3.so') {
                    # keep the unversioned name only; see the header comment.
                    Copy-Item $found (Join-Path $LibOut $plain) -Force
                    Remove-Item (Join-Path $LibOut $dep) -Force -ErrorAction SilentlyContinue
                    Write-Host ("  = {0} kept, {1} dropped (ArkTS loads libSDL3.so by name)" -f $plain, $dep)
                } else {
                    Copy-Item $found (Join-Path $LibOut $plain) -Force
                    Write-Host ("  + {0}  (unversioned alias)" -f $plain)
                }
            }
            $queue.Enqueue($found)
        } else {
            Write-Host ("  ? {0}  (not found locally -- assuming the system provides it)" -f $dep) -ForegroundColor Yellow
        }
    }
}
Copy-Item $libmain (Join-Path $LibOut 'libmain.so') -Force
Write-Host '  + libmain.so (SuperTux)'

$libcxx = Join-Path $NATIVE 'llvm\lib\aarch64-linux-ohos\libc++_shared.so'
if ((Test-Path $libcxx) -and -not (Test-Path (Join-Path $LibOut 'libc++_shared.so'))) {
    Copy-Item $libcxx (Join-Path $LibOut 'libc++_shared.so') -Force
    Write-Host '  + libc++_shared.so'
}

# --------------------------------------------------------------- 2. data.zip
Step '2. build resources/rawfile/data.zip'
New-Item -ItemType Directory -Force -Path $RawOut | Out-Null
$zip = Join-Path $RawOut 'data.zip'

if ($SkipDataZip -and (Test-Path $zip)) {
    Write-Host ("data.zip already present: {0:N1} MB (skipped)" -f ((Get-Item $zip).Length / 1MB))
} else {
    if (-not (Test-Path $DataDir)) { Fail "no SuperTux data at $DataDir -- run scripts/fetch-sources.ps1 first" }

    $stage = Join-Path (Split-Path $Prefix -Parent) 'data-stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    Get-ChildItem $DataDir -Force | Where-Object { $IncludeMusic -or $_.Name -ne 'music' } | ForEach-Object {
        Copy-Item $_.FullName $stage -Recurse -Force
    }
    Write-Host ("staged data: {0:N1} MB" -f ((Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))

    if (Test-Path $zip) { Remove-Item $zip -Force }
    Push-Location $stage
    try { & $CMAKE -E tar cfv $zip --format=zip . 2>&1 | Select-Object -Last 1 | Write-Host }
    finally { Pop-Location }
    Write-Host ("data.zip: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))
}

# ------------------------------------------------------------------- 3. hap
if (-not $SkipPackage) {
    Step '3. hvigorw assembleHap'
    $env:DEVECO_SDK_HOME = Join-Path $CLT 'sdk'
    Push-Location $Project
    try {
        & $HVIGOR --no-daemon assembleHap 2>&1 |
            Select-String -Pattern 'ERROR|BUILD SUCCESSFUL|BUILD FAILED|WARN: No signingConfig' | Select-Object -Last 10 | Write-Host
    } finally { Pop-Location }
}
Get-ChildItem $OutDir -Filter '*.hap' -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host

# ------------------------------------------------------------------ 3b. sign
$unsigned = Join-Path $OutDir 'entry-default-unsigned.hap'
$signed = Join-Path $OutDir 'entry-default-signed.hap'
if (Test-Path $unsigned) {
    Step '3b. sign with hap-sign-tool'
    foreach ($p in @($Cert, $Profile, $Keystore)) {
        if (-not (Test-Path $p)) {
            Fail @"
missing signing material: $p

Put your own AppGallery Connect debug certificate, profile and keystore in $SigningDir
(or pass -Cert/-Profile/-Keystore), and provide the keystore password with -KeyPwd or the
SUPERTUX_OHOS_KEY_PWD environment variable. See docs/signing-howto.md.
"@
        }
    }
    if (-not $KeyPwd) { Fail 'no keystore password: pass -KeyPwd or set SUPERTUX_OHOS_KEY_PWD' }

    & $JAVA -jar $JAR sign-app `
        -keyAlias $KeyAlias -keyPwd $KeyPwd -signAlg SHA256withECDSA -mode localSign `
        -appCertFile $Cert -profileFile $Profile `
        -inFile $unsigned -outFile $signed `
        -keystoreFile $Keystore -keystorePwd $KeyPwd `
        -compatibleVersion 26 -signCode 1 2>&1 | Select-Object -Last 4 | Write-Host

    if (Test-Path $signed) { Write-Host ("signed HAP: {0:N1} MB" -f ((Get-Item $signed).Length / 1MB)) }
}

# ------------------------------------------------------- 4. install and run
if (-not $SkipInstall) {
    Step '4. install + launch + logs'
    $hap = if (Test-Path $signed) { $signed } else { $unsigned }
    if (-not (Test-Path $hap)) { Fail 'no HAP produced' }

    & $HDC install -r $hap 2>&1 | Write-Host
    & $HDC shell 'hilog -r' | Out-Null
    & $HDC shell "aa start -a $Ability -b $BundleName" 2>&1 | Write-Host
    Start-Sleep -Seconds $LogSeconds

    $logFile = Join-Path $SigningDir 'hilog-supertux.txt'
    New-Item -ItemType Directory -Force -Path $SigningDir | Out-Null
    & $HDC shell 'hilog -x -e "supertux|SuperTux|SDL" -v time' 2>&1 | Set-Content -Encoding UTF8 $logFile
    Write-Host "`n--- hilog (filtered, tail) ---"
    Get-Content $logFile | Select-Object -Last 40

    Step '5. screenshot'
    $remote = '/data/local/tmp/supertux.jpeg'
    & $HDC shell "snapshot_display -f $remote" 2>&1 | Select-Object -Last 1 | Write-Host
    $shot = Join-Path $SigningDir 'supertux-screen.jpeg'
    & $HDC file recv $remote $shot 2>&1 | Select-Object -Last 1 | Write-Host
    if (Test-Path $shot) { Write-Host ("screenshot: {0} ({1:N0} bytes)" -f $shot, (Get-Item $shot).Length) }
}
