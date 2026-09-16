<#
.SYNOPSIS
    Shared helpers for deps/<name>/build.ps1. Dot-source it at the top of a
    dependency build script:

        . (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

    Runs under Windows PowerShell 5.1 (the Docker image) and pwsh 7 (GitHub
    runners); keep everything here compatible with both.

    Conventions shared by every dependency:
      - inputs come from environment variables (set by scripts/build.ps1 from the
        plan or from release tags, by `docker run -e`, or by the GitHub Actions
        env block);
      - a package is named <dep>-<version>_<build>, e.g. zlib-1.3.2_1: that is the
        zip prefix AND the top-level folder inside every zip;
      - a dependency package is addressed by <DEP>_PKG_BASE (URL or local
        directory) plus <DEP>_PKG (package name).
#>

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot   # scripts\ -> repository root

function Get-RepoRoot { $script:RepoRoot }

# --- manifest -----------------------------------------------------------------
function Get-Manifest {
    Get-Content -Raw (Join-Path $script:RepoRoot 'deps.json') | ConvertFrom-Json
}

function Get-ManifestNode([string]$Name) {
    $m = Get-Manifest
    $p = $m.deps.PSObject.Properties[$Name]
    if (-not $p) { throw "deps.json has no entry '$Name'." }
    $p.Value
}

# rabbitmq-c -> RABBITMQ_C (prefix of the environment variables about a dependency)
function ConvertTo-EnvName([string]$Dep) { ($Dep -replace '[^A-Za-z0-9]', '_').ToUpper() }

function Get-EnvValue([string]$Name, $Default = $null) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v -or $v -eq '') { return $Default }
    $v
}

# The knobs every dependency build shares, resolved from env + manifest.
function Get-BuildSettings([string]$Dep) {
    $node    = Get-ManifestNode $Dep
    $envName = ConvertTo-EnvName $Dep
    $version = ([string](Get-EnvValue "${envName}_VERSION" $node.version)).TrimStart('vV')
    $build   = [int](Get-EnvValue 'BUILD_NUMBER' '0')
    $pkg     = Get-EnvValue 'PKG_NAME' ("{0}-{1}_{2}" -f $Dep, $version, $build)
    # Source URL template: {version} = 7.88.1, {version_} = 7_88_1 (curl-style tags).
    $source  = Get-EnvValue "${envName}_URL" ((([string]$node.source) -replace '\{version_\}', ($version -replace '\.', '_')) -replace '\{version\}', $version)
    [pscustomobject]@{
        Dep       = $Dep
        Version   = $version
        Build     = $build
        Pkg       = $pkg
        SourceUrl = $source
        Configs   = @(([string](Get-EnvValue 'CONFIGS'   'Release Debug')) -split '\s+' | Where-Object { $_ })
        Platforms = @(([string](Get-EnvValue 'PLATFORMS' 'x64'))           -split '\s+' | Where-Object { $_ })
        OutDir    = [string](Get-EnvValue 'OUT_DIR'    (Join-Path $script:RepoRoot "artifacts\$Dep"))
        # Short build path: OpenSSL's tree and CMake's NMake files break past MAX_PATH.
        BuildRoot = [string](Get-EnvValue 'BUILD_ROOT' "C:\wd\$Dep")
    }
}

# --- releases (tags) ----------------------------------------------------------
# Package releases are tags '<name>-v<version>_<build>'; a legacy '<name>-v<version>'
# counts as build 0. These helpers are the single place that knows that scheme.
function Get-ReleaseTags {
    if (-not (Test-Path (Join-Path $script:RepoRoot '.git'))) { return @() }
    $tags = @(& git -C $script:RepoRoot tag -l 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    $tags
}

# Latest released package of <Name> at <Version> among $Tags, or $null.
# Returns @{ build; tag; pkg }.
function Find-LatestPackage([string]$Name, [string]$Version, [string[]]$Tags) {
    $best = $null
    foreach ($t in $Tags) {
        if ($t -match '^(?<name>.+)-v(?<ver>[0-9][^_]*)(?:_(?<build>[0-9]+))?$') {
            if ($Matches.name -ne $Name -or $Matches.ver -ne $Version) { continue }
            $b = if ($Matches.build) { [int]$Matches.build } else { 0 }
            if ($null -eq $best -or $best.build -lt $b) {
                $pkg = if ($Matches.build) { "$Name-${Version}_$b" } else { "$Name-$Version" }
                $best = @{ build = $b; tag = $t; pkg = $pkg }
            }
        }
    }
    $best
}

function Get-ReleaseBaseUrl([string]$Repository, [string]$Tag) { "https://github.com/$Repository/releases/download/$Tag" }

# --- toolchain ----------------------------------------------------------------
# Locates Visual Studio (vcvarsall.bat via vswhere), prepends the non-VS tool
# dirs to PATH defensively (Docker inherits an incomplete PATH otherwise) and
# picks Windows' own bsdtar. Returns an object with VsInstall, VcVarsAll, Tar.
function Initialize-Toolchain {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at '$vswhere' (Visual Studio 2017+ with the C++ toolset is required)." }
    $vsInstall = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1
    if (-not $vsInstall) { throw "No Visual Studio install with the C++ toolset (VC.Tools.x86.x64) was found." }
    $vcvarsall = Join-Path $vsInstall 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path $vcvarsall)) { throw "vcvarsall.bat not found at '$vcvarsall'." }

    # Order matters: the standalone CMake first (Strawberry Perl ships an older
    # cmake in its c\bin, which is deliberately NOT added -- only perl\bin is
    # needed for OpenSSL's Configure).
    $toolDirs = @(
        'C:\Program Files\CMake\bin',
        (Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'),
        'C:\Strawberry\perl\bin',
        'C:\Program Files\NASM',
        'C:\ProgramData\chocolatey\bin'
    ) | Where-Object { Test-Path $_ }
    $env:Path = (($toolDirs + ($env:Path -split ';')) | Where-Object { $_ } | Select-Object -Unique) -join ';'

    # A GNU tar from Git for Windows earlier on PATH would misread "C:\..." as a
    # remote host ("Cannot connect to C: resolve failed"); use System32\tar.exe.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tar)) { $tar = 'tar.exe' }

    [pscustomobject]@{ VsInstall = $vsInstall; VcVarsAll = $vcvarsall; Tar = $tar }
}

