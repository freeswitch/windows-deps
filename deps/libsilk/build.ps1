<#
.SYNOPSIS
    libsilk: builds the static libsilk.lib (the SILK SDK mod_silk uses) with the
    Visual C++ toolchain and packages it for FreeSWITCH's w32\libsilk.props.

    FreeSWITCH used to build this in tree: w32\download_libsilk.props fetched
    libsilk-<version>.tar.gz from files.freeswitch.org and
    libs\win32\libsilk\Silk_FIX.2017.vcxproj compiled it. This node does the same
    compilation, from the GitHub release of freeswitch/libsilk, and ships the
    result as a package instead. The file list is upstream's own
    libSKP_SILK_SDK_la_SOURCES from Makefile.am, which holds the same 109 files
    that project listed -- 1.0.9 only renamed SKP_Silk_apply_sine_window_new.c
    back to SKP_Silk_apply_sine_window.c.

    The library is a plain static one: the SDK headers declare no dllimport or
    dllexport, so a consumer needs no special define. The in tree project called
    the output Silk_FIX.lib; the package names it after the package.

    Package <pkg> = libsilk-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/silk/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/libsilk.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    The headers are upstream's library_include_HEADERS, so the four interface\
    headers mod_silk compiles against plus the src\ headers upstream installs
    alongside them, all under include\silk\ the way its autotools install does.
    mod_silk writes #include "SKP_Silk_SDK_API.h", so the property sheet puts
    both include\ and include\silk\ on the include path.

    Environment (all optional): LIBSILK_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBSILK_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libsilk'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libsilk         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "libsilk-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libsilk $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "libsilk-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $root 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\s*\[?libSKP_SILK_SDK\]?,\s*\[?([0-9][0-9.]*)\]?') {
            if ($Matches[1] -ne $s.Version) { throw "libsilk source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # Source list straight out of upstream's Makefile.am.
        $mk = (Get-Content (Join-Path $root 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
        if ($mk -notmatch '(?m)^libSKP_SILK_SDK_la_SOURCES\s*=\s*([^\r\n]*)$') { throw "No libSKP_SILK_SDK_la_SOURCES in Makefile.am." }
        $names = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.c' })
        if ($names.Count -lt 100) { throw "Only $($names.Count) sources listed in Makefile.am -- the tree layout changed." }
        $sources = foreach ($n in $names) {
            $p = Join-Path $root ($n -replace '/', '\')
            if (-not (Test-Path $p)) { throw "'$n' is listed in Makefile.am but missing." }
            $p
        }
        $dupes = $sources | Group-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $_.Count -gt 1 }
        if ($dupes) { throw "Duplicate source file names: $(($dupes | ForEach-Object { $_.Name }) -join ', ')." }
        Write-Host ("sources: {0} files" -f $sources.Count)

        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The same knobs the in tree vcxproj used: a static lib against the DLL CRT,
        # with src\ and interface\ on the include path.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $inc = @('src', 'interface') | ForEach-Object { "/I`"$(Join-Path $root $_)`"" }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_LIB $extraCFlags",
                   ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libsilk.lib'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libsilk build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        # Everything mod_silk calls.
        if (-not (Test-Path $lib)) { throw "libsilk [$plat/$config] did not produce libsilk.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'SKP_Silk_SDK_Get_Encoder_Size', 'SKP_Silk_SDK_InitEncoder', 'SKP_Silk_SDK_Encode',
                         'SKP_Silk_SDK_Get_Decoder_Size', 'SKP_Silk_SDK_InitDecoder', 'SKP_Silk_SDK_Decode',
                         'SKP_Silk_SDK_search_for_LBRR') {
            if ($syms -notmatch "\b$sym\b") { throw "libsilk.lib does not contain $sym -- the source selection is wrong." }
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
# Upstream's library_include_HEADERS, under the include\silk\ its install uses.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\silk'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
$mk = (Get-Content (Join-Path $headerSrc 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
if ($mk -notmatch '(?m)^library_include_HEADERS\s*=\s*([^\r\n]*)$') { throw "No library_include_HEADERS in Makefile.am." }
$headers = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.h' })
foreach ($h in $headers) {
    $p = Join-Path $headerSrc ($h -replace '/', '\')
    if (-not (Test-Path $p)) { throw "'$h' is listed in Makefile.am but missing." }
    Copy-Item $p -Destination $incDst
}
Write-Host ("headers: {0} files" -f $headers.Count)
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'SKP_Silk_SDK_API.h', 'SKP_Silk_control.h', 'SKP_Silk_errors.h', 'SKP_Silk_typedef.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\silk\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libsilk.lib (static, Silk_FIX.lib in the old in tree build)",
               "features: SILK SDK fixed point encoder + decoder, /MD")
Write-PackageSummary $s
