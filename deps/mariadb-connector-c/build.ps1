<#
.SYNOPSIS
    MariaDB Connector/C: builds libmariadb.dll (+ import library, static library and
    the client plugins) with CMake + the Visual C++ toolchain, and packages it the
    way FreeSWITCH's w32\mariadb-connector-c.props expects (the layout
    files.freeswitch.org served; consumer: mod_mariadb).

    TLS comes from Schannel, not OpenSSL: that is upstream's Windows default and
    what the previous packages did (hence the Secur32.lib in the consumer's link
    line), so this node depends on nothing else in the graph.

    Package <pkg> = mariadb-connector-c-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING.LIB
                                              <pkg>/include/*.h, include/mysql/*.h, include/mariadb/*.h
                                                  (exactly what upstream installs, mariadb_version.h included)
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING.LIB
                                              <pkg>/binaries/<Platform>/<Config>/{libmariadb.dll, libmariadb.lib,
                                                                                  libmariadb.pdb, mariadbclient.lib}
                                                                             /plugin/*.dll
      SHA256SUMS.txt, <pkg>-BOM.txt

    NOTE on plugins: on Windows the connector does NOT use the plugin directory
    compiled into it. It loads <name>.dll from the plugin dir given by
    mysql_options(MYSQL_PLUGIN_DIR) or the MARIADB_PLUGIN_DIR environment
    variable, and otherwise by plain DLL search order. The package keeps them in
    plugin\ because that is where the property sheet picks them up from.

    Environment (all optional): MARIADB_CONNECTOR_C_VERSION, BUILD_NUMBER, PKG_NAME,
    CONFIGS, PLATFORMS, OUT_DIR, BUILD_ROOT, MARIADB_CONNECTOR_C_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'mariadb-connector-c'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.22) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " mariadb-connector-c : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " TLS             : Schannel (no OpenSSL dependency)"
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

$tarball = Join-Path $s.BuildRoot "mariadb-connector-c-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null   # install prefix of the first build (headers are config independent)
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building mariadb-connector-c $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "mariadb-connector-c-$($s.Version)"   # GitHub tag archive of v<ver>
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version upstream's CMake declares must match the manifest.
        $cml = Get-Content (Join-Path $srcDir 'CMakeLists.txt') -Raw
        $ver = foreach ($k in 'MAJOR', 'MINOR', 'PATCH') {
            if ($cml -match "(?m)^SET\(CPACK_PACKAGE_VERSION_$k\s+([0-9]+)\)") { $Matches[1] } else { $null }
        }
        if ($ver -notcontains $null) {
            $srcVer = $ver -join '.'
            if ($srcVer -ne $s.Version) { throw "Connector/C source declares version $srcVer but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read CPACK_PACKAGE_VERSION_* from CMakeLists.txt, version not cross-checked."
        }

        # WITH_SSL=SCHANNEL is the Windows default, set explicitly so the package can
        # never silently pick up an OpenSSL from the image. WITH_CURL=OFF drops the
        # AWS IAM plugin (and with it a libcurl dependency), WITH_UNIT_TESTS=OFF skips
        # the test suite, WITH_EXTERNAL_ZLIB=OFF uses the bundled zlib.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DWITH_SSL=SCHANNEL',
            '-DWITH_CURL=OFF',
            '-DWITH_UNIT_TESTS=OFF',
            '-DWITH_EXTERNAL_ZLIB=OFF',
            '-DWITH_MSI=OFF',
            '-DWITH_SIGNCODE=OFF'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "mariadb-connector-c build [$plat/$config]"

        # --- collect --------------------------------------------------------------
        # Upstream moves things between install layouts, so everything is located by
        # name and the result is verified rather than assumed.
        function Find-One([string]$Root, [string]$Name) {
            $hit = Get-ChildItem -Recurse -File $Root -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $hit.FullName } else { $null }
        }
        $dll = Find-One $insDir 'libmariadb.dll'; if (-not $dll) { $dll = Find-One $bldDir 'libmariadb.dll' }
        $imp = Find-One $insDir 'libmariadb.lib'; if (-not $imp) { $imp = Find-One $bldDir 'libmariadb.lib' }
        $sta = Find-One $insDir 'mariadbclient.lib'; if (-not $sta) { $sta = Find-One $bldDir 'mariadbclient.lib' }
        $pdb = Find-One $bldDir 'libmariadb.pdb'
        foreach ($p in @(@{n = 'libmariadb.dll'; v = $dll}, @{n = 'libmariadb.lib'; v = $imp}, @{n = 'mariadbclient.lib'; v = $sta})) {
            if (-not $p.v) { throw "mariadb-connector-c [$plat/$config] did not produce $($p.n)." }
        }
        # Client plugins: every other DLL that got built (dialog, caching_sha2_password,
        # sha256_password, mysql_clear_password, auth_gssapi_client, pvio_npipe, pvio_shmem).
        $plugins = @(Get-ChildItem -Recurse -File $bldDir -Filter '*.dll' | Where-Object { $_.Name -ne 'libmariadb.dll' } |
                     Group-Object Name | ForEach-Object { $_.Group[0] })
        Write-Host ("plugins built: {0}" -f (($plugins | ForEach-Object { $_.Name }) -join ', '))
        foreach ($must in 'caching_sha2_password.dll', 'dialog.dll', 'sha256_password.dll') {
            if ($plugins.Name -notcontains $must) { throw "client plugin $must was not built; the previous packages shipped it." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        $plgDst  = Join-Path $binDst 'plugin'
        New-Item -ItemType Directory -Force -Path $plgDst | Out-Null
        Copy-Item $dll, $imp, $sta -Destination $binDst
        if ($pdb) { Copy-Item $pdb -Destination $binDst }
        foreach ($p in $plugins) { Copy-Item $p.FullName -Destination $plgDst }
        Copy-Item (Join-Path $srcDir 'COPYING.LIB') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# Taken from the install tree, so the set is exactly what upstream declares public
# (include/CMakeLists.txt), including the generated mariadb_version.h.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
$incSrc = Get-ChildItem -Recurse -Directory $headerInstall | Where-Object { Test-Path (Join-Path $_.FullName 'mysql.h') } | Select-Object -First 1
if (-not $incSrc) { throw "No installed include directory with mysql.h found under '$headerInstall'." }
Copy-Item -Path (Join-Path $incSrc.FullName '*') -Destination $incDst -Recurse -Force
Copy-Item (Join-Path $licenseSrc 'COPYING.LIB') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'mysql.h', 'mariadb_version.h', 'mariadb_com.h', 'errmsg.h', 'mysql\client_plugin.h', 'mariadb\ma_io.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)",
               "features: Schannel TLS, bundled zlib, no curl (no AWS IAM plugin), no unit tests, /MD")
Write-PackageSummary $s