function Get-VcArch([string]$Platform) {
    switch ($Platform) {
        'x64'   { 'x64' }
        'Win32' { 'x86' }
        default { throw "Unsupported platform '$Platform' (use 'x64' or 'Win32')." }
    }
}

function ConvertTo-ForwardSlashes([string]$Path) { $Path -replace '\\', '/' }

# --- files --------------------------------------------------------------------
function Reset-Directory([string]$Path) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

# $Source is an http(s) URL or a local file path (dependency packages built
# earlier in the same CI run are handed over as files).
function Get-RemoteFile([string]$Source, [string]$OutFile) {
    if ($Source -match '^https?://') {
        Write-Host "Downloading $Source ..."
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # Windows PowerShell renders a progress bar for every buffer it writes, which
        # costs more than the transfer itself on a large tarball (OpenCV's is ~90 MB).
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Source -OutFile $OutFile -UseBasicParsing } finally { $ProgressPreference = $prev }
    } else {
        Write-Host "Copying $Source ..."
        Copy-Item -LiteralPath $Source -Destination $OutFile -Force
    }
    if (-not (Test-Path $OutFile)) { throw "Failed to fetch '$Source'." }
    Write-Host ("  -> {0:N0} bytes" -f (Get-Item $OutFile).Length)
}

function Expand-Tarball([string]$Tarball, [string]$Destination, $Toolchain) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & $Toolchain.Tar -xf $Tarball -C $Destination
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract '$Tarball' into '$Destination'." }
}

# Runs a cmd batch (typically: call vcvarsall, then the real build commands) with
# stdout+stderr merged into $LogFile BY CMD ITSELF, then echoes the log. We do not
# use PowerShell's `2>&1` on the native call: under Windows PowerShell 5.1 that
# turns every native stderr line into a terminating NativeCommandError when
# $ErrorActionPreference='Stop'. The batch is written with CRLF: cmd misparses
# LF-only batch files.
function Invoke-BuildBatch([string]$Script, [string]$BatchFile, [string]$LogFile, [string]$Label) {
    $text = (($Script -replace "`r?`n", "`r`n").TrimEnd()) + "`r`n"
    [System.IO.File]::WriteAllText($BatchFile, $text, [System.Text.Encoding]::ASCII)
    & cmd.exe /c "`"$BatchFile`" > `"$LogFile`" 2>&1"
    $code = $LASTEXITCODE
    if (Test-Path $LogFile) { Get-Content $LogFile }   # surface build output in the CI/Docker console
    if ($code -ne 0) {
        Write-Host ""
        Write-Host "===== $Label FAILED (exit $code) - error lines from $LogFile =====" -ForegroundColor Red
        Select-String -Path $LogFile -Pattern '(: |\b)(error|fatal error)\b|CMake Error|LNK[12][0-9]{3}' -CaseSensitive:$false |
            Select-Object -Last 60 | ForEach-Object { Write-Host $_.Line }
        throw "$Label failed with exit code $code. Full log preserved at: $LogFile"
    }
}

