<#
.SYNOPSIS
    libsrtp: builds the static srtp2.lib (libSRTP 2) with OpenSSL crypto, using
    CMake + the Visual C++ toolchain, and packages it for FreeSWITCH's
    w32\libsrtp.props. The consumer is FreeSwitchCore, whose switch_rtp.c
    protects RTP and RTCP with it.

    FreeSWITCH builds this in tree: libs\srtp\libsrtp.2017.vcxproj compiles
    2.6.0 with OpenSSL crypto and AES-GCM. This node builds 2.8.1, the latest
    release, from the GitHub tag archive with upstream's CMake: ENABLE_OPENSSL,
    which also enables AES-GCM, against this repository's OpenSSL package, and
    no test applications. The package holds what upstream's install rules
    install: srtp2.lib, and srtp.h, auth.h, cipher.h and crypto_types.h in
    include\srtp2\.

    OpenSSL is referenced, not linked, by the static library: consumers link
    the OpenSSL package and ws2_32.lib, which libsrtp.props does. The library
    is /MD (Debug: /MDd), CMake's default and what FreeSwitchCore uses.

    Package <pkg> = libsrtp-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/srtp2/srtp.h, auth.h, cipher.h, crypto_types.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/srtp2.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBSRTP_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBSRTP_URL, EXTRA_CMAKE, and
    OPENSSL_PKG_BASE / OPENSSL_PKG for the OpenSSL package (scripts\build.ps1 sets
    those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libsrtp'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.21) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libsrtp         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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
$depCache = Join-Path $s.BuildRoot 'deps'

$tarball = Join-Path $s.BuildRoot "libsrtp-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = Join-Path $srcParent "libsrtp-$($s.Version)"   # GitHub tag archive of v<ver>
if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
foreach ($must in 'CMakeLists.txt', 'LICENSE', 'include\srtp.h') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}
# The version CMake gives the library (and srtp_get_version_string() returns) must match the manifest.
$cml = Get-Content (Join-Path $root 'CMakeLists.txt') -Raw
if ($cml -notmatch '(?m)^project\(libsrtp2 VERSION (\S+)') { throw "project(libsrtp2 VERSION ...) not found in CMakeLists.txt." }
if ($Matches[1] -ne $s.Version) { throw "libsrtp source declares version $($Matches[1]) but deps.json says $($s.Version)." }
Write-Host "CMakeLists.txt declares libsrtp2 $($s.Version)"

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building srtp2.lib $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $bldDir = Join-Path $work 'build'
        $inst   = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $root)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $inst)`"",
            '-DENABLE_OPENSSL=ON',
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON',
            '-DLIBSRTP_TEST_APPS=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $lib = Join-Path $inst 'lib\srtp2.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" || exit /b 1
cmake --install "$bldDir" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libsrtp build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "libsrtp [$plat/$config] did not install lib\srtp2.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        # What switch_rtp.c calls, and srtp_aes_gcm_256, which only the OpenSSL backend defines.
        foreach ($sym in 'srtp_init', 'srtp_shutdown', 'srtp_create', 'srtp_dealloc', 'srtp_get_version_string',
                         'srtp_protect', 'srtp_protect_mki', 'srtp_unprotect', 'srtp_unprotect_mki',
                         'srtp_protect_rtcp', 'srtp_protect_rtcp_mki', 'srtp_unprotect_rtcp', 'srtp_unprotect_rtcp_mki',
                         'srtp_crypto_policy_set_aes_gcm_256_16_auth', 'srtp_aes_gcm_256') {
            if ($syms -notmatch "\b_?$sym\b") { throw "srtp2.lib does not contain $sym." }
        }

        # --- stage + zip -----------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'LICENSE') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        $hdrInst = Join-Path $inst 'include'
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
New-Item -ItemType Directory -Force -Path $hdrRoot | Out-Null
Copy-Item $hdrInst -Destination $hdrRoot -Recurse
foreach ($h in 'srtp.h', 'auth.h', 'cipher.h', 'crypto_types.h') {
    if (-not (Test-Path (Join-Path $hdrRoot "include\srtp2\$h"))) { throw "Headers package is missing include\srtp2\$h." }
}
Copy-Item (Join-Path $root 'LICENSE') -Destination $hdrRoot
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "library: srtp2.lib (static, /MD, OpenSSL crypto with AES-GCM)",
               "consumers: link the OpenSSL package and ws2_32.lib")
Write-PackageSummary $s
