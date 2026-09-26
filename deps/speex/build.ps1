<#
.SYNOPSIS
    Speex: builds the static libspeex.lib (the Speex codec) with the Visual C++
    toolchain and packages it for FreeSWITCH's w32\speex.props. The consumer is
    FreeSwitchCore, whose switch_speex.c is the built in Speex codec.

    FreeSWITCH built this in tree: w32\download_speex.props fetched
    speex-1.2rc1.tar.gz from files.freeswitch.org and
    libs\win32\speex\libspeex.2017.vcxproj compiled it. This node builds 1.2.1
    from Xiph's own tag. Since 1.2.0 the DSP half -- resampler, preprocessor,
    echo canceller, jitter buffer -- lives in SpeexDSP, which the tree builds
    from its own sources; this package is the codec alone.

    What goes in is upstream's own file list, libspeex_la_SOURCES in
    libspeex\Makefile.am, without the optional Vorbis psychoacoustic model
    (VPSY_SOURCE and the FFT it pulls in), which configure leaves out unless
    asked. That is also the file set the in tree project compiled. config.h is
    upstream's win32\config.h. The version string comes from libspeex\arch.h,
    which defines it when configure has not.

    The solution maps that project's Debug|x64 and Release|x64 to its static
    configurations, so the package is a static library, built with the same
    knobs: /MD, WIN32, _LIB, HAVE_CONFIG_H.

    Package <pkg> = speex-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/speex/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/libspeex.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): SPEEX_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, SPEEX_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'speex'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " speex           : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " Extra cflags    : $extraCFlags"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tarball = Join-Path $s.BuildRoot "speex-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = (Get-ChildItem $srcParent -Directory | Select-Object -First 1)
if (-not $root) { throw "The tag archive did not expand to a directory." }
$root = $root.FullName
$lib_src = Join-Path $root 'libspeex'
foreach ($must in 'configure.ac', 'COPYING', 'win32\config.h', 'libspeex\Makefile.am', 'libspeex\arch.h', 'include\speex\speex.h') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}

# The version must agree in both places upstream keeps it.
$ac = Get-Content (Join-Path $root 'configure.ac') -Raw
if ($ac -notmatch 'AC_INIT\(\[speex\],\s*\[([0-9][0-9.]*)\]') { throw "configure.ac has no AC_INIT version." }
if ($Matches[1] -ne $s.Version) { throw "configure.ac declares $($Matches[1]) but deps.json says $($s.Version)." }
$arch = Get-Content (Join-Path $lib_src 'arch.h') -Raw
if ($arch -notmatch '#define\s+SPEEX_VERSION\s+"speex-([0-9][0-9.]*)"') { throw "libspeex\arch.h defines no SPEEX_VERSION." }
if ($Matches[1] -ne $s.Version) { throw "libspeex\arch.h says speex-$($Matches[1]) but deps.json says $($s.Version)." }
Write-Host "configure.ac and libspeex\arch.h declare $($s.Version)"

# --- source list, upstream's own ---------------------------------------------------
# libspeex_la_SOURCES minus $(VPSY_SOURCE) and $(FFTSRC), which configure only
# fills in for the Vorbis psychoacoustic model.
$mk = (Get-Content (Join-Path $lib_src 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
if ($mk -notmatch '(?m)^libspeex_la_SOURCES\s*=\s*([^\r\n]*)$') { throw "No libspeex_la_SOURCES in libspeex\Makefile.am." }
$names = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.c' })
if ($names.Count -lt 25) { throw "Only $($names.Count) sources listed in libspeex\Makefile.am -- the tree layout changed." }
$sources = foreach ($n in $names) {
    $p = Join-Path $lib_src $n
    if (-not (Test-Path $p)) { throw "'$n' is listed in libspeex\Makefile.am but missing." }
    $p
}
Write-Host ("sources: {0} files" -f $sources.Count)

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libspeex.lib $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The same knobs the in tree vcxproj used for its static configurations.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $inc = @('win32', 'include') | ForEach-Object { "/I`"$(Join-Path $root $_)`"" }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_LIB /DHAVE_CONFIG_H $extraCFlags",
                   ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libspeex.lib'
        $objects = $sources | ForEach-Object { Join-Path $objDir ([System.IO.Path]::GetFileNameWithoutExtension($_) + '.obj') }
        $libRsp = @('/nologo', "/OUT:`"$lib`"") + ($objects | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'lib.rsp') -Value $libRsp -Encoding ASCII

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cl @"$(Join-Path $work 'cl.rsp')" || exit /b 1
lib @"$(Join-Path $work 'lib.rsp')" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "speex build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "speex [$plat/$config] did not produce libspeex.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        # What switch_speex.c takes from the library, the three mode tables included.
        foreach ($sym in 'speex_encoder_init', 'speex_encoder_ctl', 'speex_encoder_destroy',
                         'speex_encode', 'speex_encode_int', 'speex_decoder_init', 'speex_decoder_ctl',
                         'speex_decoder_destroy', 'speex_decode', 'speex_decode_int', 'speex_bits_init',
                         'speex_bits_reset', 'speex_bits_pack', 'speex_bits_write', 'speex_bits_read_from',
                         'speex_bits_destroy', 'speex_nb_mode', 'speex_wb_mode', 'speex_uwb_mode', 'speex_lib_ctl') {
            if ($syms -notmatch "\b$sym\b") { throw "libspeex.lib does not contain $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'COPYING') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))
    }
}

# --- headers zip -------------------------------------------------------------------
# Upstream's pkginclude_HEADERS. speex_config_types.h, the one configure
# generates, is left out: speex_types.h never includes it for Visual C++.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\speex'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
$hmk = (Get-Content (Join-Path $root 'include\speex\Makefile.am') -Raw) -replace '\\\r?\n', ' '
if ($hmk -notmatch '(?m)^pkginclude_HEADERS\s*=\s*([^\r\n]*)$') { throw "No pkginclude_HEADERS in include\speex\Makefile.am." }
$headers = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.h' })
foreach ($h in $headers) {
    $p = Join-Path $root "include\speex\$h"
    if (-not (Test-Path $p)) { throw "'$h' is listed in include\speex\Makefile.am but missing." }
    Copy-Item $p -Destination $incDst
}
Copy-Item (Join-Path $root 'COPYING') -Destination $hdrRoot
foreach ($must in 'speex.h', 'speex_bits.h', 'speex_types.h', 'speex_header.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\speex\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libspeex.lib (static)",
               "features: Speex codec (narrowband, wideband, ultra-wideband), floating point, /MD")
Write-PackageSummary $s
