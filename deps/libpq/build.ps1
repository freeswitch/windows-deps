<#
.SYNOPSIS
    libpq: builds PostgreSQL's client library (libpq.dll + its import library)
    from the official postgresql-<version>.tar.gz with Meson + the Visual C++
    toolchain, and packages it the way FreeSWITCH's w32\libpq.props expects (the
    layout the old libpq-packaging project produced; consumers: mod_pgsql,
    mod_cdr_pg_csv and switch_pgsql in the core).

    PostgreSQL 16 dropped, and 17 removed, src\tools\msvc -- Meson is the only
    supported Windows build system now. Only the libpq target is built; the rest
    of the tree (server, psql, contrib) is never compiled.

    Package <pkg> = libpq-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYRIGHT
                                              <pkg>/include/{libpq-fe.h, libpq-events.h, postgres_ext.h,
                                                             pg_config.h, pg_config_ext.h, pg_config_manual.h, pg_config_os.h}
                                              <pkg>/include/libpq/libpq-fs.h
                                              <pkg>/include/internal/...          (libpq-int.h and what it includes)
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYRIGHT
                                              <pkg>/binaries/<Platform>/<Config>/{libpq.dll, libpq.lib}
                                                                             /libpq.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    OpenSSL comes from this repository's openssl package and is linked STATICALLY
    into libpq.dll: the DLL has no libcrypto/libssl DLL dependency and exports
    only the PQ* API (PostgreSQL links it with its own /DEF: export list), so the
    copy of OpenSSL inside is private to libpq and cannot clash with the one
    FreeSWITCH links itself. Dynamic CRT (/MD, /MDd in Debug), as FreeSWITCH uses.

    Environment (all optional): LIBPQ_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBPQ_URL, PG_PREFIX, EXTRA_MESON, and
    OPENSSL_PKG_BASE / OPENSSL_PKG for the OpenSSL package (scripts\build.ps1 sets
    those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libpq'
$tc = Initialize-Toolchain
$extraMeson = [string](Get-EnvValue 'EXTRA_MESON' '')

# --prefix only ends up in pg_config_paths.h; for libpq the one that matters is
# SYSCONFDIR = <prefix>\etc, where it looks for pg_service.conf. Keep it under
# "Program Files" so the lookup cannot be redirected by a non-admin user (the
# reason openssl is configured with a fixed --openssldir as well).
$prefix = [string](Get-EnvValue 'PG_PREFIX' 'C:/Program Files/PostgreSQL/17')

# Windows libraries OpenSSL's static libcrypto/libssl need (openssl's own LDLIBS).
# PostgreSQL only adds ws2_32 and secur32 itself.
$sslSysLibs = @('ws2_32.lib', 'gdi32.lib', 'advapi32.lib', 'crypt32.lib', 'user32.lib')

# Tools PostgreSQL's meson.build insists on -- perl, python, flex and bison are
# probed at CONFIGURE time even for a libpq-only build.
function Find-Tool([string[]]$Names, [string]$What) {
    foreach ($n in $Names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c }
    }
    throw "$What not found on PATH (looked for: $($Names -join ', ')). See docker\Dockerfile for how the build image installs it."
}

$mesonCmd  = Find-Tool @('meson.exe', 'meson.cmd', 'meson') 'meson'
$ninjaCmd  = Find-Tool @('ninja.exe', 'ninja') 'ninja'
$pythonCmd = Find-Tool @('python3.exe', 'python.exe') "python (PostgreSQL's meson.build requires it)"
$perlCmd   = Find-Tool @('perl.exe') "perl (PostgreSQL generates C sources with it)"
$flexCmd   = Find-Tool @('win_flex.exe', 'flex.exe') 'flex / win_flex'
$bisonCmd  = Find-Tool @('win_bison.exe', 'bison.exe') 'bison / win_bison'

# Same trap as OpenSSL's Configure: the perl from Git for Windows is an MSYS
# build that speaks POSIX paths and misses modules.
$perlOs = (& $perlCmd.Source -e 'print $^O') 2>$null
if ($perlOs -ne 'MSWin32') { throw "perl at '$($perlCmd.Source)' reports OS '$perlOs'; PostgreSQL needs a native Windows Perl (Strawberry Perl), not the MSYS/Cygwin one from Git for Windows." }

