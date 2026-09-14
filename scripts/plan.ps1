<#
.SYNOPSIS
    Decides WHAT to build and in WHICH ORDER from deps.json (the dependency graph)
    and the repository's git state, and assigns build numbers.

    A node is rebuilt when:
      - its own version in deps.json changed, or files under deps/<name>/ changed
        (between -BaseRef and -HeadRef), or it is listed in -Changed, or -All;
      - something that goes into every package changed (scripts/common.ps1,
        scripts/build.ps1, docker/): then everything -- unless the head commit
        message scopes it with "[deps: a,b]" (only those nodes, plus their
        dependents as usual), "[deps: none]" (the shared change rebuilds nothing
        by itself) or "[deps: all]". Changes to scripts/plan.ps1, the workflows
        and docs never trigger rebuilds: they do not alter package contents;
      - it has never been released for its current version (no matching tag);
      - any node it depends on (transitively) is rebuilt.

    Build numbers come from tags, never from the manifest: for <name> at version
    <ver>, the next build is max(N over tags '<name>-v<ver>_N') + 1, starting at 1.
    A legacy tag '<name>-v<ver>' (no suffix) counts as build 0.

    Output: a JSON plan (-OutFile) and, with -GitHubOutput, `affected` (JSON
    array) and `plan` (compact JSON) appended to $GITHUB_OUTPUT:

      { "repository": "...", "affected": [...], "order": [...],
        "nodes": { "<name>": { "version", "build", "tag", "pkg", "affected",
                               "deps": { "<dep>": { "tag", "pkg", "source": "run"|"release", "base" } } } } }

    "source": "run" means the dependency is built earlier in the same CI run and
    handed over as a workflow artifact; "release" means fetch it from the GitHub
    Release `base`.
#>
[CmdletBinding(PositionalBinding = $false)]   # named parameters only: an array splat must fail loudly, not misbind
param(
    [string]$BaseRef,                 # git ref/sha to diff from (push: github.event.before)
    [string]$HeadRef = 'HEAD',        # git ref/sha to diff to
    [string[]]$Changed = @(),         # explicit list of changed nodes (workflow_dispatch / testing)
    [switch]$All,                     # rebuild everything
    [string[]]$ExistingTags,          # override the tag list (testing); default: `git tag -l`
    [string]$Repository,              # owner/repo for release URLs; default: GITHUB_REPOSITORY or deps.json
    [string]$OutFile,                 # write the plan JSON here
    [switch]$GitHubOutput             # append affected/plan to $env:GITHUB_OUTPUT
)

. (Join-Path $PSScriptRoot 'common.ps1')
$RepoRoot = Get-RepoRoot
$manifest = Get-Manifest

# Accept "a,b,c" as well as separate arguments (powershell -File passes one string).
$Changed = @($Changed | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })
if ($null -ne $ExistingTags) { $ExistingTags = @($ExistingTags | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ }) }
if (-not $Repository) { $Repository = $env:GITHUB_REPOSITORY }
if (-not $Repository) { $Repository = $manifest.repository }

$names = @($manifest.deps.PSObject.Properties.Name)

# --- graph: validate + topological order (Kahn) --------------------------------
$indeg = @{}; $dependents = @{}
foreach ($n in $names) { $indeg[$n] = 0; $dependents[$n] = @() }
foreach ($n in $names) {
    foreach ($d in @($manifest.deps.$n.deps)) {
        if ($d -notin $names) { throw "deps.json: '$n' depends on unknown node '$d'." }
        $indeg[$n]++
        $dependents[$d] += $n
    }
}
$queue = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($n in $names) { if ($indeg[$n] -eq 0) { $queue.Enqueue($n) } }
$order = @()
while ($queue.Count -gt 0) {
    $n = $queue.Dequeue(); $order += $n
    foreach ($m in $dependents[$n]) { $indeg[$m]--; if ($indeg[$m] -eq 0) { $queue.Enqueue($m) } }
}
if ($order.Count -ne $names.Count) { throw "deps.json has a dependency cycle." }

# --- what changed ---------------------------------------------------------------
$changedSet = New-Object 'System.Collections.Generic.HashSet[string]'
$everything = [bool]$All
foreach ($c in $Changed) { if ($c -notin $names) { throw "-Changed: unknown node '$c'." }; [void]$changedSet.Add($c) }

