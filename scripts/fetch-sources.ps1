<#
.SYNOPSIS
  Clone the third-party sources this port builds against, at the pinned revisions in versions.txt,
  then apply the patches in patches/.

.DESCRIPTION
  Everything lands under <repo>/third_party/ (git-ignored). Nothing third-party is stored in this
  repository, so this script is the first step of any build.

  SuperTux needs its submodules (external/tinygettext, external/sexp-cpp, external/simplesquirrel)
  and simplesquirrel has a nested libs/squirrel submodule, hence --recursive.

.EXAMPLE
  .\fetch-sources.ps1
  .\fetch-sources.ps1 -Proxy http://127.0.0.1:7890      # if GitHub needs a proxy
  .\fetch-sources.ps1 -Force                            # re-clone everything
  .\fetch-sources.ps1 -SkipPatches                      # pristine upstream trees
#>
[CmdletBinding()]
param(
    [string]$ThirdParty = (Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party'),
    [string]$Proxy = '',
    [switch]$SkipPatches,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$versions = Join-Path $PSScriptRoot 'versions.txt'
if (-not (Test-Path $versions)) { throw "missing $versions" }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    if ($Proxy) {
        & git -c "http.proxy=$Proxy" -c "https.proxy=$Proxy" @GitArgs
    } else {
        & git @GitArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $ThirdParty | Out-Null
Write-Host "third_party: $ThirdParty"

Get-Content $versions | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object {
    $fields = $_ -split '\|'
    $name = $fields[0].Trim()
    $url = $fields[1].Trim()
    $rev = $fields[2].Trim()
    $dir = Join-Path $ThirdParty $name

    Write-Host "`n=== $name @ $($rev.Substring(0, [Math]::Min(12, $rev.Length))) ===" -ForegroundColor Cyan

    if ($Force -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force }

    if (Test-Path (Join-Path $dir '.git')) {
        Write-Host '  already cloned, checking out the pinned revision'
        Invoke-Git -C $dir fetch --depth 1 origin $rev
        Invoke-Git -C $dir checkout -q --detach FETCH_HEAD
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $dir -Parent) | Out-Null
        Invoke-Git init -q $dir
        Invoke-Git -C $dir remote add origin $url
        try {
            # GitHub serves fetches by SHA, which keeps this shallow and quick.
            Invoke-Git -C $dir fetch --depth 1 origin $rev
            Invoke-Git -C $dir checkout -q --detach FETCH_HEAD
        } catch {
            Write-Host '  fetch by revision failed, falling back to a blobless clone' -ForegroundColor Yellow
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-Git clone --filter=blob:none --no-checkout $url $dir
            Invoke-Git -C $dir checkout -q $rev
        }
    }

    if (Test-Path (Join-Path $dir '.gitmodules')) {
        Write-Host '  updating submodules (recursive)'
        Invoke-Git -C $dir submodule update --init --recursive --depth 1
    }

    $head = (& git -C $dir rev-parse --short HEAD)
    Write-Host "  at $head"
}

if ($SkipPatches) {
    Write-Host "`n-SkipPatches: leaving the trees pristine (the port will not build like this)" -ForegroundColor Yellow
    exit 0
}

Write-Host "`n=== applying patches ===" -ForegroundColor Cyan
$patches = @(
    @{ Target = 'SDL';          Patch = 'sdl-ohos.patch' },
    @{ Target = 'SuperTux';     Patch = 'supertux-ohos.patch' },
    @{ Target = 'deps/openal';  Patch = 'openal-ohos-sdl3.patch' }
)
foreach ($p in $patches) {
    $target = Join-Path $ThirdParty $p.Target
    $patch = Join-Path $RepoRoot ("patches\" + $p.Patch)
    if (-not (Test-Path $patch)) { Write-Host "  $($p.Patch): not found, skipping"; continue }

    & git -C $target apply --check --whitespace=nowarn $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git -C $target apply --whitespace=nowarn $patch
        Write-Host "  $($p.Patch) -> $($p.Target)"
    } else {
        Write-Host "  $($p.Patch): does not apply cleanly (already applied, or the revision moved)" -ForegroundColor Yellow
    }
}

Write-Host "`nDone. Next: scripts/build-ohos-deps.ps1" -ForegroundColor Green