# --- dependency packages ------------------------------------------------------
# Fetches (once) and extracts one package of a dependency and returns the path
# of its top-level folder (<cache>\<zip name>\<pkg>). Kind: 'headers' or
# 'binaries' (the latter needs Platform + Config).
function Get-DepPackageRoot([string]$Dep, [string]$Kind, [string]$CacheDir, [string]$Platform = '', [string]$Config = '') {
    $envName = ConvertTo-EnvName $Dep
    $base = Get-EnvValue "${envName}_PKG_BASE"
    $pkg  = Get-EnvValue "${envName}_PKG"
    if (-not $base -or -not $pkg) {
        throw "Dependency '$Dep' is not resolved: set ${envName}_PKG_BASE and ${envName}_PKG (scripts\build.ps1 does this from the plan or from release tags)."
    }
    $zipName = switch ($Kind) {
        'headers'  { "$pkg-headers.zip" }
        'binaries' { "$pkg-binaries-$($Platform.ToLower())-$($Config.ToLower()).zip" }
        default    { throw "Unknown package kind '$Kind'." }
    }
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $zipPath = Join-Path $CacheDir $zipName
    if (-not (Test-Path $zipPath)) {
        $src = if ($base -match '^https?://') { "$($base.TrimEnd('/'))/$zipName" } else { Join-Path $base $zipName }
        Get-RemoteFile $src $zipPath
    }
    $dest = Join-Path $CacheDir ([System.IO.Path]::GetFileNameWithoutExtension($zipName))
    $root = Join-Path $dest $pkg
    if (-not (Test-Path $root)) { Expand-Archive -Path $zipPath -DestinationPath $dest -Force }
    if (-not (Test-Path $root)) { throw "'$zipName' does not contain the expected top-level folder '$pkg'." }
    $root
}

# Assembles a conventional OpenSSL install root (include\openssl\*.h merged from
# include/ and include_<arch>/, plus lib\libcrypto.lib, libssl.lib) for one
# platform/config out of this repository's openssl package, so CMake's
# FindOpenSSL can simply be pointed at it with OPENSSL_ROOT_DIR. Returns the root.
function Get-OpenSSLRootForCMake([string]$Platform, [string]$Config, [string]$CacheDir) {
    $hdr = Get-DepPackageRoot -Dep openssl -Kind headers  -CacheDir $CacheDir
    $bin = Get-DepPackageRoot -Dep openssl -Kind binaries -CacheDir $CacheDir -Platform $Platform -Config $Config
    $root = Join-Path $CacheDir "openssl-root-$Platform-$Config"
    if (-not (Test-Path (Join-Path $root 'lib\libcrypto.lib'))) {
        $inc = Join-Path $root 'include\openssl'
        $lib = Join-Path $root 'lib'
        New-Item -ItemType Directory -Force -Path $inc, $lib | Out-Null
        Copy-Item -Path (Join-Path $hdr 'include\openssl\*') -Destination $inc -Recurse -Force
        $archDir = if ($Platform -eq 'Win32') { 'include_x86' } else { "include_$Platform" }
        $archInc = Join-Path $hdr "$archDir\openssl"
        if (Test-Path $archInc) { Copy-Item -Path (Join-Path $archInc '*') -Destination $inc -Recurse -Force }
        $binDir = Join-Path $bin "binaries\$Platform\$Config"
        Get-ChildItem $binDir -File | Where-Object { $_.Extension -in @('.lib', '.pdb') } | Copy-Item -Destination $lib -Force
        foreach ($must in 'include\openssl\ssl.h', 'include\openssl\configuration.h', 'lib\libcrypto.lib', 'lib\libssl.lib') {
            if (-not (Test-Path (Join-Path $root $must))) { throw "OpenSSL package is missing '$must' (assembling $root)." }
        }
    }
    $root
}

# --- packaging ----------------------------------------------------------------
function New-PackageZip([string]$SourceDir, [string]$ZipPath) {
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    Compress-Archive -Path $SourceDir -DestinationPath $ZipPath
    Write-Host "  -> $ZipPath"
}

function Write-Checksums([string]$OutDir) {
    $sums = Join-Path $OutDir 'SHA256SUMS.txt'
    Get-ChildItem -Path $OutDir -Filter '*.zip' | ForEach-Object {
        "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
    } | Set-Content -Encoding ASCII $sums
}

# Bill of materials: which source and which dependency packages went into this
# package. Published next to the zips so a release is traceable.
function Write-Bom($Settings, [string[]]$Extra = @()) {
    $node  = Get-ManifestNode $Settings.Dep
    $lines = @(
        "package: $($Settings.Pkg)",
        "version: $($Settings.Version)",
        "build: $($Settings.Build)",
        "source: $($Settings.SourceUrl)"
    )
    foreach ($d in @($node.deps)) {
        $e = ConvertTo-EnvName $d
        $lines += ("dep: {0} = {1} (tag {2})" -f $d, (Get-EnvValue "${e}_PKG" '?'), (Get-EnvValue "${e}_PKG_TAG" '?'))
    }
    $lines += $Extra
    Set-Content -Path (Join-Path $Settings.OutDir "$($Settings.Pkg)-BOM.txt") -Value $lines -Encoding ASCII
}

function Write-PackageSummary($Settings) {
    Write-Host "==================================================================="
    Write-Host " Done. $($Settings.Pkg) packaged in $($Settings.OutDir) :"
    Get-ChildItem -Path $Settings.OutDir -Filter '*.zip' | ForEach-Object {
        Write-Host ("   {0,14:N0}  {1}" -f $_.Length, $_.Name)
    }
    Write-Host "==================================================================="
}
