<#
.SYNOPSIS
    mpg123: builds the libmpg123 DLL and its import library with CMake + the
    Visual C++ toolchain and packages them for FreeSWITCH's w32\mpg123.props.
    The consumer is mod_shout, which decodes MP3 with it.

    FreeSWITCH used to build this in tree: w32\download_mpg123.props fetched
    mpg123-1.14.4.tar.bz2 from files.freeswitch.org, renamed the directory to
    libs\libmpg123 and libs\win32\mpg123\libmpg123.2017.vcxproj compiled a hand
    kept list of sources against two files checked into the tree,
    libs\win32\mpg123\libmpg123\{config.h, mpg123.h}, plus ports\MSVC++\msvc.c
    from the tarball.

    1.33.7 has no MSVC port any more -- ports\README says the contributed ones
    were dropped as they went stale, leaving ports\cmake -- so this node builds
    that, which generates config.h and mpg123.h itself. Only the decoder is
    built: libout123 is off (it also gates the programs) and so are the tools,
    since mod_shout links nothing else.

    Package <pkg> = mpg123-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/{mpg123.h, fmt123.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/{mpg123.dll,
                                                                                  mpg123.lib}
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): MPG123_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, MPG123_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'mpg123'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

$cmakeCmd = Get-Command cmake -ErrorAction Stop
$cmakeVersion = (& cmake --version | Select-Object -First 1)

Write-Host "==================================================================="
Write-Host " mpg123          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " Extra cmake     : $extraCMake"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " cmake           : $($cmakeCmd.Source) ($cmakeVersion)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

# Which tools actually got picked matters on a hosted runner, where the PATH is
# not ours: name them before anything long starts.
foreach ($t in 'cmake', 'nmake', 'ml64', 'nasm', 'tar') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    Write-Host ("  {0,-6} {1}" -f $t, $(if ($c) { $c.Source } else { "(not on PATH)" }))
}
Write-Host ("  tar in use: {0}" -f $tc.Tar)

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tarball = Join-Path $s.BuildRoot "mpg123-$($s.Version).tar.bz2"
Get-RemoteFile $s.SourceUrl $tarball