$mesonVersion = (& $mesonCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libpq           : PostgreSQL $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " OpenSSL         : package $(Get-EnvValue 'OPENSSL_PKG' '?') from $(Get-EnvValue 'OPENSSL_PKG_BASE' '?') (linked statically)"
Write-Host " --prefix        : $prefix"
Write-Host " Extra meson     : $extraMeson"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " meson           : $($mesonCmd.Source) ($mesonVersion)"
Write-Host " ninja           : $($ninjaCmd.Source)"
Write-Host " python          : $($pythonCmd.Source)"
Write-Host " perl            : $($perlCmd.Source)"
Write-Host " flex / bison    : $($flexCmd.Name) / $($bisonCmd.Name)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tarball = Join-Path $s.BuildRoot "postgresql-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$depCache = Join-Path $s.BuildRoot 'deps'

$headerSrc = $null   # source tree of the first build
$headerGen = $null   # its build dir (pg_config.h and friends are generated there)

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libpq (PostgreSQL $($s.Version))  [$plat / $config]  (meson + ninja)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "postgresql-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version meson declares must match the manifest.
        $mb = Get-Content (Join-Path $srcDir 'meson.build') -Raw
        if ($mb -notmatch "(?m)^\s*version:\s*'([0-9][^']*)'") { throw "No project version found in PostgreSQL's meson.build." }
        if ($Matches[1] -ne $s.Version) { throw "PostgreSQL source declares version $($Matches[1]) but deps.json says $($s.Version)." }

        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache
        $sslInc  = ConvertTo-ForwardSlashes (Join-Path $sslRoot 'include')
        $sslLib  = ConvertTo-ForwardSlashes (Join-Path $sslRoot 'lib')

        $buildType = if ($config -eq 'Debug') { 'debug' } else { 'release' }
        $vscrt     = if ($config -eq 'Debug') { 'mdd' } else { 'md' }

        # auto_features=disabled switches every optional dependency off (zlib,
        # gssapi, icu, nls, lz4, zstd, readline, libxml, tap tests, docs ...);
        # ssl and ldap are then turned back on explicitly. libpq itself does not
        # use zlib -- only the server and pg_dump do -- so this node does not
        # depend on the zlib package.
        $setupArgs = @(
            "`"$(ConvertTo-ForwardSlashes $bldDir)`"",
            "`"$(ConvertTo-ForwardSlashes $srcDir)`"",
            '--backend', 'ninja',
            '--buildtype', $buildType,
            "--prefix=`"$prefix`"",
            "-Db_vscrt=$vscrt",
            '-Dauto_features=disabled',
            '-Dssl=openssl',
            '-Dldap=enabled',
            "-Dextra_include_dirs=`"$sslInc`"",
            "-Dextra_lib_dirs=`"$sslLib`"",
            "-Dc_link_args=`"$($sslSysLibs -join ' ')`""
        )
        if ($extraMeson) { $setupArgs += $extraMeson }

        # One cmd session: enter the VC env, configure, build the shared libpq
        # only, then record what the DLL actually links against.
        $dllPath  = Join-Path $bldDir 'src\interfaces\libpq\libpq.dll'
        $dumpFile = Join-Path $work 'dumpbin.txt'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
rem Strawberry Perl ships an ancient ccache in C:\Strawberry\c\bin, which is on the
rem machine PATH; meson picks it up as a compiler launcher on its own (and old
rem ccache + MSVC /Zi is a known-bad combination). Naming the compiler explicitly
rem stops meson from auto-detecting a compiler cache at all.
set CC=cl
meson setup $($setupArgs -join ' ') || exit /b 1
meson compile -C "$bldDir" libpq:shared_library || exit /b 1
dumpbin /nologo /dependents "$dllPath" || exit /b 1
dumpbin /nologo /dependents /exports "$dllPath" > "$dumpFile" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libpq build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        $outDirBld = Join-Path $bldDir 'src\interfaces\libpq'
        foreach ($f in 'libpq.dll', 'libpq.lib') {
            if (-not (Test-Path (Join-Path $outDirBld $f))) { throw "libpq [$plat/$config] did not produce $f in '$outDirBld'." }
        }
        $dump = Get-Content $dumpFile -Raw
        foreach ($sym in 'PQconnectdb', 'PQlibVersion', 'PQinitOpenSSL') {
            if ($dump -notmatch "\b$sym\b") { throw "libpq.dll does not export $sym -- unexpected build result (see $dumpFile)." }
        }
        # OpenSSL must be *inside* the DLL: a libcrypto/libssl import would mean
        # the package needs OpenSSL DLLs next to it at run time, which the old
        # libpq packages never did.
        if ($dump -match '(?im)^\s*(libcrypto|libssl)[-0-9_]*\.dll') { throw "libpq.dll imports an OpenSSL DLL; it must link libcrypto/libssl statically (see $dumpFile)." }
        foreach ($imp in 'WS2_32.dll', 'SECUR32.dll', 'WLDAP32.dll') {
            if ($dump -notmatch "(?i)\b$([regex]::Escape($imp))\b") { throw "libpq.dll does not import $imp -- SSL/LDAP support did not get enabled (see $dumpFile)." }
        }
        # USE_OPENSSL in the generated pg_config.h is the configure-side proof.
        $pgConfig = Join-Path $bldDir 'src\include\pg_config.h'
        if (-not (Test-Path $pgConfig)) { throw "Generated pg_config.h not found at '$pgConfig'." }
        if ((Get-Content $pgConfig -Raw) -notmatch '(?m)^#define USE_OPENSSL 1') { throw "USE_OPENSSL is not set in the generated pg_config.h -- meson did not pick up the OpenSSL package." }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item (Join-Path $outDirBld 'libpq.dll') -Destination $binDst
        Copy-Item (Join-Path $outDirBld 'libpq.lib') -Destination $binDst
        Copy-Item (Join-Path $srcDir 'COPYRIGHT') -Destination $pkgRoot
        if ($config -eq 'Debug') {
            $pdb = Join-Path $outDirBld 'libpq.pdb'
            if (Test-Path $pdb) { Copy-Item $pdb -Destination $binDst }
        }
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir; $headerGen = $bldDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# Same layout as the old libpq-packaging output, plus the headers PostgreSQL 17's
# libpq-int.h pulls in that PostgreSQL 10's did not (fe-auth-sasl.h, pg_prng.h,
# fe_memutils.h, protocol.h, win32_port.h), so include\internal is self-contained.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
foreach ($d in 'libpq', 'internal', 'internal\libpq', 'internal\common', 'internal\port') {
    New-Item -ItemType Directory -Force -Path (Join-Path $incDst $d) | Out-Null
}
Copy-Item (Join-Path $headerSrc 'COPYRIGHT') -Destination $hdrRoot

# <source relative path> -> <path inside include\>
$fromSource = [ordered]@{
    'src/interfaces/libpq/libpq-fe.h'     = 'libpq-fe.h'
    'src/interfaces/libpq/libpq-events.h' = 'libpq-events.h'
    'src/include/postgres_ext.h'          = 'postgres_ext.h'
    'src/include/pg_config_manual.h'      = 'pg_config_manual.h'
    'src/include/libpq/libpq-fs.h'        = 'libpq/libpq-fs.h'
    'src/include/c.h'                     = 'internal/c.h'
    'src/include/port.h'                  = 'internal/port.h'
    'src/include/postgres_fe.h'           = 'internal/postgres_fe.h'
    'src/interfaces/libpq/libpq-int.h'    = 'internal/libpq-int.h'
    'src/interfaces/libpq/pqexpbuffer.h'  = 'internal/pqexpbuffer.h'
    'src/interfaces/libpq/fe-auth-sasl.h' = 'internal/fe-auth-sasl.h'
    'src/include/libpq/pqcomm.h'          = 'internal/libpq/pqcomm.h'
    'src/include/libpq/protocol.h'        = 'internal/libpq/protocol.h'
    'src/include/common/fe_memutils.h'    = 'internal/common/fe_memutils.h'
    'src/include/common/pg_prng.h'        = 'internal/common/pg_prng.h'
    'src/include/port/win32_port.h'       = 'internal/port/win32_port.h'
}
# Generated by meson's configure step, in the build directory.
$fromBuild = [ordered]@{
    'src/include/pg_config.h'     = 'pg_config.h'
    'src/include/pg_config_ext.h' = 'pg_config_ext.h'
    'src/include/pg_config_os.h'  = 'pg_config_os.h'
}
foreach ($kv in $fromSource.GetEnumerator()) {
    $src = Join-Path $headerSrc ($kv.Key -replace '/', '\')
    if (-not (Test-Path $src)) { throw "Header '$($kv.Key)' not found in the PostgreSQL source tree." }
    Copy-Item $src -Destination (Join-Path $incDst ($kv.Value -replace '/', '\')) -Force
}
foreach ($kv in $fromBuild.GetEnumerator()) {
    $src = Join-Path $headerGen ($kv.Key -replace '/', '\')
    if (-not (Test-Path $src)) { throw "Generated header '$($kv.Key)' not found in the build directory." }
    Copy-Item $src -Destination (Join-Path $incDst ($kv.Value -replace '/', '\')) -Force
}
foreach ($must in 'libpq-fe.h', 'pg_config.h', 'pg_config_ext.h', 'pg_config_os.h', 'libpq\libpq-fs.h', 'internal\libpq-int.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("meson: $mesonVersion", "toolchain: $($tc.VsInstall)", "prefix: $prefix",
               "features: libpq only, OpenSSL linked statically, LDAP (wldap32), no zlib/gssapi/icu/nls, /MD")
Write-PackageSummary $s
