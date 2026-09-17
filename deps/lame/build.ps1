<#
.SYNOPSIS
    LAME: builds the static libmp3lame.lib (the MP3 encoder mod_shout uses) with
    the Visual C++ toolchain and packages it for FreeSWITCH's w32\lame.props.

    FreeSWITCH used to build this in tree: w32\download_LAME.props fetched
    lame-3.98.4-1.tar.gz from files.freeswitch.org and
    libs\win32\libmp3lame\libmp3lame.2017.vcxproj compiled it against a copy of
    LAME's own configMS.h checked in as libs\win32\libmp3lame\config.h. This node
    does the same compilation from upstream's 3.101 release and ships the result
    as a package instead.

    The file list is upstream's own libmp3lame_la_SOURCES from
    libmp3lame\Makefile.am, and config.h is upstream's configMS.h copied into the
    source root -- the step its own vc_solution\vs2019_libmp3lame.vcxproj performs.
    Nothing else goes in: no NASM assembly (HAVE_NASM off), no vector routines and
    no mpglib decoder, the same shape the in tree project had. mod_shout only
    encodes with LAME -- it decodes through mpg123 -- so mpglib_interface.c
    compiles to nothing without HAVE_MPGLIB, exactly as before.

    Package <pkg> = lame-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/lame/lame.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/libmp3lame.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    mod_shout includes <lame.h> on Windows and <lame/lame.h> elsewhere; upstream
    installs the header as $(includedir)/lame/lame.h, so the package keeps that
    layout and the property sheet puts both include\ and include\lame\ on the
    include path, which satisfies either spelling.

    Environment (all optional): LAME_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LAME_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'lame'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " lame            : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "lame-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libmp3lame $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "lame-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
        $src = Join-Path $root 'libmp3lame'

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $root 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\[lame\],\[([0-9][0-9.]*)\]') {
            if ($Matches[1] -ne $s.Version) { throw "LAME source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # LAME keeps its version macros in the private header, not in lame.h.
        $vh = Get-Content (Join-Path $src 'version.h') -Raw
        $want = $s.Version -split '\.'
        if ($vh -notmatch "LAME_MAJOR_VERSION\s+$($want[0])\b" -or $vh -notmatch "LAME_MINOR_VERSION\s+$($want[1])\b") {
            throw "version.h does not declare $($s.Version)."
        }

        # config.h is upstream's configMS.h, the copy its own MSVC project makes.
        Copy-Item (Join-Path $root 'configMS.h') -Destination (Join-Path $root 'config.h') -Force

        # Source list straight out of upstream's Makefile.am.
        $mk = (Get-Content (Join-Path $src 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
        if ($mk -notmatch '(?m)^libmp3lame_la_SOURCES\s*=\s*([^\r\n]*)$') { throw "No libmp3lame_la_SOURCES in libmp3lame\Makefile.am." }
        $names = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.c' })
        if ($names.Count -lt 18) { throw "Only $($names.Count) sources listed in Makefile.am -- the tree layout changed." }
        # On x64 configMS.h defines HAVE_XMMINTRIN_H, so quantize.c reaches for
        # init_xrpow_core_sse; it lives in vector\, which upstream's Makefile.am keeps
        # in its own convenience library and its MSVC project compiles alongside.
        $vec = (Get-Content (Join-Path $src 'vector\Makefile.am') -Raw) -replace '\\\r?\n', ' '
        if ($vec -notmatch '(?m)^xmm_sources\s*=\s*([^\r\n]*)$') { throw "No xmm_sources in libmp3lame\vector\Makefile.am." }
        $names += @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.c' } | ForEach-Object { "vector\$_" })
        $sources = foreach ($n in $names) {
            $p = Join-Path $src ($n -replace '/', '\')
            if (-not (Test-Path $p)) { throw "'$n' is listed in Makefile.am but missing." }
            $p
        }
        $dupes = $sources | Group-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $_.Count -gt 1 }
        if ($dupes) { throw "Duplicate source file names: $(($dupes | ForEach-Object { $_.Name }) -join ', ')." }
        Write-Host ("sources: {0} files" -f $sources.Count)

        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The same knobs the in tree vcxproj used.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $inc = @('.', 'include', 'libmp3lame') | ForEach-Object { "/I`"$(Join-Path $root $_)`"" }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_WINDOWS /DHAVE_CONFIG_H $extraCFlags",
                   ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libmp3lame.lib'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "lame build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        # Everything mod_shout calls.
        if (-not (Test-Path $lib)) { throw "lame [$plat/$config] did not produce libmp3lame.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'lame_init', 'lame_init_params', 'lame_close', 'lame_encode_buffer',
                         'lame_encode_buffer_interleaved', 'lame_encode_flush', 'lame_get_framesize',
                         'lame_print_config', 'lame_set_brate', 'lame_set_in_samplerate',
                         'lame_set_out_samplerate', 'lame_set_num_channels', 'lame_set_mode',
                         'lame_set_quality', 'lame_set_disable_reservoir',
                         'lame_set_errorf', 'lame_set_debugf', 'lame_set_msgf') {
            if ($syms -notmatch "\b$sym\b") { throw "libmp3lame.lib does not contain $sym -- the source selection is wrong." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'COPYING') -Destination $pkgRoot -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $root }
    }
}

# --- headers zip -------------------------------------------------------------------
# Upstream's pkginclude_HEADERS, under the include\lame\ its install uses.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\lame'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerSrc 'include\lame.h') -Destination $incDst
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $incDst 'lame.h'))) { throw "Headers package is missing include\lame\lame.h." }
$h = Get-Content (Join-Path $incDst 'lame.h') -Raw
if ($h -notmatch '\blame_encode_buffer\b') { throw "include\lame\lame.h is not the public API header." }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libmp3lame.lib (static)",
               "features: MP3 encoder, /MD; no NASM, no vector routines, no mpglib decoder")
Write-PackageSummary $s
