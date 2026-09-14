<#
.SYNOPSIS
    libpng: builds the shared libpng16.dll with its import library and the static
    libpng16_static.lib with CMake + the Visual C++ toolchain, against the zlib
    package of this repository, and packages them for FreeSWITCH (FreeSwitchCore
    and mod_png, which used to build libpng in-tree as libs\win32\libpng).

    zlib: libpng links the zlib IMPORT library of the matching configuration
    (zlib.lib / zlibd.lib), so libpng16.dll loads zlib.dll (zlibd.dll in Debug) at
    run time -- the DLLs w32\zlib.props deploys. Consumers of libpng16_static.lib
    must link zlib themselves.

    Package <pkg> = libpng-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/{png.h, pngconf.h, pnglibconf.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/bin/libpng16.dll         (libpng16d.dll in Debug)
                                                                             /bin/libpng16d.pdb        (Debug only)
                                                                             /lib/libpng16.lib         (libpng16d.lib in Debug)        import library
                                                                             /lib/libpng16_static.lib  (libpng16_staticd.lib in Debug) static library
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBPNG_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBPNG_URL, EXTRA_CMAKE, and ZLIB_PKG_BASE /
    ZLIB_PKG for the zlib package (scripts\build.ps1 sets those from the plan or
    from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libpng'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)

# Output names depend on the configuration (libpng's "d" debug postfix), so only
# the two configurations FreeSWITCH builds are supported.
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

# libpng16 = "libpng" + ABI version (major+minor of 1.6.x). Derived, so a future
# 1.8.x would be checked as libpng18 rather than silently mispackaged.
$verParts = $s.Version -split '\.'
$abi = "$($verParts[0])$($verParts[1])"
$libBase = "libpng$abi"

Write-Host "==================================================================="
Write-Host " libpng          : $($s.Version) (build $($s.Build), package $($s.Pkg), ABI $libBase)"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " zlib            : package $(Get-EnvValue 'ZLIB_PKG' '?') from $(Get-EnvValue 'ZLIB_PKG_BASE' '?')"
Write-Host " Extra cmake     : $extraCMake"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " cmake           : $($cmakeCmd.Source) ($cmakeVersion)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tarball = Join-Path $s.BuildRoot "libpng-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

# zlib headers (platform/config independent) from the zlib package.
$depCache = Join-Path $s.BuildRoot 'deps'
$zlibInclude = Join-Path (Get-DepPackageRoot -Dep zlib -Kind headers -CacheDir $depCache) 'include'
if (-not (Test-Path (Join-Path $zlibInclude 'zlib.h'))) { throw "zlib.h not found in the zlib headers package (looked in '$zlibInclude')." }

$headerNames  = @('png.h', 'pngconf.h', 'pnglibconf.h')
$incSnapshots = @{}

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libpng $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "libpng-$($s.Version)"     # GitHub tag tarball expands to libpng-<ver>/
        $bldDir = Join-Path $work 'build'
        $prefix = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # zlib import library of the matching configuration: libpng16[d].dll then
        # loads zlib[d].dll at run time, the flavour zlib.props deploys per config.
        $zd = if ($config -eq 'Debug') { 'd' } else { '' }
        $zroot   = Get-DepPackageRoot -Dep zlib -Kind binaries -CacheDir $depCache -Platform $plat -Config $config
        $zlibLib = Join-Path $zroot "binaries\$plat\$config\lib\zlib$zd.lib"
        if (-not (Test-Path $zlibLib)) { throw "zlib$zd.lib not found in the zlib binaries package for $plat/$config (looked for '$zlibLib')." }

        # Our zlib package is not a standard install root, so point FindZLIB at the
        # files explicitly instead of using ZLIB_ROOT.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $prefix)`"",
            "-DZLIB_INCLUDE_DIR=`"$(ConvertTo-ForwardSlashes $zlibInclude)`"",
            "-DZLIB_LIBRARY=`"$(ConvertTo-ForwardSlashes $zlibLib)`"",
            '-DPNG_SHARED=ON',
            '-DPNG_STATIC=ON',
            '-DPNG_TESTS=OFF',
            '-DPNG_TOOLS=OFF',
            '-DPNG_FRAMEWORK=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" || exit /b 1
cmake --install "$bldDir" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libpng build [$plat/$config]"

        # --- verify the install tree ---------------------------------------------
        $dll = "bin\$libBase$zd.dll"; $imp = "lib\$libBase$zd.lib"; $sta = "lib\${libBase}_static$zd.lib"
        $missing = @(@($dll, $imp, $sta) | Where-Object { -not (Test-Path (Join-Path $prefix $_)) })
        if ($missing.Count -gt 0) {
            $have = Get-ChildItem -Recurse -File $prefix | ForEach-Object { $_.FullName.Substring($prefix.Length + 1) }
            throw "libpng [$plat/$config] did not produce: $($missing -join ', '). Installed tree contains: $($have -join ', ')."
        }
        $impText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $prefix $imp)))
        if ($impText -notmatch "(?i)$libBase$zd\.dll") { throw "$imp does not reference $libBase$zd.dll." }
        $dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $prefix $dll)))
        if ($dllText -notmatch "(?i)zlib$zd\.dll") { throw "$dll does not import zlib$zd.dll -- it was linked against the wrong zlib flavour." }
        foreach ($h in $headerNames) {
            if (-not (Test-Path (Join-Path $prefix "include\$h"))) { throw "Expected header include\$h was not installed." }
        }

        # --- stage + zip -----------------------------------------------------------
        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path (Join-Path $binDst 'bin'), (Join-Path $binDst 'lib') | Out-Null
        Get-ChildItem (Join-Path $prefix 'bin') -File -Filter '*.dll' | Copy-Item -Destination (Join-Path $binDst 'bin')
        # The PDB is not installed by libpng's CMake; take it from the build tree if present.
        $pdb = Join-Path $bldDir "$libBase$zd.pdb"
        if (Test-Path $pdb) { Copy-Item $pdb -Destination (Join-Path $binDst 'bin') }
        Get-ChildItem (Join-Path $prefix 'lib') -File -Filter "$libBase*.lib" | Copy-Item -Destination (Join-Path $binDst 'lib')
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $incSnapshots.ContainsKey($plat)) {
            $snap = Join-Path $stage "inc-$plat"
            New-Item -ItemType Directory -Force -Path $snap | Out-Null
            foreach ($h in $headerNames) { Copy-Item (Join-Path $prefix "include\$h") -Destination $snap }
            $incSnapshots[$plat] = $snap
        }
    }
}

# --- headers zip --------------------------------------------------------------------
# Single include/: pnglibconf.h is generated from the prebuilt template and does
# not depend on the target architecture. Verified rather than assumed.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$builtPlats = @($incSnapshots.Keys)
$refPlat = if ($incSnapshots.ContainsKey('x64')) { 'x64' } else { $builtPlats[0] }
foreach ($plat in $builtPlats) {
    foreach ($h in $headerNames) {
        $a = (Get-FileHash (Join-Path $incSnapshots[$refPlat] $h) -Algorithm SHA256).Hash
        $b = (Get-FileHash (Join-Path $incSnapshots[$plat]    $h) -Algorithm SHA256).Hash
        if ($a -ne $b) { throw "include\$h differs between $refPlat and $plat; the single include/ layout cannot represent that." }
    }
}
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($h in $headerNames) { Copy-Item (Join-Path $incSnapshots[$refPlat] $h) -Destination $incDst }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)")
Write-PackageSummary $s