function Test-GitCommit([string]$Ref) {
    if (-not $Ref -or $Ref -match '^0+$') { return $false }
    & git -C $RepoRoot cat-file -e "$Ref^{commit}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

if ($BaseRef -and -not $everything) {
    if (-not (Test-GitCommit $BaseRef)) {
        Write-Host "plan: base ref '$BaseRef' is not a known commit (first push?) -> rebuilding everything"
        $everything = $true
    } else {
        $files = @(& git -C $RepoRoot diff --name-only $BaseRef $HeadRef)
        if ($LASTEXITCODE -ne 0) { throw "git diff $BaseRef $HeadRef failed." }
        $sharedChanged = @()
        foreach ($f in $files) {
            $f = $f -replace '\\', '/'
            if ($f -match '^deps/([^/]+)/') {
                if ($Matches[1] -in $names) { [void]$changedSet.Add($Matches[1]) }
            } elseif ($f -eq 'deps.json') {
                $oldText = & git -C $RepoRoot show "${BaseRef}:deps.json" 2>$null
                if ($LASTEXITCODE -ne 0) { $everything = $true; continue }
                $old = ($oldText -join "`n") | ConvertFrom-Json
                foreach ($n in $names) {
                    $op = $old.deps.PSObject.Properties[$n]
                    if (-not $op) { [void]$changedSet.Add($n); continue }                   # new node
                    if ([string]$op.Value.version -ne [string]$manifest.deps.$n.version) { [void]$changedSet.Add($n) }
                    if ([string]$op.Value.source  -ne [string]$manifest.deps.$n.source)  { [void]$changedSet.Add($n) }
                    if ((@($op.Value.deps) -join ',') -ne (@($manifest.deps.$n.deps) -join ',')) { [void]$changedSet.Add($n) }
                }
            } elseif ($f -match '^(scripts/common\.ps1|scripts/build\.ps1|docker/)') {
                # Goes into every package: rebuild everything unless the commit scopes it.
                $sharedChanged += $f
            }
            # scripts/plan.ps1, .github/workflows/, README etc.: no effect on package contents.
        }
        Write-Host ("plan: {0} changed file(s) between {1} and {2}" -f $files.Count, $BaseRef, $HeadRef)

        if ($sharedChanged.Count -gt 0) {
            # "[deps: a,b]" / "[deps: none]" / "[deps: all]" in the head commit message
            # scopes the effect of a shared-file change (e.g. a helper added for one node).
            $msg = (& git -C $RepoRoot log -1 --format=%B $HeadRef 2>$null) -join "`n"
            $scope = $null
            if ($msg -match '\[deps:\s*([^\]]*)\]') { $scope = $Matches[1].Trim() }
            if ($null -eq $scope -or $scope -eq 'all') {
                Write-Host ("plan: shared file(s) changed ({0}) -> rebuilding everything (scope with '[deps: a,b]' or '[deps: none]' in the commit message)" -f ($sharedChanged -join ', '))
                $everything = $true
            } elseif ($scope -eq 'none') {
                Write-Host ("plan: shared file(s) changed ({0}) but commit says [deps: none] -> no rebuild for that" -f ($sharedChanged -join ', '))
            } else {
                $scoped = @($scope -split '\s*,\s*' | Where-Object { $_ })
                foreach ($c in $scoped) { if ($c -notin $names) { throw "[deps: ...] in the commit message names unknown node '$c'." } ; [void]$changedSet.Add($c) }
                Write-Host ("plan: shared file(s) changed ({0}), commit scopes it to [{1}]" -f ($sharedChanged -join ', '), ($scoped -join ', '))
            }
        }
    }
}
if ($everything) { foreach ($n in $names) { [void]$changedSet.Add($n) } }

# --- existing releases (tags) ----------------------------------------------------
if ($null -eq $ExistingTags) { $ExistingTags = @(Get-ReleaseTags) }

# --- resolve every node in topological order -------------------------------------
$nodes = [ordered]@{}
$affected = @()
foreach ($n in $order) {
    $ver = [string]$manifest.deps.$n.version
    $latest = Find-LatestPackage $n $ver $ExistingTags
    $isChanged = $changedSet.Contains($n) -or ($null -eq $latest)   # never released for this version -> must build
    $isAffected = $isChanged
    foreach ($d in @($manifest.deps.$n.deps)) { if ($nodes[$d].affected) { $isAffected = $true } }

    if ($isAffected) {
        $build = if ($latest) { $latest.build + 1 } else { 1 }
        $tag = "$n-v${ver}_$build"
        $pkg = "$n-${ver}_$build"
        $affected += $n
    } else {
        $build = $latest.build
        $tag = $latest.tag
        $pkg = $latest.pkg
    }

    $depInfo = [ordered]@{}
    foreach ($d in @($manifest.deps.$n.deps)) {
        $dn = $nodes[$d]
        $depInfo[$d] = [ordered]@{
            tag    = $dn.tag
            pkg    = $dn.pkg
            source = if ($dn.affected) { 'run' } else { 'release' }
            base   = if ($dn.affected) { $null } else { Get-ReleaseBaseUrl $Repository $dn.tag }
        }
    }
    $nodes[$n] = [ordered]@{
        version  = $ver
        build    = $build
        tag      = $tag
        pkg      = $pkg
        affected = [bool]$isAffected
        deps     = $depInfo
    }
}

$plan = [ordered]@{
    repository = $Repository
    affected   = @($affected)
    order      = @($order)
    nodes      = $nodes
}
# -InputObject, not the pipeline: piping an array unrolls it, so an empty
# `affected` would serialize to nothing and a single node to a bare string.
$json          = ConvertTo-Json -InputObject $plan -Depth 10
$compact       = ConvertTo-Json -InputObject $plan -Depth 10 -Compress
$affectedJson  = ConvertTo-Json -InputObject @($affected) -Compress

Write-Host "plan: affected = [$($affected -join ', ')]"
foreach ($n in $order) {
    $x = $nodes[$n]
    $what = if ($x.affected) { 'BUILD ' } else { 'reuse ' }
    $deps = @($x.deps.Keys | ForEach-Object { "{0}={1}({2})" -f $_, $x.deps[$_].pkg, $x.deps[$_].source }) -join ' '
    Write-Host ("  {0}{1,-14} {2,-24} {3}" -f $what, $n, $x.tag, $deps)
}

if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $json + "`n", (New-Object System.Text.UTF8Encoding($false))) }
if ($GitHubOutput -and $env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("affected=" + $affectedJson)
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("plan=" + $compact)
}
