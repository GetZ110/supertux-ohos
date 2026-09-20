<#
.SYNOPSIS
  Configure and build SuperTux for HarmonyOS (API 26, arm64-v8a) as libmain.so.

.DESCRIPTION
  Run scripts/fetch-sources.ps1, build-ohos-deps.ps1 and build-sdl-ohos.ps1 first.

  Why this produces a shared library rather than an executable:
    SDL3 on HarmonyOS cannot use an ANSI main(). SDL gains control of the app through ArkTS +
    XComponent and then loads libmain.so and calls SDL_AppInit/SDL_AppIterate/SDL_AppEvent/
    SDL_AppQuit from it (src/ohos/main_ohos.cpp in the patched SuperTux tree). src/main.cpp is
    therefore excluded, and the target is named "main".

  Notes:
    * ENABLE_NETWORKING=OFF drops the libcurl dependency; the patched file_system.cpp no longer
      includes <curl/curl.h> unconditionally.
    * ENABLE_OPENGL=OFF makes SuperTux use its SDL_Renderer video path, which is what SDL3's
      HarmonyOS backend implements well (GLES2).
    * physfs 3.3 exports PhysFS::PhysFS-shared but SuperTux's AddPackage.cmake wants
      PhysFS::PhysFS, so an alias is appended to the installed config, and the package is looked up
      with find_package instead of pkg-config (there is no pkg-config on this machine).

.EXAMPLE
  .\build-supertux-ohos.ps1
  .\build-supertux-ohos.ps1 -Reconfigure
#>
[CmdletBinding()]
param(
    [string]$CLT = $(if ($env:OHOS_CLT) { $env:OHOS_CLT } else { 'E:\harmony_os\command-line-tools' }),
    [string]$ThirdParty = (Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party'),
    [string]$Build = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\supertux'),
    [string]$Prefix = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\ohos-prefix'),
    [int]$Jobs = 8,
    [switch]$Reconfigure
)

$ErrorActionPreference = 'Continue'

$NATIVE = Join-Path $CLT 'sdk\default\openharmony\native'
$CMAKE = Join-Path $NATIVE 'build-tools\cmake\bin\cmake.exe'
$NINJA = Join-Path $NATIVE 'build-tools\cmake\bin\ninja.exe'
$TOOLCHAIN = Join-Path $NATIVE 'build\cmake\ohos.toolchain.cmake'

foreach ($tool in @($CMAKE, $NINJA, $TOOLCHAIN)) {
    if (-not (Test-Path $tool)) { throw "not found: $tool (pass -CLT <path to Huawei command line tools>)" }
}

$Src = Join-Path $ThirdParty 'SuperTux'
if (-not (Test-Path (Join-Path $Src 'CMakeLists.txt'))) { throw "no SuperTux sources at $Src -- run scripts/fetch-sources.ps1 first" }
if (-not (Test-Path (Join-Path $Src 'src\ohos\main_ohos.cpp'))) {
    throw "SuperTux does not look patched (src/ohos/main_ohos.cpp missing) -- run scripts/fetch-sources.ps1 without -SkipPatches"
}

Write-Host "=== 1. submodules (external/tinygettext, sexp-cpp, simplesquirrel + nested squirrel) ===" -ForegroundColor Cyan
& git -C $Src submodule update --init --recursive --depth 1 external/tinygettext external/sexp-cpp external/simplesquirrel 2>&1 |
    Select-Object -Last 4 | Write-Host
foreach ($m in 'tinygettext','sexp-cpp','simplesquirrel') {
    Write-Host ("  {0,-16} {1}" -f $m, (Test-Path (Join-Path $Src "external\$m\CMakeLists.txt")))
}

Write-Host "`n=== 2. physfs target alias ===" -ForegroundColor Cyan
$physfsCfg = Join-Path $Prefix 'lib\cmake\PhysFS\PhysFSConfig.cmake'
if (Test-Path $physfsCfg) {
    if ((Get-Content $physfsCfg -Raw) -notmatch 'PhysFS::PhysFS ALIAS') {
@'

# --- local HarmonyOS port shim -------------------------------------------------
# physfs 3.3 exports only PhysFS::PhysFS-shared / PhysFS::PhysFS-static, but SuperTux's
# mk/cmake/SuperTux/AddPackage.cmake expects the target PhysFS::PhysFS.
if(TARGET PhysFS::PhysFS-shared AND NOT TARGET PhysFS::PhysFS)
  add_library(PhysFS::PhysFS ALIAS PhysFS::PhysFS-shared)
endif()
# ------------------------------------------------------------------------------
'@ | Add-Content -Path $physfsCfg -Encoding ASCII
        Write-Host '  alias appended'
    } else {
        Write-Host '  alias already present'
    }
} else {
    Write-Host "  WARNING: $physfsCfg not found -- build-ohos-deps.ps1 first?" -ForegroundColor Yellow
}

Write-Host "`n=== 3. configure SuperTux for OHOS ===" -ForegroundColor Cyan
if ($Reconfigure -and (Test-Path $Build)) { Remove-Item $Build -Recurse -Force }

& $CMAKE -G Ninja -S $Src -B $Build `
    "-DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN" `
    -DCMAKE_BUILD_TYPE=Release `
    -DOHOS_COMPATIBLE_SDK_VERSION=26 `
    "-DCMAKE_PREFIX_PATH=$Prefix" `
    "-DCMAKE_FIND_ROOT_PATH=$NATIVE;$Prefix" `
    "-DCMAKE_INSTALL_PREFIX=$Prefix" `
    "-DCMAKE_MAKE_PROGRAM=$NINJA" `
    -DENABLE_NETWORKING=OFF `
    -DENABLE_OPENGL=OFF `
    -DBUILD_TESTING=OFF `
    -DSUPERTUX_PCH=OFF `
    -DSUPERTUX_CCACHE=OFF `
    -DPhysFS_PREFER_FIND_PACKAGE=ON `
    2>&1 | Select-Object -Last 25 | Write-Host

if ($LASTEXITCODE -ne 0) { throw 'SuperTux configure failed' }

Write-Host "`n=== 4. build ===" -ForegroundColor Cyan
& $CMAKE --build $Build -j $Jobs 2>&1 | Select-String -Pattern 'error:|FAILED|Linking' | Select-Object -First 25 | Write-Host
Write-Host "build exit code: $LASTEXITCODE"

Get-ChildItem $Build -Filter 'libmain.so' -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
