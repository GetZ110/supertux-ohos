<#
.SYNOPSIS
  Cross-build SDL3 and the two SDL3 satellite libraries SuperTux needs (SDL3_image, SDL3_ttf) for
  HarmonyOS, installing all three into build/ohos-prefix.

.DESCRIPTION
  Run scripts/fetch-sources.ps1 first: the trees under third_party/ must exist and already have
  patches/sdl-ohos.patch applied.

  Two things to know:
    * OHOS cannot link executables ("undefined symbol: main" under -Wl,--no-undefined), so the
      examples/tests are off and only the library targets are built. SDL_image's samples fail to
      link for exactly that reason.
    * SDL3 must be installed *before* SDL3_image/SDL3_ttf, because those two find it through
      SDL3_DIR in the prefix.

.EXAMPLE
  .\build-sdl-ohos.ps1
  .\build-sdl-ohos.ps1 -SkipImage -SkipTtf
#>
[CmdletBinding()]
param(
    [string]$CLT = $(if ($env:OHOS_CLT) { $env:OHOS_CLT } else { 'E:\harmony_os\command-line-tools' }),
    [string]$ThirdParty = (Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party'),
    [string]$BuildRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build'),
    [string]$Prefix = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ohos-prefix'),
    [int]$Jobs = 8,
    [switch]$SkipImage,
    [switch]$SkipTtf
)

$ErrorActionPreference = 'Continue'

$NATIVE = Join-Path $CLT 'sdk\default\openharmony\native'
$CMAKE = Join-Path $NATIVE 'build-tools\cmake\bin\cmake.exe'
$NINJA = Join-Path $NATIVE 'build-tools\cmake\bin\ninja.exe'
$TOOLCHAIN = Join-Path $NATIVE 'build\cmake\ohos.toolchain.cmake'

foreach ($tool in @($CMAKE, $NINJA, $TOOLCHAIN)) {
    if (-not (Test-Path $tool)) { throw "not found: $tool (pass -CLT <path to Huawei command line tools>)" }
}
if (-not (Test-Path (Join-Path $ThirdParty 'SDL\CMakeLists.txt'))) {
    throw "no SDL sources at $ThirdParty\SDL -- run scripts/fetch-sources.ps1 first"
}

New-Item -ItemType Directory -Force -Path $Prefix, $BuildRoot | Out-Null

function Configure-And-Build {
    param([string]$Name, [string]$Source, [string]$Build, [string[]]$Extra, [string[]]$Targets = @())

    Write-Host "`n================ $Name ================" -ForegroundColor Cyan
    if (-not (Test-Path (Join-Path $Source 'CMakeLists.txt'))) {
        Write-Host "SKIP: no sources at $Source" -ForegroundColor Yellow
        return $false
    }

    $cfg = @('-G','Ninja', '-S',$Source, '-B',$Build,
             "-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN",
             '-DCMAKE_BUILD_TYPE=Release',
             '-DOHOS_COMPATIBLE_SDK_VERSION=26',
             "-DCMAKE_INSTALL_PREFIX=$Prefix",
             "-DCMAKE_PREFIX_PATH=$Prefix",
             "-DCMAKE_FIND_ROOT_PATH=$NATIVE;$Prefix",
             "-DCMAKE_MAKE_PROGRAM=$NINJA") + $Extra

    & $CMAKE @cfg 2>&1 | Select-String -Pattern 'CMake Error|Configuring done' | Select-Object -First 6 | Write-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "CONFIGURE FAILED: $Name" -ForegroundColor Red; return $false }

    if ($Targets.Count -gt 0) {
        & $CMAKE --build $Build --target @Targets -j $Jobs 2>&1 | Select-String -Pattern 'error|FAILED|Linking' | Select-Object -First 8 | Write-Host
    } else {
        & $CMAKE --build $Build -j $Jobs 2>&1 | Select-String -Pattern 'error|FAILED|Linking' | Select-Object -First 8 | Write-Host
    }
    if ($LASTEXITCODE -ne 0) { Write-Host "BUILD FAILED: $Name" -ForegroundColor Red; return $false }

    & $CMAKE --install $Build 2>&1 | Select-Object -Last 1 | Write-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "INSTALL FAILED: $Name" -ForegroundColor Red; return $false }

    Write-Host "$Name ok" -ForegroundColor Green
    return $true
}

# 1. SDL3 itself. -DSDL_SHARED only: one libSDL3.so, no tests/examples/install extras.
$sdlOk = Configure-And-Build -Name 'SDL3' -Source (Join-Path $ThirdParty 'SDL') -Build (Join-Path $BuildRoot 'sdl') `
    -Extra @('-DSDL_SHARED=ON','-DSDL_STATIC=OFF','-DSDL_TESTS=OFF','-DSDL_EXAMPLES=OFF')
if (-not $sdlOk) { throw 'SDL3 build failed' }

$sdl3Dir = Join-Path $Prefix 'lib\cmake\SDL3'

# 2. SDL3_image (vendored stb backends; libpng comes from the prefix).
if (-not $SkipImage) {
    Configure-And-Build -Name 'SDL3_image' -Source (Join-Path $ThirdParty 'SDL_image') -Build (Join-Path $BuildRoot 'sdl-image') `
        -Extra @('-DBUILD_SHARED_LIBS=ON','-DSDLIMAGE_TESTS=OFF',"-DSDL3_DIR=$sdl3Dir") `
        -Targets @('SDL3_image-shared') | Out-Null
}

# 3. SDL3_ttf against the system FreeType from the prefix (no FetchContent: vendoring would pull
#    FreeType/HarfBuzz/plutosvg at configure time). Without HarfBuzz there is no complex-script
#    shaping and no colour emoji -- acceptable for a first port.
if (-not $SkipTtf) {
    Configure-And-Build -Name 'SDL3_ttf' -Source (Join-Path $ThirdParty 'SDL_ttf') -Build (Join-Path $BuildRoot 'sdl-ttf') `
        -Extra @('-DBUILD_SHARED_LIBS=ON','-DSDLTTF_VENDORED=OFF','-DSDLTTF_HARFBUZZ=OFF','-DSDLTTF_PLUTOSVG=OFF',
                 '-DSDLTTF_SAMPLES=OFF','-DSDLTTF_INSTALL=ON',"-DSDL3_DIR=$sdl3Dir") `
        -Targets @('SDL3_ttf-shared') | Out-Null
}

Write-Host "`nprefix contents:" -ForegroundColor Cyan
Get-ChildItem (Join-Path $Prefix 'lib') -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