# Upstream ships bzip2 only. The bsdtar in Windows Server 2022's System32 stalls
# on it, so the bzip2 layer comes off here and tar only ever sees a plain .tar.
# 7-Zip if the machine has it (hosted runners do), otherwise Python (the
# toolchain image has it); both are far quicker than the archive is large.
$plainTar = [System.IO.Path]::ChangeExtension($tarball, $null).TrimEnd('.')
if (-not (Test-Path $plainTar)) {
    $sevenZip = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($sevenZip) {
        Write-Host "decompressing with $sevenZip ..."
        & $sevenZip e -y "-o$($s.BuildRoot)" $tarball | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z could not decompress '$tarball'." }
    } else {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) { throw "Neither 7-Zip nor python is available to decompress '$tarball'." }
        Write-Host "decompressing with $($python.Source) ..."
        $code = "import bz2,shutil,sys" + [char]10 +
                "with bz2.open(sys.argv[1]) as i, open(sys.argv[2], 'wb') as o: shutil.copyfileobj(i, o)"
        & $python.Source -c $code $tarball $plainTar
        if ($LASTEXITCODE -ne 0) { throw "python could not decompress '$tarball'." }
    }
    if (-not (Test-Path $plainTar)) { throw "Decompressing '$tarball' produced no '$plainTar'." }
}
Write-Host ("  -> {0:N0} bytes uncompressed" -f (Get-Item $plainTar).Length)

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libmpg123 $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "mpg123-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Write-Host '-- extracting ...'
        Expand-Tarball $plainTar $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }
        $cmakeSrc = Join-Path $srcDir 'ports\cmake'
        if (-not (Test-Path (Join-Path $cmakeSrc 'CMakeLists.txt'))) { throw "No CMake port in '$cmakeSrc'." }

        # src\version.h is where the version lives -- configure.ac only assembles it
        # from m4 macros, and the CMake port reads this same header.
        $vh = Get-Content (Join-Path $srcDir 'src\version.h') -Raw
        $parts = foreach ($m in 'MAJOR', 'MINOR', 'PATCH') {
            if ($vh -notmatch "#define\s+MPG123_$m\s+(\d+)") { throw "No MPG123_$m in src\version.h." }
            $Matches[1]
        }
        $sourceVersion = $parts -join '.'
        if ($sourceVersion -ne $s.Version) { throw "mpg123 source declares version $sourceVersion but deps.json says $($s.Version)." }

        # The decoder only, as a DLL: the in tree build was a DLL too, and mod_shout
        # uses nothing else from this package.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $cmakeSrc)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=ON',
            '-DBUILD_LIBOUT123=OFF',
            '-DBUILD_PROGRAMS=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        # One phase per batch: each prints its output when it ends, so a stall is
        # visible at the phase that never reported.
        $phases = @(
            @{ name = 'configure'; cmd = "cmake $($configureArgs -join ' ')" },
            @{ name = 'build';     cmd = "cmake --build `"$bldDir`"" },
            @{ name = 'install';   cmd = "cmake --install `"$bldDir`"" }
        )
        foreach ($phase in $phases) {
            Write-Host "-- $($phase.name) ..."
            $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
$($phase.cmd) || exit /b 1
"@
            $log = Join-Path $s.OutDir "build-$plat-$config-$($phase.name).log"
            Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work "$($phase.name).bat") -LogFile $log -Label "mpg123 $($phase.name) [$plat/$config]"
        }

        # --- verify --------------------------------------------------------------
        $dll = Join-Path $insDir 'bin\mpg123.dll'
        $imp = Join-Path $insDir 'lib\mpg123.lib'
        foreach ($f in $dll, $imp, (Join-Path $insDir 'include\mpg123.h'), (Join-Path $insDir 'include\fmt123.h')) {
            if (-not (Test-Path $f)) { throw "mpg123 [$plat/$config] did not install $(Split-Path -Leaf $f)." }
        }

        # Everything mod_shout calls.
        $expFile = Join-Path $work "exports-$config.txt"
        $dump = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
dumpbin /nologo /exports "$dll" > "$expFile" || exit /b 1
"@
        Invoke-BuildBatch -Script $dump -BatchFile (Join-Path $work 'dump.bat') -LogFile (Join-Path $work 'dump.log') -Label "mpg123 exports [$plat/$config]"
        $exports = Get-Content $expFile -Raw
        foreach ($sym in 'mpg123_init', 'mpg123_new', 'mpg123_delete', 'mpg123_exit',
                         'mpg123_open_feed', 'mpg123_feed', 'mpg123_decode', 'mpg123_read',
                         'mpg123_getformat', 'mpg123_format_none', 'mpg123_format',
                         'mpg123_param', 'mpg123_plain_strerror', 'mpg123_strerror', 'mpg123_close') {
            if ($exports -notmatch "\b$sym\b") { throw "mpg123.dll does not export $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $dll, $imp -Destination $binDst
        Copy-Item (Join-Path $srcDir 'COPYING') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# mpg123.h and fmt123.h are generated by the CMake run, so they come from the
# install tree rather than the source.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($h in 'mpg123.h', 'fmt123.h') {
    Copy-Item (Join-Path $headerInstall "include\$h") -Destination $incDst
}
Copy-Item (Join-Path $licenseSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
$h = Get-Content (Join-Path $incDst 'mpg123.h') -Raw
if ($h -notmatch '\bmpg123_open_feed\b') { throw "include\mpg123.h is not the public API header." }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "cmake: $cmakeVersion",
               "library: mpg123.dll + mpg123.lib (import library)",
               "built: libmpg123 only; no libout123, no programs")
Write-PackageSummary $s
