<#
.SYNOPSIS
    FreeType: builds the static freetype.lib with CMake + the Visual C++ toolchain
    and packages it for FreeSWITCH's w32\freetype.props. The consumer is
    FreeSwitchCore, whose switch_core_video.c draws text onto video frames with it.

    FreeSWITCH built this in tree: w32\download_freetype.props fetched an unversioned
    freetype.tar.bz2 (2.7.0) from files.freeswitch.org and
    libs\win32\freetype\freetype.2017.vcxproj compiled 39 of its files. This node
    builds 2.14.3 from the release freetype.org links to, with upstream's own CMake
    build -- the module list moved on since 2.7.0 (sdf, for one), and CMake is what
    writes ftoption.h to match the options chosen.

    Static library only, the shape the in tree build had, and like it with no
    external libraries: zlib, bzip2, libpng, HarfBuzz and Brotli are all disabled.
    FT_DISABLE_ZLIB turns off the system zlib, not gzip support: FreeType then
    compiles the copy of zlib it carries in src\gzip -- what it inflates .pcf.gz
    bitmap fonts with -- which is also what the in tree build did.
    switch_core_video.c renders outline fonts through FT_Load_Char with
    FT_LOAD_RENDER and needs nothing more.

    Upstream appends a d to the debug library unless DISABLE_FORCE_DEBUG_POSTFIX
    is set; it is, so the library is freetype.lib in both configurations, the way
    every other package here names its library once.

    Package <pkg> = freetype-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/{LICENSE.TXT, FTL.TXT, GPLv2.TXT}
                                              <pkg>/include/{ft2build.h, freetype\...}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/{LICENSE.TXT, FTL.TXT, GPLv2.TXT}
                                              <pkg>/binaries/<Platform>/<Config>/freetype.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    FreeType is dual licensed, FTL or GPLv2 at the user's choice; LICENSE.TXT says
    so and both texts go in.

    Environment (all optional): FREETYPE_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, FREETYPE_URL, EXTRA_CMAKE.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'freetype'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

$cmakeCmd = Get-Command cmake -ErrorAction Stop
$cmakeVersion = (& cmake --version | Select-Object -First 1)

Write-Host "==================================================================="
Write-Host " freetype        : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "freetype-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerInstall = $null
$licenseSrc    = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building freetype $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "freetype-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        $insDir = Join-Path $work 'install'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version freetype.h declares must match the manifest.
        $fh = Get-Content (Join-Path $srcDir 'include\freetype\freetype.h') -Raw
        $ver = foreach ($part in 'MAJOR', 'MINOR', 'PATCH') {
            if ($fh -notmatch "#define\s+FREETYPE_$part\s+([0-9]+)") { throw "freetype.h defines no FREETYPE_$part." }
            $Matches[1]
        }
        if (($ver -join '.') -ne $s.Version) { throw "freetype.h declares $($ver -join '.') but deps.json says $($s.Version)." }

        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $insDir)`"",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DDISABLE_FORCE_DEBUG_POSTFIX=ON',
            '-DFT_DISABLE_ZLIB=ON',
            '-DFT_DISABLE_BZIP2=ON',
            '-DFT_DISABLE_PNG=ON',
            '-DFT_DISABLE_HARFBUZZ=ON',
            '-DFT_DISABLE_BROTLI=ON'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "freetype build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        $libName = 'freetype.lib'
        $lib = Join-Path $insDir "lib\$libName"
        foreach ($f in "lib\$libName", 'include\freetype2\ft2build.h', 'include\freetype2\freetype\freetype.h',
                       'include\freetype2\freetype\config\ftoption.h') {
            if (-not (Test-Path (Join-Path $insDir $f))) { throw "freetype [$plat/$config] did not install $f." }
        }
        # The options really went in: nothing from outside is configured in.
        $opt = Get-Content (Join-Path $insDir 'include\freetype2\freetype\config\ftoption.h') -Raw
        foreach ($o in 'FT_CONFIG_OPTION_SYSTEM_ZLIB', 'FT_CONFIG_OPTION_USE_BZIP2', 'FT_CONFIG_OPTION_USE_PNG',
                       'FT_CONFIG_OPTION_USE_HARFBUZZ', 'FT_CONFIG_OPTION_USE_BROTLI') {
            if ($opt -match "(?m)^\s*#\s*define\s+$o\b") { throw "ftoption.h still defines $o." }
        }

        # What switch_core_video.c calls, plus the version query the test uses.
        $symFile = Join-Path $work "symbols-$config.txt"
        $dump = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$symFile" || exit /b 1
"@
        Invoke-BuildBatch -Script $dump -BatchFile (Join-Path $work 'dump.bat') -LogFile (Join-Path $work 'dump.log') -Label "freetype symbols [$plat/$config]"
        $syms = Get-Content $symFile -Raw
        foreach ($sym in 'FT_Init_FreeType', 'FT_Done_FreeType', 'FT_New_Face', 'FT_Done_Face', 'FT_Set_Char_Size',
                         'FT_Set_Transform', 'FT_Load_Char', 'FT_Library_Version') {
            if ($syms -notmatch "\b$sym\b") { throw "$libName does not contain $sym." }
        }
        # gzip support is still in, through the bundled zlib.
        if ($syms -notmatch '\bFT_Stream_OpenGzip\b') { throw "$libName has no gzip support -- the bundled zlib did not go in." }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        foreach ($l in 'LICENSE.TXT', 'docs\FTL.TXT', 'docs\GPLv2.TXT') { Copy-Item (Join-Path $srcDir $l) -Destination $pkgRoot }
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerInstall) { $headerInstall = $insDir; $licenseSrc = $srcDir }
    }
}

# --- headers zip -------------------------------------------------------------------
# What CMake installs under include\freetype2 -- ft2build.h and the freetype\ tree,
# with the ftoption.h written for the options above -- flattened to include\, so
# the include directory is the one #include <ft2build.h> expects.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerInstall 'include\freetype2\*') -Destination $incDst -Recurse
foreach ($l in 'LICENSE.TXT', 'docs\FTL.TXT', 'docs\GPLv2.TXT') { Copy-Item (Join-Path $licenseSrc $l) -Destination $hdrRoot }
foreach ($must in 'ft2build.h', 'freetype\freetype.h', 'freetype\ftglyph.h', 'freetype\config\ftoption.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "cmake: $cmakeVersion", "library: freetype.lib (static)",
               "options: no system zlib (bundled copy for gzip), no bzip2, libpng, HarfBuzz or Brotli")
Write-PackageSummary $s
