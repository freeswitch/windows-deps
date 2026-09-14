<#
.SYNOPSIS
    OpenSSL: builds STATIC libcrypto.lib + libssl.lib with the Visual C++
    toolchain and packages headers + binaries in the layout FreeSWITCH's
    w32\openssl.props consumes (the layout of the old openssl-packaging project).

    zlib comes from this repository's zlib package (dependency edge in deps.json):
      ZLIB_MODE=zlib-dynamic (default)  compile against the zlib headers; libcrypto
                                        loads zlib.dll (zlibd.dll in Debug) at run
                                        time -- the DLL w32\zlib.props already
                                        deploys -- so consumers link nothing extra.
      ZLIB_MODE=zlib                    link zlibstatic[d].lib into openssl.exe;
                                        consumers of libcrypto.lib must link it too.
      ZLIB_MODE=none                    no zlib.

    Package <pkg> = openssl-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/openssl/*.h              (architecture-independent)
                                              <pkg>/include_x64/openssl/configuration.h  (per-arch; include_x86 if Win32 is built)
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/{libcrypto.lib, libssl.lib, ossl_static.pdb, openssl.exe}
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): OPENSSL_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, OPENSSL_URL, OPENSSLDIR, EXTRA_CONFIG,
    ZLIB_MODE, and ZLIB_PKG_BASE / ZLIB_PKG for the zlib package (scripts\build.ps1
    sets those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'openssl'
$tc = Initialize-Toolchain

# OpenSSL's Configure needs a native Windows Perl (Strawberry Perl). Git for
# Windows ships an MSYS perl that is often first on PATH on developer machines;
# it lacks modules and speaks POSIX paths, and Configure dies with confusing
# "Can't locate ..." errors. Fail early with a clear message instead.
$perlCmd = Get-Command perl.exe -ErrorAction SilentlyContinue
if (-not $perlCmd) { throw "perl.exe not found on PATH. Install Strawberry Perl (https://strawberryperl.com); the Docker image and deps/openssl/prereqs.ps1 do this via Chocolatey." }
$perlOs = (& $perlCmd.Source -e 'print $^O' 2>$null)
if ($perlOs -ne 'MSWin32') { throw "perl at '$($perlCmd.Source)' reports OS '$perlOs'; OpenSSL's Configure needs a native Windows Perl (Strawberry Perl), not the MSYS/Cygwin one from Git for Windows." }
if (-not (Get-Command nasm.exe -ErrorAction SilentlyContinue)) { throw "nasm.exe not found on PATH. Install NASM (choco install nasm) or pass EXTRA_CONFIG with no-asm." }

$openssldir = [string](Get-EnvValue 'OPENSSLDIR' 'C:/Program Files/FreeSWITCH/ssl')
# EXTRA_CONFIG: unset -> default; explicitly '' -> nothing (so the default can be dropped).
$extraConfig = [Environment]::GetEnvironmentVariable('EXTRA_CONFIG')
if ($null -eq $extraConfig) { $extraConfig = 'no-autoload-config' }
$zlibMode = [string](Get-EnvValue 'ZLIB_MODE' 'zlib-dynamic')
if ($zlibMode -notin @('zlib-dynamic', 'zlib', 'none')) { throw "Unsupported ZLIB_MODE '$zlibMode' (use 'zlib-dynamic', 'zlib' or 'none')." }

function Get-BuildArg([string]$plat) {
    switch ($plat) { 'x64' { 'VC-WIN64A' } 'Win32' { 'VC-WIN32' } default { throw "Unsupported platform '$plat' (use 'x64' or 'Win32')." } }
}
function Get-ArchIncludeDir([string]$plat) {
    # The original packaging splits the per-architecture configuration.h into
    # include_x64 / include_x86 (Win32 == 32-bit == x86).
    switch ($plat) { 'x64' { 'include_x64' } 'Win32' { 'include_x86' } default { throw "Unsupported platform '$plat'." } }
}

Write-Host "==================================================================="
Write-Host " OpenSSL         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " Configure opts  : no-shared no-tests $extraConfig"
Write-Host " zlib            : $zlibMode$(if ($zlibMode -ne 'none') { " (package $(Get-EnvValue 'ZLIB_PKG' '?') from $(Get-EnvValue 'ZLIB_PKG_BASE' '?'))" })"
Write-Host " openssldir      : $openssldir"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tarball = Join-Path $s.BuildRoot "openssl-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

# zlib headers (platform/config independent) from the zlib package.
$depCache = Join-Path $s.BuildRoot 'deps'
$zlibInclude = $null
if ($zlibMode -ne 'none') {
    $zlibInclude = Join-Path (Get-DepPackageRoot -Dep zlib -Kind headers -CacheDir $depCache) 'include'
    if (-not (Test-Path (Join-Path $zlibInclude 'zlib.h'))) { throw "zlib.h not found in the zlib headers package (looked in '$zlibInclude')." }
}

$incSnapshots = @{}

foreach ($plat in $s.Platforms) {
    $buildArg = Get-BuildArg $plat
    $vcArch   = Get-VcArch   $plat
    foreach ($config in $s.Configs) {
        $buildType = $config.ToLower()    # release | debug
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building OpenSSL $($s.Version)  [$plat / $config]  ($buildArg, --$buildType)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "openssl-$($s.Version)"
        $prefix = Join-Path $work 'OpenSSL'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        # OpenSSL's Configure builds IN-SOURCE, so each platform/config needs its
        # own clean copy of the tree.
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # zlib Configure options. Debug uses the "d" postfixed files of the zlib
        # package (zlibd.dll / zlibstaticd.lib), which is what FreeSWITCH's
        # zlib.props deploys for Debug builds.
        $zlibOpts = ''
        if ($zlibMode -ne 'none') {
            $zd = if ($config -eq 'Debug') { 'd' } else { '' }
            $zlibOpts = "$zlibMode --with-zlib-include=`"$(ConvertTo-ForwardSlashes $zlibInclude)`""
            if ($zlibMode -eq 'zlib-dynamic') {
                # On Windows --with-zlib-lib is the base name of the DLL libcrypto
                # DSO_load()s at run time (OpenSSL appends ".dll"; default ZLIB1).
                $zlibOpts += " --with-zlib-lib=zlib$zd"
            } else {
                $zroot = Get-DepPackageRoot -Dep zlib -Kind binaries -CacheDir $depCache -Platform $plat -Config $config
                $zlibStatic = Join-Path $zroot "binaries\$plat\$config\lib\zlibstatic$zd.lib"
                if (-not (Test-Path $zlibStatic)) { throw "zlibstatic$zd.lib not found in the zlib binaries package for $plat/$config (looked for '$zlibStatic')." }
                # On Windows --with-zlib-lib is the .lib to link (goes into ex_libs).
                $zlibOpts += " --with-zlib-lib=`"$(ConvertTo-ForwardSlashes $zlibStatic)`""
            }
        }

        # One cmd session: enter the VC env, then Configure -> nmake -> nmake
        # install_sw. `no-shared` => static libs; `no-tests` skips the test suite
        # (apps + openssl.exe still build).
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cd /d "$srcDir" || exit /b 1
perl Configure $buildArg no-shared no-tests $extraConfig $zlibOpts --$buildType --prefix="$prefix" --openssldir="$openssldir" || exit /b 1
nmake || exit /b 1
nmake install_sw || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "OpenSSL build [$plat/$config]"

        # --- verify zlib ended up enabled as configured -------------------------
        if ($zlibMode -ne 'none') {
            $confH = Join-Path $prefix 'include\openssl\configuration.h'
            if ((Test-Path $confH) -and (Select-String -Path $confH -Pattern '^\s*#\s*define\s+OPENSSL_NO_ZLIB\b' -Quiet)) {
                throw "OPENSSL_NO_ZLIB is defined in $confH although ZLIB_MODE=$zlibMode -- Configure did not enable zlib."
            }
        }

        # --- collect binaries -> staged tree ----------------------------------
        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null

        $libDir = Join-Path $prefix 'lib'
        foreach ($f in 'libssl.lib', 'libcrypto.lib') {
            $p = Join-Path $libDir $f
            if (-not (Test-Path $p)) { throw "Expected '$p' was not produced by the build." }
            Copy-Item $p -Destination $binDst
        }
        # ossl_static.pdb: install_sw normally drops it in lib\; fall back to the build tree.
        $pdb = Join-Path $libDir 'ossl_static.pdb'
        if (-not (Test-Path $pdb)) { $pdb = Join-Path $srcDir 'ossl_static.pdb' }
        if (Test-Path $pdb) { Copy-Item $pdb -Destination (Join-Path $binDst 'ossl_static.pdb') }
        else { Write-Host "  NOTE: ossl_static.pdb not found (lib\ or build tree); continuing without it." -ForegroundColor Yellow }

        $exe = Join-Path $prefix 'bin\openssl.exe'
        if (-not (Test-Path $exe)) { $exe = Join-Path $srcDir 'apps\openssl.exe' }
        if (-not (Test-Path $exe)) { throw "Expected openssl.exe was not produced by the build." }
        Copy-Item $exe -Destination (Join-Path $binDst 'openssl.exe')

        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        # Snapshot installed headers once per platform (identical across configs).
        if (-not $incSnapshots.ContainsKey($plat)) {
            $snap = Join-Path $stage "inc-$plat"
            New-Item -ItemType Directory -Force -Path $snap | Out-Null
            Copy-Item -Recurse -Force (Join-Path $prefix 'include\openssl') (Join-Path $snap 'openssl')
            $incSnapshots[$plat] = Join-Path $snap 'openssl'
        }
    }
}

# --- assemble headers zip ----------------------------------------------------
# Architecture-independent headers in include/, the per-architecture
# configuration.h in include_x64 / include_x86. Arch-specific headers are found by
# content-comparing the per-platform snapshots (configuration.h is seeded so it
# lands in include_<arch> even for a single-platform build).
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."

$hdrRoot   = Join-Path $stage "hdr\$($s.Pkg)"
$incCommon = Join-Path $hdrRoot 'include\openssl'
New-Item -ItemType Directory -Force -Path $incCommon | Out-Null

$builtPlats = @($incSnapshots.Keys)
$refPlat = if ($incSnapshots.ContainsKey('x64')) { 'x64' } else { $builtPlats[0] }
$refDir  = $incSnapshots[$refPlat]
function Get-Hash($p) { (Get-FileHash $p -Algorithm SHA256).Hash }

$archSpecific = New-Object 'System.Collections.Generic.HashSet[string]'
[void]$archSpecific.Add('configuration.h')
foreach ($file in (Get-ChildItem $refDir -File)) {
    $hashes = foreach ($plat in $builtPlats) {
        $pp = Join-Path $incSnapshots[$plat] $file.Name
        if (Test-Path $pp) { Get-Hash $pp } else { 'MISSING' }
    }
    if (($hashes | Select-Object -Unique).Count -gt 1) { [void]$archSpecific.Add($file.Name) }
}
foreach ($plat in $builtPlats) {
    foreach ($file in (Get-ChildItem $incSnapshots[$plat] -File)) {
        if (-not (Test-Path (Join-Path $refDir $file.Name))) { [void]$archSpecific.Add($file.Name) }
    }
}
if (-not (Test-Path (Join-Path $refDir 'configuration.h'))) {
    Write-Host "  WARNING: configuration.h not found in installed headers; header layout may be off." -ForegroundColor Yellow
}
Write-Host ("  Architecture-specific headers: {0}" -f (($archSpecific | Sort-Object) -join ', '))

Get-ChildItem $refDir -File | Where-Object { -not $archSpecific.Contains($_.Name) } |
    ForEach-Object { Copy-Item $_.FullName -Destination $incCommon }
Get-ChildItem $refDir -Directory | ForEach-Object { Copy-Item -Recurse -Force $_.FullName $incCommon }
foreach ($plat in $builtPlats) {
    $dst = Join-Path $hdrRoot ("{0}\openssl" -f (Get-ArchIncludeDir $plat))
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($name in $archSpecific) {
        $pp = Join-Path $incSnapshots[$plat] $name
        if (Test-Path $pp) { Copy-Item $pp -Destination $dst }
    }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("configure: no-shared no-tests $extraConfig", "zlib-mode: $zlibMode", "openssldir: $openssldir", "toolchain: $($tc.VsInstall)")
Write-PackageSummary $s
