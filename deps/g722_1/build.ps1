<#
.SYNOPSIS
    libg722_1: builds the static libg722_1.lib (the G.722.1 / Siren codec mod_siren
    uses) with the Visual C++ toolchain and packages it for FreeSWITCH's
    w32\g722_1.props.

    FreeSWITCH used to build this in tree: w32\download_g722_1.props fetched
    g722_1-<version>.tar.gz from files.freeswitch.org and
    libs\win32\libg722_1\libg722_1.2017.vcxproj compiled it. This node does the same
    compilation, from the GitHub release of freeswitch/libg7221, and ships the
    result as a package instead. The file list is upstream's own
    libg722_1_la_SOURCES from src\Makefile.am plus msvc\gettimeofday.c, which its
    WIN32SOURCES adds for this platform.

    The library is a plain static one: its public header declares no dllimport or
    dllexport, so a consumer needs no special define.

    Package <pkg> = g722_1-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/g722_1/{g722_1.h, version.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/libg722_1.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    mod_siren includes "g722_1.h", which is include\g722_1\g722_1.h: the property
    sheet puts both include\ and include\g722_1\ on the include path, the way the
    in tree build did. The top level g722_1.h of the autotools build is generated
    by configure and never existed on Windows.

    Environment (all optional): G722_1_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, G722_1_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'g722_1'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " g722_1          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "libg7221-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libg722_1 $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "libg7221-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
        $src = Join-Path $root 'src'

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $root 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\[?libg722_1\]?,\s*\[?([0-9][0-9.]*)\]?') {
            if ($Matches[1] -ne $s.Version) { throw "libg722_1 source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # Source list straight out of upstream's Makefile.am, plus the one file its
        # WIN32SOURCES adds for this platform.
        $mk = (Get-Content (Join-Path $src 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
        if ($mk -notmatch '(?m)^libg722_1_la_SOURCES\s*=\s*([^\r\n]*)$') { throw "No libg722_1_la_SOURCES in src\Makefile.am." }
        $names = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.c' })
        $names += 'msvc\gettimeofday.c'
        if ($names.Count -lt 12) { throw "Only $($names.Count) sources listed in Makefile.am -- the tree layout changed." }
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

        # The same knobs the in tree vcxproj used. LIBG722_1_EXPORTS is inert for the
        # public header (it declares nothing platform specific), but it is what that
        # project defined, so it stays.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $inc = @('msvc', 'g722_1', 'generated') | ForEach-Object { "/I`"$(Join-Path $src $_)`"" }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_WINDOWS /D_USRDLL /DLIBG722_1_EXPORTS $extraCFlags",
                   ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libg722_1.lib'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "g722_1 build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "g722_1 [$plat/$config] did not produce libg722_1.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'g722_1_encode_init', 'g722_1_encode', 'g722_1_decode_init', 'g722_1_decode', 'g722_1_fillin') {
            if ($syms -notmatch "\b$sym\b") { throw "libg722_1.lib does not contain $sym -- the source selection is wrong." }
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
# Upstream's nobase_include_HEADERS, keeping the g722_1\ prefix so both
# #include "g722_1.h" and <g722_1/g722_1.h> work.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\g722_1'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($h in 'g722_1.h', 'version.h') {
    Copy-Item (Join-Path $headerSrc "src\g722_1\$h") -Destination $incDst
}
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'g722_1\g722_1.h', 'g722_1\version.h') {
    if (-not (Test-Path (Join-Path $hdrRoot "include\$must"))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libg722_1.lib (static)",
               "features: G.722.1 encoder + decoder, /MD")
Write-PackageSummary $s
