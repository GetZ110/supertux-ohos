<#
.SYNOPSIS
  Cross-build every third-party library SuperTux needs on HarmonyOS (API 26, arm64-v8a) into one
  prefix: build/ohos-prefix.

.DESCRIPTION
  Run scripts/fetch-sources.ps1 first: this script only builds, it does not download.

  Already built outside this script (they are SDL's own CMake projects and are built by the two
  scripts after this one, against the same prefix):
    * SDL3       -> build/sdl
    * SDL3_image -> build/sdl-image
    * SDL3_ttf   -> build/sdl-ttf

  Notes that cost real debugging time:
    * zlib comes from the OHOS sysroot, nothing to build.
    * OHOS cannot link executables, so tests/samples are disabled everywhere.
    * The OHOS toolchain pins CMAKE_FIND_ROOT_PATH to the SDK sysroot, so a prefix outside it is
      invisible to find_library() unless it is appended to CMAKE_FIND_ROOT_PATH.
    * OpenAL Soft: master needs C++20 std::lexicographical_compare_three_way (absent from OHOS's
      libc++), so 1.23.1 is used; and its AL_API export macro comes from a check_c_source_compiles()
      probe that fails when cross-compiling, leaving the library with ZERO exported symbols unless
      HAVE_GCC_DEFAULT_VISIBILITY is forced on.

.EXAMPLE
  .\build-ohos-deps.ps1
  .\build-ohos-deps.ps1 -Only libpng,freetype
  .\build-ohos-deps.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [string]$CLT = $(if ($env:OHOS_CLT) { $env:OHOS_CLT } else { 'E:\harmony_os\command-line-tools' }),
    [string]$ThirdParty = (Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party'),
    [string]$Prefix = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ohos-prefix'),
    [int]$Jobs = 8,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Continue'

$NATIVE = Join-Path $CLT 'sdk\default\openharmony\native'
$CMAKE = Join-Path $NATIVE 'build-tools\cmake\bin\cmake.exe'
$NINJA = Join-Path $NATIVE 'build-tools\cmake\bin\ninja.exe'
$TOOLCHAIN = Join-Path $NATIVE 'build\cmake\ohos.toolchain.cmake'

foreach ($tool in @($CMAKE, $NINJA, $TOOLCHAIN)) {
    if (-not (Test-Path $tool)) { throw "not found: $tool (pass -CLT <path to Huawei command line tools>)" }
}

# OpenAL's output backend on OHOS is SDL3's audio subsystem (SDL3 -> OHAudio), so OpenAL needs
# SDL3's headers and libSDL3.so in the prefix at configure time. build-sdl-ohos.ps1 normally runs
# after this script, so make sure the SDL3 core is there first (SDL3_image/SDL3_ttf need libpng and
# freetype from this script, so the two steps cannot simply be swapped).
function Get-OpenAlSdl3Args {
    $hdr = Join-Path $Prefix 'include\SDL3\SDL.h'
    $lib = Join-Path $Prefix 'lib\libSDL3.so'
    if ((Test-Path $hdr) -and (Test-Path $lib)) {
        return @('-DALSOFT_BACKEND_SDL3=ON','-DALSOFT_REQUIRE_SDL3=ON',
                 "-DSDL3_INCLUDE_DIR=$Prefix/include", "-DSDL3_LIBRARY=$lib")
    }
    return @()
}

$openalArgs = @('-DLIBTYPE=SHARED','-DALSOFT_EXAMPLES=OFF','-DALSOFT_UTILS=OFF','-DALSOFT_TESTS=OFF',
                '-DHAVE_GCC_DEFAULT_VISIBILITY=1',
                '-DALSOFT_BACKEND_ALSA=OFF','-DALSOFT_BACKEND_PULSEAUDIO=OFF','-DALSOFT_BACKEND_OSS=OFF',
                '-DALSOFT_BACKEND_SNDIO=OFF','-DALSOFT_BACKEND_JACK=OFF','-DALSOFT_BACKEND_PIPEWIRE=OFF',
                '-DALSOFT_BACKEND_WAVE=ON','-DALSOFT_BACKEND_NULL=ON') + (Get-OpenAlSdl3Args)

# name, extra cmake args. Sources live in third_party/deps/<name>.
$deps = @(
    @{ name='libpng';   args=@('-DPNG_SHARED=ON','-DPNG_STATIC=OFF','-DPNG_TESTS=OFF','-DPNG_TOOLS=OFF','-DPNG_EXECUTABLES=OFF') },
    @{ name='physfs';   args=@('-DPHYSFS_BUILD_SHARED=ON','-DPHYSFS_BUILD_STATIC=OFF','-DPHYSFS_BUILD_TEST=OFF','-DPHYSFS_BUILD_DOCS=OFF') },
    @{ name='fmt';      args=@('-DFMT_TEST=OFF','-DFMT_DOC=OFF','-DBUILD_SHARED_LIBS=ON') },
    @{ name='glm';      args=@('-DGLM_BUILD_TESTS=OFF','-DBUILD_SHARED_LIBS=OFF') },
    @{ name='freetype'; args=@('-DFT_DISABLE_HARFBUZZ=ON','-DFT_DISABLE_BROTLI=ON','-DFT_DISABLE_BZIP2=ON','-DBUILD_SHARED_LIBS=ON') },
    @{ name='ogg';      args=@('-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTING=OFF') },
    @{ name='vorbis';   args=@('-DBUILD_SHARED_LIBS=ON','-DBUILD_TESTING=OFF') },
    @{ name='openal';   args=$openalArgs }
)

if ($ListOnly) { $deps | ForEach-Object { Write-Host $_.name }; return }

New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

# Build the SDL3 core first when OpenAL is being built and SDL3 is not in the prefix yet.
$wantOpenal = (-not $Only) -or ($Only -contains 'openal')
if ($wantOpenal -and -not (Test-Path (Join-Path $Prefix 'include\SDL3\SDL.h'))) {
    Write-Host "`n================ SDL3 (prerequisite of OpenAL) ================" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'build-sdl-ohos.ps1') -SkipImage -SkipTtf -Prefix $Prefix
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'WARNING: SDL3 prerequisite build failed; OpenAL will have no output backend' -ForegroundColor Yellow
    }
}

