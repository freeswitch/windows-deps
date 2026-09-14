<#
.SYNOPSIS
    Builds ONE dependency: resolves its version, build number and the packages of
    the dependencies it needs, then runs deps/<name>/build.ps1.

    Two modes:

      CI (with a plan from scripts/plan.ps1):
        scripts\build.ps1 -Dep openssl -Plan plan.json -LocalPackages pkgs
      Dependencies marked "run" in the plan are taken from <LocalPackages>\<dep>
      (or <LocalPackages>\pkg-<dep>, the layout actions/download-artifact
      produces); the others from their GitHub Release.

      Local (no plan):
        scripts\build.ps1 -Dep openssl
      Version from deps.json, BUILD_NUMBER from the environment (default 0),
      dependency packages from <DEP>_PKG_BASE / <DEP>_PKG in the environment or,
      failing that, from deps.lock.

    Everything else (CONFIGS, PLATFORMS, OUT_DIR, BUILD_ROOT and the per-dependency
    knobs) is plain environment, see README.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Dep,
    [string]$Plan,
    [string]$LocalPackages
)

. (Join-Path $PSScriptRoot 'common.ps1')

$manifest = Get-Manifest
if (-not $manifest.deps.PSObject.Properties[$Dep]) { throw "deps.json has no entry '$Dep'. Known: $($manifest.deps.PSObject.Properties.Name -join ', ')" }
$node    = $manifest.deps.$Dep
$envName = ConvertTo-EnvName $Dep
$repoRoot = Get-RepoRoot

function Set-Env([string]$Name, $Value) { [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'Process') }

if ($Plan) {
    if (-not (Test-Path $Plan)) { throw "Plan file '$Plan' not found." }
    $p = Get-Content -Raw $Plan | ConvertFrom-Json
    $pn = $p.nodes.PSObject.Properties[$Dep]
    if (-not $pn) { throw "Plan has no node '$Dep'." }
    $pn = $pn.Value
    Set-Env "${envName}_VERSION" $pn.version
    Set-Env 'BUILD_NUMBER' $pn.build
    Set-Env 'PKG_NAME' $pn.pkg
    foreach ($dp in $pn.deps.PSObject.Properties) {
        $d = $dp.Name; $info = $dp.Value; $e = ConvertTo-EnvName $d
        if ($info.source -eq 'run') {
            if (-not $LocalPackages) { throw "Plan says '$d' is built in this run; pass -LocalPackages <dir> holding its artifact." }
            $base = $null
            foreach ($cand in @((Join-Path $LocalPackages $d), (Join-Path $LocalPackages "pkg-$d"))) { if (Test-Path $cand) { $base = $cand; break } }
            if (-not $base) { throw "Package directory for '$d' not found under '$LocalPackages' (expected '$d' or 'pkg-$d')." }
        } else {
            $base = $info.base
        }
        Set-Env "${e}_PKG_BASE" $base
        Set-Env "${e}_PKG"      $info.pkg
        Set-Env "${e}_PKG_TAG"  $info.tag
    }
} else {
    # Local mode: fill in whatever the environment does not already say.
    if (-not (Get-EnvValue "${envName}_VERSION")) { Set-Env "${envName}_VERSION" $node.version }
    if (-not (Get-EnvValue 'BUILD_NUMBER')) { Set-Env 'BUILD_NUMBER' '0' }
    $lock = $null
    $lockFile = Join-Path $repoRoot 'deps.lock'
    if (Test-Path $lockFile) { $lock = Get-Content -Raw $lockFile | ConvertFrom-Json }
    foreach ($d in @($node.deps)) {
        $e = ConvertTo-EnvName $d
        if ((Get-EnvValue "${e}_PKG_BASE") -and (Get-EnvValue "${e}_PKG")) { continue }
        $entry = if ($lock) { $lock.PSObject.Properties[$d] } else { $null }
        if (-not $entry) { throw "Cannot resolve dependency '$d' of '$Dep': set ${e}_PKG_BASE and ${e}_PKG, or add '$d' to deps.lock." }
        $entry = $entry.Value
        Set-Env "${e}_PKG_BASE" $entry.base
        Set-Env "${e}_PKG"      $entry.pkg
        Set-Env "${e}_PKG_TAG"  $entry.tag
    }
}

$settings = Get-BuildSettings $Dep
Write-Host "==================================================================="
Write-Host " windows-deps: building $($settings.Pkg)  (mode: $(if ($Plan) { 'plan' } else { 'local' }))"
foreach ($d in @($node.deps)) {
    $e = ConvertTo-EnvName $d
    Write-Host ("   dep {0,-12} {1}  <- {2}" -f $d, (Get-EnvValue "${e}_PKG"), (Get-EnvValue "${e}_PKG_BASE"))
}
Write-Host "==================================================================="

& (Join-Path $repoRoot "deps\$Dep\build.ps1")
