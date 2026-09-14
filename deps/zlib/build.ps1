<#
.SYNOPSIS
    zlib: builds the shared zlib.dll with its import library and the static
    zlibstatic.lib with CMake + the Visual C++ toolchain, and packages them in the
    layout FreeSWITCH's w32\zlib.props consumes.

    Package <pkg> = zlib-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/{zlib.h, zconf.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/bin/zlib.dll        (zlibd.dll in Debug)
                                                                             /bin/zlibd.pdb       (Debug only)
                                                                             /lib/zlib.lib        (zlibd.lib in Debug)       import library
                                                                             /lib/zlibstatic.lib  (zlibstaticd.lib in Debug) static library
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): ZLIB_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, ZLIB_URL, EXTRA_CMAKE. Run via scripts\build.ps1.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'zlib'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)

# Output names depend on the configuration (CMake's "d" debug postfix), so only
# the two configurations FreeSWITCH builds are supported.
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " zlib            : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "zlib-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

# zlib 1.3.2 rewrote its CMake build and now names the Windows outputs
# z.dll / z.lib (import) / zs.lib (static). FreeSWITCH's w32\zlib.props -- and the
# packages this replaces -- expect the names zlib's earlier CMake produced:
# zlib.dll + zlib.lib and zlibstatic.lib, with CMake's "d" debug postfix
# (zlibd.dll, zlibd.lib, zlibstaticd.lib). The DLL name is baked into the import
# library, so it has to be fixed at link time, not by renaming files afterwards.
# This file is injected via CMAKE_PROJECT_zlib_INCLUDE (included right after
# zlib's project() call) and defers the property change until all targets exist.
# On zlib versions that already use these names it is a no-op.
$fixupCMake = @'
# Injected by deps/zlib/build.ps1 via CMAKE_PROJECT_zlib_INCLUDE.
function(fs_zlib_restore_output_names)
    if(TARGET zlib)
        set_target_properties(zlib PROPERTIES OUTPUT_NAME zlib)
    endif()
    if(TARGET zlibstatic)
        set_target_properties(zlibstatic PROPERTIES OUTPUT_NAME zlibstatic)
    endif()
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL fs_zlib_restore_output_names)
'@
$fixupFile = Join-Path $s.BuildRoot 'fs-zlib-names.cmake'
Set-Content -Path $fixupFile -Value $fixupCMake -Encoding ASCII

$headerNames  = @('zlib.h', 'zconf.h')
$incSnapshots = @{}

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building zlib $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "zlib-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $prefix = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        # Fresh source copy per platform/config (older zlib CMake builds touch the
        # source tree, e.g. renaming zconf.h).
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $prefix)`"",
            "-DCMAKE_PROJECT_zlib_INCLUDE=`"$(ConvertTo-ForwardSlashes $fixupFile)`"",
            '-DZLIB_BUILD_SHARED=ON',
            '-DZLIB_BUILD_STATIC=ON',
            '-DZLIB_INSTALL=ON',
            '-DZLIB_BUILD_TESTING=OFF',    # skip example/minigzip (zlib >= 1.3.2)
            '-DZLIB_BUILD_MINIZIP=OFF'     # skip contrib/minizip (zlib >= 1.3.2)
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "zlib build [$plat/$config]"

        # --- verify the install tree has exactly the names FreeSWITCH links ----
        $d = if ($config -eq 'Debug') { 'd' } else { '' }
        $expected = @("bin\zlib$d.dll", "lib\zlib$d.lib", "lib\zlibstatic$d.lib")
        $missing = @($expected | Where-Object { -not (Test-Path (Join-Path $prefix $_)) })
        if ($missing.Count -gt 0) {
            $have = Get-ChildItem -Recurse -File $prefix | ForEach-Object { $_.FullName.Substring($prefix.Length + 1) }
            throw "zlib [$plat/$config] did not produce: $($missing -join ', '). Installed tree contains: $($have -join ', '). (Upstream naming changed? See fs-zlib-names.cmake.)"
        }
        # The import library embeds the DLL name the consumer loads at run time.
        $implibText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $prefix "lib\zlib$d.lib")))
        if ($implibText -notmatch "(?i)zlib$d\.dll") { throw "lib\zlib$d.lib does not reference zlib$d.dll -- the DLL was linked under a different name." }
        foreach ($h in $headerNames) {
            if (-not (Test-Path (Join-Path $prefix "include\$h"))) { throw "Expected header include\$h was not installed." }
        }

        # --- stage + zip -------------------------------------------------------
        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path (Join-Path $binDst 'bin'), (Join-Path $binDst 'lib') | Out-Null
        Get-ChildItem (Join-Path $prefix 'bin') -File | Where-Object { $_.Extension -in @('.dll', '.pdb') } |
            Copy-Item -Destination (Join-Path $binDst 'bin')
        Get-ChildItem (Join-Path $prefix 'lib') -File -Filter '*.lib' |
            Copy-Item -Destination (Join-Path $binDst 'lib')
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $incSnapshots.ContainsKey($plat)) {
            $snap = Join-Path $stage "inc-$plat"
            New-Item -ItemType Directory -Force -Path $snap | Out-Null
            foreach ($h in $headerNames) { Copy-Item (Join-Path $prefix "include\$h") -Destination $snap }
            $incSnapshots[$plat] = $snap
        }
    }
}

# --- headers zip ------------------------------------------------------------------
# Single include/ (no per-arch split): zconf.h is generated by CMake but does not
# depend on the target architecture with MSVC. Verified rather than assumed.
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
