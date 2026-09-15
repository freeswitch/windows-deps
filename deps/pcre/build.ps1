<#
.SYNOPSIS
    PCRE2: builds pcre2-8.dll (plus the static library and upstream's tools) with
    CMake + the Visual C++ toolchain, and packages it the way FreeSWITCH's
    w32\pcre.props expects (the layout files.freeswitch.org served; consumer:
    FreeSwitchCore, through switch_regex.c).

    The node is called "pcre" because that is the package name FreeSWITCH uses,
    but the library is PCRE2: FreeSWITCH's regex wrapper has been on the pcre2 API
    since the PCRE2 conversion, and the previous packages were already 10.x. Only
    the 8 bit code unit width is built, which is what <pcre2.h> with
    PCRE2_CODE_UNIT_WIDTH 8 needs. JIT stays off, as before: nothing in FreeSWITCH
    calls pcre2_jit_compile.

    The package is simply upstream's CMake install tree: bin\ (DLLs and the
    pcre2grep / pcre2test tools), lib\ (import and static libraries, the CMake and
    pkg-config files) and LICENCE.md, with include\ split off into the headers zip.
    Debug files carry the "d" postfix (pcre2-8d.dll), which upstream's CMakeLists
    sets itself.

    Package <pkg> = pcre-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENCE.md
                                              <pkg>/include/{pcre2.h, pcre2posix.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/LICENCE.md
                                                                             /bin/*
                                                                             /lib/*
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): PCRE_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, PCRE_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'pcre'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.22) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " pcre (PCRE2)    : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "pcre2-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building PCRE2 $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "pcre2-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $srcDir 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'm4_define\(pcre2_major,\s*\[(\d+)\]\)' ) {
            $major = $Matches[1]
            if ($ac -match 'm4_define\(pcre2_minor,\s*\[(\d+)\]\)') {
                $srcVer = "$major.$($Matches[1])"
                if ($srcVer -ne $s.Version) { throw "PCRE2 source declares version $srcVer but deps.json says $($s.Version)." }
            }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # Both library kinds, like the packages that came before: the DLL is what
        # FreeSWITCH links (pcre2-8[d].lib is its import library), the static one is
        # there for anyone who defines PCRE2_STATIC. 8 bit only, Unicode on, JIT off.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=ON',
            '-DBUILD_STATIC_LIBS=ON',
            '-DPCRE2_BUILD_PCRE2_8=ON',
            '-DPCRE2_BUILD_PCRE2_16=OFF',
            '-DPCRE2_BUILD_PCRE2_32=OFF',
            '-DPCRE2_SUPPORT_UNICODE=ON',
            '-DPCRE2_SUPPORT_JIT=OFF',
            '-DPCRE2_SUPPORT_LIBZ=OFF',
            '-DPCRE2_SUPPORT_LIBBZ2=OFF',
            '-DPCRE2_SUPPORT_LIBREADLINE=OFF',
            '-DPCRE2_SUPPORT_LIBEDIT=OFF'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "pcre build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        $d = if ($config -eq 'Debug') { 'd' } else { '' }
        foreach ($f in "bin\pcre2-8$d.dll", "lib\pcre2-8$d.lib", "lib\pcre2-8-static$d.lib", 'include\pcre2.h') {
            if (-not (Test-Path (Join-Path $insDir $f))) { throw "pcre [$plat/$config] did not install $f." }
        }

        # --- stage ---------------------------------------------------------------
        # The package is the install prefix itself, minus include\ (headers zip).
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        foreach ($sub in 'bin', 'lib') {
            Copy-Item -Path (Join-Path $insDir $sub) -Destination $binDst -Recurse -Force
        }
        Copy-Item (Join-Path $srcDir 'LICENCE.md') -Destination $binDst -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item -Path (Join-Path $headerInstall 'include\*.h') -Destination $incDst
Copy-Item (Join-Path $licenseSrc 'LICENCE.md') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'pcre2.h', 'pcre2posix.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)",
               "features: PCRE2 8 bit, shared + static, Unicode, no JIT, /MD")
Write-PackageSummary $s
