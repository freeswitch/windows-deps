<#
.SYNOPSIS
    miniupnpc: builds the static libminiupnpc.lib (the UPnP IGD client library)
    with CMake + the Visual C++ toolchain and packages it for FreeSWITCH's
    w32\miniupnpc.props. The consumer is FreeSwitchCore, whose switch_nat.c maps
    ports on the gateway through UPnP.

    FreeSWITCH builds this in tree: FreeSwitchCore.2017.vcxproj compiles
    libs\miniupnpc, a 2009 snapshot (1.3), into the core. This node builds the
    latest miniupnpc release, the tarball attached to upstream's GitHub release,
    with upstream's own CMake build, static library only: no shared library,
    samples or tests.

    Upstream sources are taken as they come, plus the diffs in patches\: the
    minixml.c fixes upstream made after 2.3.3 for one-byte heap over-reads a
    spoofed gateway can trigger, one in parseatt and two in parseelt. No
    miniupnpc release carries them yet.

    The library is /MD (Debug: /MDd), CMake's default and what FreeSwitchCore
    uses. Consumers define MINIUPNP_STATICLIB and link ws2_32.lib and
    iphlpapi.lib.

    Package <pkg> = miniupnpc-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/miniupnpc/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/libminiupnpc.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): MINIUPNPC_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, MINIUPNPC_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'miniupnpc'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.14) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

$patches = @(Get-ChildItem (Join-Path $PSScriptRoot 'patches') -Filter '*.patch' | Sort-Object Name)

Write-Host "==================================================================="
Write-Host " miniupnpc       : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Patches         : $($patches.Count)"
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

$tarball = Join-Path $s.BuildRoot "miniupnpc-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = (Get-ChildItem $srcParent -Directory | Select-Object -First 1)
if (-not $root) { throw "The tarball did not expand to a directory." }
$root = $root.FullName
foreach ($must in 'CMakeLists.txt', 'VERSION', 'LICENSE', 'include\miniupnpc.h', 'src\minixml.c') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}

# The version must agree in all three places upstream keeps it.
$verFile = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ($verFile -ne $s.Version) { throw "VERSION says $verFile but deps.json says $($s.Version)." }
$cml = Get-Content (Join-Path $root 'CMakeLists.txt') -Raw
if ($cml -notmatch 'project\s*\(\s*miniupnpc\s+VERSION\s+([0-9][0-9.]*)') { throw "CMakeLists.txt has no project() version." }
if ($Matches[1] -ne $s.Version) { throw "CMakeLists.txt declares $($Matches[1]) but deps.json says $($s.Version)." }
$hdr = Get-Content (Join-Path $root 'include\miniupnpc.h') -Raw
if ($hdr -notmatch '#define\s+MINIUPNPC_VERSION\s+"([0-9][0-9.]*)"') { throw "include\miniupnpc.h defines no MINIUPNPC_VERSION." }
if ($Matches[1] -ne $s.Version) { throw "include\miniupnpc.h says $($Matches[1]) but deps.json says $($s.Version)." }
Write-Host "VERSION, CMakeLists.txt and include\miniupnpc.h declare $($s.Version)"

# Everything this build changes in upstream sources lives in patches\ and is
# applied here; patch fails the build if a hunk no longer applies, which is how
# a fix landing upstream would announce itself.
foreach ($patch in $patches) {
    Write-Host "applying $($patch.Name)"
    & patch -p1 -i "$($patch.FullName)" -d "$root" --binary
    if ($LASTEXITCODE -ne 0) { throw "patch $($patch.Name) did not apply (exit $LASTEXITCODE)." }
}

$incSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libminiupnpc.lib $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $bldDir = Join-Path $work 'build'
        $prefix = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $root)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $prefix)`"",
            '-DUPNPC_BUILD_STATIC=ON',
            '-DUPNPC_BUILD_SHARED=OFF',
            '-DUPNPC_BUILD_TESTS=OFF',
            '-DUPNPC_BUILD_SAMPLE=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $lib = Join-Path $prefix 'lib\libminiupnpc.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" || exit /b 1
cmake --install "$bldDir" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "miniupnpc build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "miniupnpc [$plat/$config] did not produce lib\libminiupnpc.lib." }
        # What switch_nat.c calls.
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'upnpDiscover', 'freeUPNPDevlist', 'miniwget', 'parserootdesc', 'GetUPNPUrls',
                         'FreeUPNPUrls', 'UPNP_GetExternalIPAddress', 'UPNP_AddPortMapping', 'UPNP_DeletePortMapping') {
            if ($syms -notmatch "\b_?$sym\b") { throw "libminiupnpc.lib does not contain $sym." }
        }

        # --- stage + zip -----------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'LICENSE') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $incSrc) { $incSrc = Join-Path $prefix 'include\miniupnpc' }
    }
}

# --- headers zip -------------------------------------------------------------------
# The headers upstream's CMake installs, as installed: copied from include\, none
# of them generated, so one configuration's set stands for all.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\miniupnpc'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Get-ChildItem $incSrc -File -Filter '*.h' | Copy-Item -Destination $incDst
Copy-Item (Join-Path $root 'LICENSE') -Destination $hdrRoot
foreach ($must in 'miniupnpc.h', 'miniupnpc_declspec.h', 'miniwget.h', 'igd_desc_parse.h', 'upnpcommands.h', 'upnperrors.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\miniupnpc\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "library: libminiupnpc.lib (static, /MD)",
               "patches: $(($patches | ForEach-Object { $_.Name }) -join ', ')",
               "consumers: define MINIUPNP_STATICLIB, link ws2_32.lib and iphlpapi.lib")
Write-PackageSummary $s
