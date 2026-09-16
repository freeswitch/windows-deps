<#
.SYNOPSIS
    OpenCV: builds the single opencv_world DLL with CMake + the Visual C++
    toolchain and packages it the way FreeSWITCH's w32\opencv.props expects (the
    layout files.freeswitch.org served; consumer: mod_cv).

    Like the 3.4.1 packages before it, this is a world build: one DLL, one import
    library, the whole include tree. mod_cv still uses a few pieces of OpenCV's
    legacy C API (IplImage, cvCreateImage, cvPoint, highgui_c.h); 4.x keeps all of
    them, but it no longer ships the old include\opencv\ directory, so the
    property sheet points at include\opencv2\opencv.hpp instead of opencv\cv.h.

    Nothing is downloaded during the build: IPP (ippicv) and FFmpeg both pull
    prebuilt binaries from opencv_3rdparty at configure time, so both are off.
    Bindings, tests, apps and samples are off as well; gapi is off because it did
    not exist in the packages this replaces.

    Package <pkg> = opencv-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/opencv2/**
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/bin/opencv_world<ver>[d].dll
                                                                             /lib/opencv_world<ver>[d].lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): OPENCV_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, OPENCV_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'opencv'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.22) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " opencv          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "opencv-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building OpenCV $($s.Version)  [$plat / $config]  (NMake Makefiles, world DLL)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "opencv-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version upstream's version.hpp declares must match the manifest.
        $vh = Get-Content (Join-Path $srcDir 'modules\core\include\opencv2\core\version.hpp') -Raw -ErrorAction SilentlyContinue
        $parts = foreach ($k in 'MAJOR', 'MINOR', 'REVISION') {
            if ($vh -match "(?m)^#define CV_VERSION_$k\s+(\d+)") { $Matches[1] } else { $null }
        }
        if ($parts -notcontains $null) {
            $srcVer = $parts -join '.'
            if ($srcVer -ne $s.Version) { throw "OpenCV source declares version $srcVer but deps.json says $($s.Version)." }
            $worldBase = 'opencv_world' + ($parts -join '')
        } else {
            throw "Could not read CV_VERSION_* from modules\core\include\opencv2\core\version.hpp."
        }
        $worldName = if ($config -eq 'Debug') { "${worldBase}d" } else { $worldBase }
        Write-Host "world library  : $worldName.dll / .lib"

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=ON',
            # OpenCV 4.10 still asks for cmake_minimum_required(VERSION 3.1) and CMake 4
            # refuses anything below 3.5; this is the documented way to accept it.
            '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
            '-DBUILD_opencv_world=ON',
            # nothing that fetches a prebuilt binary at configure time
            '-DWITH_IPP=OFF',
            '-DWITH_FFMPEG=OFF',
            # Camera capture backends drag in APIs that only exist on a desktop
            # Windows: Media Foundation and Direct3D here, Video for Windows in the
            # 3.4.1 packages. FreeSWITCH feeds mod_cv its own frames and never opens a
            # capture device, so the DLL is better off without them (and then it also
            # loads on Server Core, where those DLLs are absent).
            '-DWITH_MSMF=OFF',
            '-DWITH_DSHOW=OFF',
            '-DWITH_DIRECTX=OFF',
            # the Orbbec depth sensor backend uses Media Foundation of its own accord,
            # regardless of WITH_MSMF
            '-DWITH_OBSENSOR=OFF',
            # not part of the packages this replaces / not usable from a world DLL
            '-DBUILD_opencv_gapi=OFF',
            '-DBUILD_opencv_python2=OFF',
            '-DBUILD_opencv_python3=OFF',
            '-DBUILD_opencv_java=OFF',
            '-DBUILD_opencv_js=OFF',
            '-DBUILD_opencv_apps=OFF',
            '-DBUILD_TESTS=OFF',
            '-DBUILD_PERF_TESTS=OFF',
            '-DBUILD_EXAMPLES=OFF',
            '-DBUILD_DOCS=OFF',
            '-DINSTALL_TESTS=OFF',
            '-DINSTALL_C_EXAMPLES=OFF',
            '-DINSTALL_PYTHON_EXAMPLES=OFF',
            '-DOPENCV_GENERATE_SETUPVARS=OFF'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "opencv build [$plat/$config]"

        # --- collect --------------------------------------------------------------
        # OpenCV installs into <prefix>\<arch>\vc<n>\{bin,lib} on Windows, so the two
        # files are located by name rather than by a hard coded path.
        $dll = Get-ChildItem -Recurse -File $insDir -Filter "$worldName.dll" | Select-Object -First 1
        $lib = Get-ChildItem -Recurse -File $insDir -Filter "$worldName.lib" | Select-Object -First 1
        if (-not $dll) { throw "opencv [$plat/$config] did not install $worldName.dll." }
        if (-not $lib) { throw "opencv [$plat/$config] did not install $worldName.lib." }
        $incSrc = Get-ChildItem -Recurse -Directory $insDir | Where-Object { Test-Path (Join-Path $_.FullName 'opencv2\opencv.hpp') } | Select-Object -First 1
        if (-not $incSrc) { throw "No installed include directory with opencv2\opencv.hpp found under '$insDir'." }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path (Join-Path $binDst 'bin'), (Join-Path $binDst 'lib') | Out-Null
        Copy-Item $dll.FullName -Destination (Join-Path $binDst 'bin')
        Copy-Item $lib.FullName -Destination (Join-Path $binDst 'lib')
        if ($config -eq 'Debug') {
            $pdb = Get-ChildItem -Recurse -File $bldDir -Filter "$worldName.pdb" | Select-Object -First 1
            if ($pdb) { Copy-Item $pdb.FullName -Destination (Join-Path $binDst 'bin') }
        }
        Copy-Item (Join-Path $srcDir 'LICENSE') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $incSrc.FullName; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item -Path (Join-Path $headerInstall '*') -Destination $incDst -Recurse -Force
Copy-Item (Join-Path $licenseSrc 'LICENSE') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'opencv2\opencv.hpp', 'opencv2\core.hpp', 'opencv2\core\core_c.h', 'opencv2\core\types_c.h',
                  'opencv2\highgui\highgui_c.h', 'opencv2\objdetect.hpp', 'opencv2\imgproc.hpp') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must (mod_cv needs it)." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)",
               "features: world DLL, no IPP, no FFmpeg, no gapi, no video capture backends (MSMF/DShow/DirectX/obsensor), no bindings/tests/apps, /MD")
Write-PackageSummary $s