$results = @()
foreach ($d in $deps) {
    if ($Only -and ($Only -notcontains $d.name)) { continue }

    $src = Join-Path $ThirdParty ("deps\" + $d.name)
    $bld = Join-Path (Split-Path $Prefix -Parent) ("deps\" + $d.name)
    Write-Host "`n================ $($d.name) ================" -ForegroundColor Cyan

    if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) {
        Write-Host "SKIP $($d.name): no sources at $src -- run scripts/fetch-sources.ps1 first" -ForegroundColor Yellow
        $results += [pscustomobject]@{ dep = $d.name; status = 'sources-missing' }
        continue
    }

    $cfg = @('-G','Ninja', '-S',$src, '-B',$bld,
             "-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN",
             '-DCMAKE_BUILD_TYPE=Release',
             '-DOHOS_COMPATIBLE_SDK_VERSION=26',
             "-DCMAKE_INSTALL_PREFIX=$Prefix",
             "-DCMAKE_PREFIX_PATH=$Prefix",
             # The OHOS toolchain pins CMAKE_FIND_ROOT_PATH to the SDK native dir; a custom prefix
             # outside the sysroot is invisible to find_library()/find_path() unless added here.
             "-DCMAKE_FIND_ROOT_PATH=$NATIVE;$Prefix",
             "-DCMAKE_MAKE_PROGRAM=$NINJA") + $d.args

    & $CMAKE @cfg 2>&1 | Select-String -Pattern 'CMake Error|Configuring done' | Select-Object -First 6 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CONFIGURE FAILED: $($d.name)" -ForegroundColor Red
        $results += [pscustomobject]@{ dep = $d.name; status = 'configure-failed' }
        continue
    }

    & $CMAKE --build $bld -j $Jobs 2>&1 | Select-String -Pattern 'error|FAILED' | Select-Object -First 6 | Write-Host
    $buildOk = ($LASTEXITCODE -eq 0)

    & $CMAKE --install $bld 2>&1 | Select-Object -Last 1 | Write-Host
    $installOk = ($LASTEXITCODE -eq 0)

    $status = if ($buildOk -and $installOk) { 'ok' } elseif ($buildOk) { 'built-no-install' } else { 'build-failed' }
    Write-Host "$($d.name): $status" -ForegroundColor $(if ($status -eq 'ok') { 'Green' } else { 'Yellow' })
    $results += [pscustomobject]@{ dep = $d.name; status = $status }
}

Write-Host "`n================ summary ================" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "prefix: $Prefix"
Get-ChildItem (Join-Path $Prefix 'lib') -ErrorAction SilentlyContinue -Filter '*.so' |
    Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
