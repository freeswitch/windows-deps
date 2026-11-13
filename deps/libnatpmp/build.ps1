<#
.SYNOPSIS
    libnatpmp: builds the static natpmp.lib (the NAT-PMP client library) with
    CMake + the Visual C++ toolchain and packages it for FreeSWITCH's
    w32\libnatpmp.props. The consumer is FreeSwitchCore, whose switch_nat.c maps
    ports on the gateway through NAT-PMP.

    FreeSWITCH builds this in tree: FreeSwitchCore.2017.vcxproj compiles
    libs\libnatpmp, a 2009 snapshot, into the core. This node builds 20230423,
    the latest libnatpmp release and the one Debian ships, from Debian's
    orig.tar.gz, which is upstream's release tarball byte for byte (upstream's
    GitHub repository has no tags or releases). Upstream's CMake build is used
    for the library target only: natpmpc and testgetgateway are not built.

    The release's CMakeLists.txt asks for CMake 2.8.12, which CMake 4 refuses,
    so CMAKE_POLICY_VERSION_MINIMUM is set to 3.5. It has no install rules, so
    the library is taken from the build tree and natpmp.h and natpmp_declspec.h,
    the two headers distributions install, from the source tree.

    The library is /MD (Debug: /MDd), CMake's default and what FreeSwitchCore
    uses. Consumers define NATPMP_STATICLIB and link ws2_32.lib and
    iphlpapi.lib.

    Package <pkg> = libnatpmp-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/natpmp.h, natpmp_declspec.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/natpmp.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBNATPMP_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBNATPMP_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libnatpmp'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.14) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libnatpmp       : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "libnatpmp-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = (Get-ChildItem $srcParent -Directory | Select-Object -First 1)
if (-not $root) { throw "The tarball did not expand to a directory." }
# The release keeps its version only in the tarball's directory name.
if ($root.Name -ne "libnatpmp-$($s.Version)") { throw "The tarball expands to '$($root.Name)' but deps.json says $($s.Version)." }
$root = $root.FullName
foreach ($must in 'CMakeLists.txt', 'LICENSE', 'natpmp.c', 'getgateway.c', 'natpmp.h', 'natpmp_declspec.h') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}
Write-Host "The tarball expands to libnatpmp-$($s.Version)"

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building natpmp.lib $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $root)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $lib = Join-Path $bldDir 'natpmp.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target natpmp || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libnatpmp build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "libnatpmp [$plat/$config] did not produce natpmp.lib." }
        # What switch_nat.c calls.
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'initnatpmp', 'closenatpmp', 'sendpublicaddressrequest', 'sendnewportmappingrequest',
                         'getnatpmprequesttimeout', 'readnatpmpresponseorretry') {
            if ($syms -notmatch "\b_?$sym\b") { throw "natpmp.lib does not contain $sym." }
        }

        # --- stage + zip -----------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'LICENSE') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($h in 'natpmp.h', 'natpmp_declspec.h') { Copy-Item (Join-Path $root $h) -Destination $incDst }
Copy-Item (Join-Path $root 'LICENSE') -Destination $hdrRoot
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "library: natpmp.lib (static, /MD)",
               "consumers: define NATPMP_STATICLIB, link ws2_32.lib and iphlpapi.lib")
Write-PackageSummary $s
