<#
.SYNOPSIS
    libks (SignalWire's C utility library): builds the shared ks2.dll with CMake +
    the Visual C++ toolchain against this repository's OpenSSL package, and
    packages it the way FreeSWITCH's w32\libks.props and signalwire-c's
    cmake\FindLibKS.cmake expect -- the layout libks's own win\ wrapper produced.

    Package <pkg> = libks-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/libks/CMakeLists.txt          (FindLibKS.cmake reads the version from it)
                                              <pkg>/libks/cmake/ksutil.cmake      (FindLibKS.cmake includes it)
                                              <pkg>/libks/src/include/libks/*.h, cJSON/*
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/ks2.dll
                                                                             /ks2.lib
                                                                             /ks2.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    Note: libks disables the debug postfix, so Debug files are also named ks2.*.
    OpenSSL is linked statically into ks2.dll (the openssl package is static libs).

    Environment (all optional): LIBKS_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBKS_URL, EXTRA_CMAKE, and OPENSSL_PKG_BASE /
    OPENSSL_PKG for the OpenSSL package (scripts\build.ps1 sets those from the
    plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libks'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libks           : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " OpenSSL         : package $(Get-EnvValue 'OPENSSL_PKG' '?') from $(Get-EnvValue 'OPENSSL_PKG_BASE' '?')"
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

$tarball = Join-Path $s.BuildRoot "libks-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$depCache = Join-Path $s.BuildRoot 'deps'

$headerSrc = $null   # source tree of the first build, used for the headers package

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libks $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "libks-$($s.Version)"     # GitHub tag tarball expands to libks-<ver>/
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version FindLibKS.cmake (signalwire-c) will read from the packaged
        # CMakeLists.txt must be the version we claim to package.
        $projLine = Select-String -Path (Join-Path $srcDir 'CMakeLists.txt') -Pattern '^\s*project\s*\(\s*LibKS2\s+VERSION\s+([0-9.]+)' | Select-Object -First 1
        if (-not $projLine) { throw "Could not find 'project(LibKS2 VERSION ...)' in libks's CMakeLists.txt." }
        $cmakeVer = $projLine.Matches[0].Groups[1].Value
        if ($cmakeVer -ne $s.Version) { throw "libks source declares version $cmakeVer but deps.json says $($s.Version)." }

        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache

        # Mirrors libks's own win\libks.vcxproj (cmake + build of target ks2), minus
        # the Visual Studio generator. HUNTER_WIKI skips HunterGate, which libks
        # only needs for its Catch2 test harness (WITH_KS_TEST=OFF).
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DHUNTER_WIKI=ON',
            '-DWITH_KS_TEST=OFF',
            '-DKS_STATIC=OFF',
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target ks2 || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libks build [$plat/$config]"

        # ksutil_setup_platform() routes all outputs to the build dir root.
        foreach ($f in 'ks2.dll', 'ks2.lib') {
            if (-not (Test-Path (Join-Path $bldDir $f))) {
                $have = Get-ChildItem -Recurse -File $bldDir -Include *.dll, *.lib | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
                throw "libks [$plat/$config] did not produce $f in '$bldDir'. Found: $($have -join ', ')."
            }
        }
        $dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $bldDir 'ks2.dll')))
        if ($dllText -match '(?i)libcrypto[^\s]*\.dll|libssl[^\s]*\.dll') { throw "ks2.dll imports an OpenSSL DLL; it must link the static OpenSSL package." }

        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item (Join-Path $bldDir 'ks2.dll'), (Join-Path $bldDir 'ks2.lib') -Destination $binDst
        if ($config -eq 'Debug' -and (Test-Path (Join-Path $bldDir 'ks2.pdb'))) { Copy-Item (Join-Path $bldDir 'ks2.pdb') -Destination $binDst }
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir }
    }
}

# --- headers zip: the slice of the source tree consumers use --------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)\libks"
New-Item -ItemType Directory -Force -Path (Join-Path $hdrRoot 'cmake'), (Join-Path $hdrRoot 'src') | Out-Null
Copy-Item (Join-Path $headerSrc 'CMakeLists.txt')     -Destination $hdrRoot
Copy-Item (Join-Path $headerSrc 'cmake\ksutil.cmake') -Destination (Join-Path $hdrRoot 'cmake')
Copy-Item (Join-Path $headerSrc 'src\include')        -Destination (Join-Path $hdrRoot 'src\include') -Recurse
foreach ($must in 'libks\src\include\libks\ks.h', 'libks\cmake\ksutil.cmake', 'libks\CMakeLists.txt') {
    if (-not (Test-Path (Join-Path (Split-Path $hdrRoot -Parent) $must))) { throw "Headers package is missing '$must'." }
}
New-PackageZip (Split-Path $hdrRoot -Parent) (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)")
Write-PackageSummary $s
