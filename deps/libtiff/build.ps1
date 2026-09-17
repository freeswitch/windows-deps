<#
.SYNOPSIS
    libtiff: builds the static tiff.lib with CMake + the Visual C++ toolchain and
    packages it for FreeSWITCH's w32\tiff.props. The consumer is spandsp's fax
    code (T.4/T.6 page files), through libspandsp, mod_spandsp and FreeSwitchCore.

    FreeSWITCH used to build this in tree: w32\download_tiff.props fetched
    tiff-<version>.tar.gz from files.freeswitch.org and
    libs\win32\libtiff\libtiff.2017.vcxproj compiled a hand kept list of 36
    sources, copying tif_config.vc.h / tiffconf.vc.h into place first. 4.7.x has
    neither of those files any more -- CMake generates tif_config.h and
    tiffconf.h -- so this node drives upstream's own CMake build instead.

    Codecs match what the in tree project defined: CCITT (what fax needs),
    PackBits, LZW, ThunderScan, NeXT and LogLuv. Everything that needs a third
    party library stays off, exactly as before -- the old project compiled
    tif_zip.c, tif_jpeg.c, tif_ojpeg.c and tif_pixarlog.c but never defined
    ZIP_SUPPORT or JPEG_SUPPORT, so those codecs were inert. That keeps the node
    free of dependencies.

    Upstream's cmake\WindowsSupport.cmake sets CMAKE_DEBUG_POSTFIX with a plain
    set(), which a -D on the command line cannot override, so the debug library
    keeps its own name: tiff.lib in release, tiffd.lib in debug. tiff.props picks
    the name from $(LibraryConfiguration), the way opencv.props does for
    opencv_world4100d.

    Package <pkg> = libtiff-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE.md
                                              <pkg>/include/{tiff.h, tiffio.h,
                                                             tiffvers.h, tiffconf.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE.md
                                              <pkg>/binaries/<Platform>/<Config>/tiff[d].lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBTIFF_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBTIFF_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libtiff'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

$cmakeCmd = Get-Command cmake -ErrorAction Stop
$cmakeVersion = (& cmake --version | Select-Object -First 1)

Write-Host "==================================================================="
Write-Host " libtiff         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "libtiff-v$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libtiff $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "libtiff-v$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $srcDir 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\[LibTIFF Software\],\[([0-9][0-9.]*)\]') {
            if ($Matches[1] -ne $s.Version) { throw "libtiff source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # Static library only, the shape the in tree build had. Internal codecs on,
        # every external one off; no tools, tests, contrib, docs or C++ stream API.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=OFF',
            '-Dccitt=ON',
            '-Dpackbits=ON',
            '-Dlzw=ON',
            '-Dthunder=ON',
            '-Dnext=ON',
            '-Dlogluv=ON',
            '-Dzlib=OFF',
            '-Dlibdeflate=OFF',
            '-Dpixarlog=OFF',
            '-Djpeg=OFF',
            '-Dold-jpeg=OFF',
            '-Djbig=OFF',
            '-Dlzma=OFF',
            '-Dzstd=OFF',
            '-Dwebp=OFF',
            '-Dlerc=OFF',
            '-Dtiff-tools=OFF',
            '-Dtiff-tests=OFF',
            '-Dtiff-contrib=OFF',
            '-Dtiff-docs=OFF',
            '-Dtiff-cxx=OFF'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libtiff build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        $libName = if ($config -eq 'Debug') { 'tiffd.lib' } else { 'tiff.lib' }
        $lib = Join-Path $insDir "lib\$libName"
        foreach ($f in "lib\$libName", 'include\tiff.h', 'include\tiffio.h', 'include\tiffvers.h', 'include\tiffconf.h') {
            if (-not (Test-Path (Join-Path $insDir $f))) { throw "libtiff [$plat/$config] did not install $f." }
        }

        # Everything spandsp's fax code calls, the custom directory and tag
        # extender entry points included.
        $symFile = Join-Path $work "symbols-$config.txt"
        $dump = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$symFile" || exit /b 1
"@
        Invoke-BuildBatch -Script $dump -BatchFile (Join-Path $work 'dump.bat') -LogFile (Join-Path $work 'dump.log') -Label "libtiff symbols [$plat/$config]"
        $syms = Get-Content $symFile -Raw
        foreach ($sym in 'TIFFOpen', 'TIFFClose', 'TIFFClientOpen', 'TIFFSetField', 'TIFFGetField',
                         'TIFFWriteDirectory', 'TIFFCheckpointDirectory', 'TIFFSetDirectory',
                         'TIFFCreateCustomDirectory', 'TIFFReadCustomDirectory', 'TIFFWriteCustomDirectory',
                         'TIFFMergeFieldInfo', 'TIFFSetTagExtender', 'TIFFNumberOfStrips', 'TIFFRawStripSize',
                         'TIFFReadEncodedStrip', 'TIFFWriteEncodedStrip', 'TIFFReadRawStrip', 'TIFFWriteRawStrip',
                         'TIFFReadScanline', 'TIFFScanlineSize') {
            if ($syms -notmatch "\b$sym\b") { throw "$libName does not contain $sym -- the build configuration is wrong." }
        }
        # CCITT G3/G4 is what fax writes; make sure that codec really went in.
        if ($syms -notmatch '\bTIFFInitCCITTFax4\b') { throw "$libName has no CCITT codec -- -Dccitt=ON did not take." }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $srcDir 'LICENSE.md') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# The four public headers upstream installs; tiffconf.h and tiffvers.h are generated
# by the CMake run, which is why they come from the install tree and not the source.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerInstall 'include\*.h') -Destination $incDst
Copy-Item (Join-Path $licenseSrc 'LICENSE.md') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'tiff.h', 'tiffio.h', 'tiffvers.h', 'tiffconf.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
$vers = Get-Content (Join-Path $incDst 'tiffvers.h') -Raw
if ($vers -notmatch [regex]::Escape($s.Version)) { throw "tiffvers.h does not mention $($s.Version)." }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "cmake: $cmakeVersion", "library: tiff.lib (static)",
               "codecs: CCITT, PackBits, LZW, ThunderScan, NeXT, LogLuv; no zlib, jpeg, jbig, lzma, zstd, webp or lerc")
Write-PackageSummary $s
