<#
.SYNOPSIS
    libogg: builds the static ogg.lib with CMake + the Visual C++ toolchain and
    packages it for FreeSWITCH's w32\ogg.props.

    FreeSWITCH used to build this in tree: w32\download_OGG.props fetched
    libogg-1.1.3.tar.gz from files.freeswitch.org and
    libs\win32\libogg\libogg.2017.vcxproj compiled it. This node builds upstream's
    own CMake project instead, which also generates ogg\config_types.h -- the
    header the in tree build had to provide by hand.

    Package <pkg> = libogg-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/ogg/{ogg.h, os_types.h,
                                                                 config_types.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/ogg.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBOGG_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBOGG_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libogg'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

$cmakeCmd = Get-Command cmake -ErrorAction Stop
$cmakeVersion = (& cmake --version | Select-Object -First 1)

Write-Host "==================================================================="
Write-Host " libogg          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
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

$tarball = Join-Path $s.BuildRoot "libogg-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libogg $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "libogg-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $srcDir 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\[libogg\],\[([0-9][0-9.]*)\]') {
            if ($Matches[1] -ne $s.Version) { throw "libogg source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # Static library, nothing else: no docs, no pkg-config or CMake package files.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DBUILD_TESTING=OFF',
            '-DINSTALL_DOCS=OFF',
            '-DINSTALL_PKG_CONFIG_MODULE=OFF',
            '-DINSTALL_CMAKE_PACKAGE_MODULE=OFF'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libogg build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        $lib = Join-Path $insDir 'lib\ogg.lib'
        foreach ($f in 'lib\ogg.lib', 'include\ogg\ogg.h', 'include\ogg\os_types.h', 'include\ogg\config_types.h') {
            if (-not (Test-Path (Join-Path $insDir $f))) { throw "libogg [$plat/$config] did not install $f." }
        }

        # The bitstream entry points a consumer works through.
        $symFile = Join-Path $work "symbols-$config.txt"
        $dump = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$symFile" || exit /b 1
"@
        Invoke-BuildBatch -Script $dump -BatchFile (Join-Path $work 'dump.bat') -LogFile (Join-Path $work 'dump.log') -Label "libogg symbols [$plat/$config]"
        $syms = Get-Content $symFile -Raw
        foreach ($sym in 'ogg_sync_init', 'ogg_sync_buffer', 'ogg_sync_wrote', 'ogg_sync_pageout',
                         'ogg_stream_init', 'ogg_stream_pagein', 'ogg_stream_packetout', 'ogg_page_serialno') {
            if ($syms -notmatch "\b$sym\b") { throw "ogg.lib does not contain $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $srcDir 'COPYING') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# config_types.h is generated by the CMake run, so the headers come from the
# install tree rather than the source.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\ogg'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerInstall 'include\ogg\*.h') -Destination $incDst
Copy-Item (Join-Path $licenseSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'ogg.h', 'os_types.h', 'config_types.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\ogg\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "cmake: $cmakeVersion", "library: ogg.lib (static)")
Write-PackageSummary $s
