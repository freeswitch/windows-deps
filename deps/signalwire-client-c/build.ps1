<#
.SYNOPSIS
    signalwire-client-c (SignalWire's C client, repository signalwire/signalwire-c):
    builds the shared signalwire_client2.dll with CMake + the Visual C++ toolchain
    against this repository's libks and OpenSSL packages, and packages it the way
    FreeSWITCH's w32\signalwire-client-c.props expects (mod_signalwire) -- the
    layout signalwire-c's own win\ wrapper produced.

    Package <pkg> = signalwire-client-c-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/signalwire-client-c/*.h   (the repository's inc/ directory)
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/signalwire_client2.dll
                                                                             /signalwire_client2.lib
                                                                             /signalwire_client2.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    signalwire_client2.dll imports ks2.dll (libks package); OpenSSL is static.
    No debug postfix: Debug files are also named signalwire_client2.*.

    Environment (all optional): SIGNALWIRE_CLIENT_C_VERSION, BUILD_NUMBER, PKG_NAME,
    CONFIGS, PLATFORMS, OUT_DIR, BUILD_ROOT, SIGNALWIRE_CLIENT_C_URL, EXTRA_CMAKE,
    and LIBKS_PKG_BASE / LIBKS_PKG, OPENSSL_PKG_BASE / OPENSSL_PKG for the dependency
    packages (scripts\build.ps1 sets those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'signalwire-client-c'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " signalwire-c    : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " libks           : package $(Get-EnvValue 'LIBKS_PKG' '?') from $(Get-EnvValue 'LIBKS_PKG_BASE' '?')"
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

$tarball = Join-Path $s.BuildRoot "signalwire-c-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$depCache = Join-Path $s.BuildRoot 'deps'

# libks headers package: FindLibKS.cmake wants the folder holding CMakeLists.txt,
# cmake/ksutil.cmake and src/include (the "libks" folder inside the package).
$ksInclude = Join-Path (Get-DepPackageRoot -Dep libks -Kind headers -CacheDir $depCache) 'libks'
foreach ($must in 'CMakeLists.txt', 'cmake\ksutil.cmake', 'src\include\libks\ks.h') {
    if (-not (Test-Path (Join-Path $ksInclude $must))) { throw "libks headers package is missing 'libks\$must'." }
}

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building signalwire-c $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "signalwire-c-$($s.Version)"   # GitHub tag tarball expands to signalwire-c-<ver>/
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        $projLine = Select-String -Path (Join-Path $srcDir 'CMakeLists.txt') -Pattern '^\s*project\s*\(\s*SignalWire-Client-C2\s+VERSION\s+([0-9.]+)' | Select-Object -First 1
        if ($projLine -and $projLine.Matches[0].Groups[1].Value -ne $s.Version) { throw "signalwire-c source declares version $($projLine.Matches[0].Groups[1].Value) but deps.json says $($s.Version)." }

        $ksBin   = Join-Path (Get-DepPackageRoot -Dep libks -Kind binaries -CacheDir $depCache -Platform $plat -Config $config) "binaries\$plat\$config"
        if (-not (Test-Path (Join-Path $ksBin 'ks2.lib'))) { throw "libks binaries package for $plat/$config has no ks2.lib (looked in '$ksBin')." }
        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache

        # Mirrors signalwire-c's own win\signalwire-client-c.vcxproj (cmake + build
        # of target signalwire_client2), minus the Visual Studio generator.
        # HUNTER_WIKI skips HunterGate (unused without tests); cotire's PCH/unity
        # build is switched off -- it only speeds up compilation.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DHUNTER_WIKI=ON',
            "-DLIBKS_INCLUDE_DIRS=`"$(ConvertTo-ForwardSlashes $ksInclude)`"",
            "-DLIBKS_LIBRARY_PATH=`"$(ConvertTo-ForwardSlashes $ksBin)`"",
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON',
            '-DCOTIRE_ENABLE_PRECOMPILED_HEADER=OFF',
            '-DCOTIRE_ADD_UNITY_BUILD=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target signalwire_client2 || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "signalwire-c build [$plat/$config]"

        # ksutil_setup_platform() (pulled in via FindLibKS) routes outputs to the build dir root.
        foreach ($f in 'signalwire_client2.dll', 'signalwire_client2.lib') {
            if (-not (Test-Path (Join-Path $bldDir $f))) {
                $have = Get-ChildItem -Recurse -File $bldDir -Include *.dll, *.lib | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
                throw "signalwire-c [$plat/$config] did not produce $f in '$bldDir'. Found: $($have -join ', ')."
            }
        }
        $dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $bldDir 'signalwire_client2.dll')))
        if ($dllText -notmatch '(?i)ks2\.dll') { throw "signalwire_client2.dll does not import ks2.dll." }

        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item (Join-Path $bldDir 'signalwire_client2.dll'), (Join-Path $bldDir 'signalwire_client2.lib') -Destination $binDst
        if ($config -eq 'Debug' -and (Test-Path (Join-Path $bldDir 'signalwire_client2.pdb'))) { Copy-Item (Join-Path $bldDir 'signalwire_client2.pdb') -Destination $binDst }
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir }
    }
}

# --- headers zip: the repository's inc/ directory ---------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
New-Item -ItemType Directory -Force -Path $hdrRoot | Out-Null
Copy-Item (Join-Path $headerSrc 'inc') -Destination (Join-Path $hdrRoot 'include') -Recurse
if (-not (Test-Path (Join-Path $hdrRoot 'include\signalwire-client-c\client.h'))) { throw "Headers package is missing include\signalwire-client-c\client.h." }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)")
Write-PackageSummary $s
