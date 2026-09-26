<#
.SYNOPSIS
    libjpeg: builds the static libjpeg.lib (the Independent JPEG Group's
    library) with the Visual C++ toolchain and packages it for FreeSWITCH's
    w32\libjpeg.props. The consumer is spandsp, whose T.42/T.43 fax image code
    encodes and decodes JPEG through it.

    FreeSWITCH built this in tree: w32\download_libjpeg.props fetched
    jpegsrc.v8d.tar.gz from files.freeswitch.org and
    libs\win32\libjpeg\libjpeg.2017.vcxproj compiled it. This node builds
    release 10 from ijg.org.

    IJG ships its own Windows build and the node follows it: jconfig.h is
    jconfig.vc, as install.txt says to do for Visual C++, and the file list is
    the one in makejvcx.v16, the Visual Studio project the release carries for
    the library -- the same 46 files the in tree project compiled, with
    jmemnobs.c as the memory manager. The version is checked against both
    jversion.h and JPEG_LIB_VERSION_MAJOR in jpeglib.h.

    The solution maps the in tree project's Debug|x64 and Release|x64 to static
    libraries, so the package is a static library, built with the same knobs:
    /MD, WIN32, _LIB, _CRT_SECURE_NO_WARNINGS.

    Package <pkg> = libjpeg-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/README
                                              <pkg>/include/{jpeglib.h, jconfig.h, jmorecfg.h, jerror.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/README
                                              <pkg>/binaries/<Platform>/<Config>/libjpeg.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    README goes in because its LEGAL ISSUES section is the licence.

    Environment (all optional): LIBJPEG_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBJPEG_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libjpeg'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libjpeg         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "jpegsrc.v$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = Join-Path $srcParent "jpeg-$($s.Version)"
if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
foreach ($must in 'jconfig.vc', 'makejvcx.v16', 'jversion.h', 'jpeglib.h', 'README') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}

# The version must agree in both places the release keeps it.
$jv = Get-Content (Join-Path $root 'jversion.h') -Raw
if ($jv -notmatch '#define\s+JVERSION\s+"([0-9a-z]+)\s') { throw "jversion.h defines no JVERSION." }
if ($Matches[1] -ne $s.Version) { throw "jversion.h declares $($Matches[1]) but deps.json says $($s.Version)." }
$jl = Get-Content (Join-Path $root 'jpeglib.h') -Raw
if ($jl -notmatch '#define\s+JPEG_LIB_VERSION_MAJOR\s+([0-9]+)') { throw "jpeglib.h defines no JPEG_LIB_VERSION_MAJOR." }
if ($s.Version -notmatch "^$($Matches[1])([a-z]?)$") { throw "jpeglib.h says major version $($Matches[1]) but deps.json says $($s.Version)." }
Write-Host "jversion.h and jpeglib.h declare release $($s.Version)"

# jconfig.h for Visual C++ is jconfig.vc, per install.txt.
Copy-Item (Join-Path $root 'jconfig.vc') (Join-Path $root 'jconfig.h') -Force

# --- source list, IJG's own Visual Studio project ------------------------------------
$vcx = Get-Content (Join-Path $root 'makejvcx.v16') -Raw
$names = @([regex]::Matches($vcx, '<ClCompile Include="([^"]+\.c)"') | ForEach-Object { $_.Groups[1].Value })
if ($names.Count -lt 40) { throw "Only $($names.Count) sources listed in makejvcx.v16 -- the tree layout changed." }
$sources = foreach ($n in $names) {
    $p = Join-Path $root $n
    if (-not (Test-Path $p)) { throw "'$n' is listed in makejvcx.v16 but missing." }
    $p
}
Write-Host ("sources: {0} files" -f $sources.Count)

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libjpeg.lib $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The same knobs the in tree vcxproj and makejvcx.v16 use.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_LIB /D_CRT_SECURE_NO_WARNINGS $extraCFlags",
                   "/I`"$root`"", "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libjpeg.lib'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libjpeg build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "libjpeg [$plat/$config] did not produce libjpeg.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        # What spandsp's t42.c and t43.c take from the library.
        # jpeg_create_compress/decompress are macros over the jpeg_Create* functions.
        foreach ($sym in 'jpeg_std_error', 'jpeg_CreateCompress', 'jpeg_CreateDecompress', 'jpeg_set_defaults',
                         'jpeg_set_quality', 'jpeg_start_compress', 'jpeg_write_scanlines', 'jpeg_write_marker',
                         'jpeg_finish_compress', 'jpeg_destroy_compress', 'jpeg_save_markers', 'jpeg_read_header',
                         'jpeg_start_decompress', 'jpeg_read_scanlines', 'jpeg_finish_decompress',
                         'jpeg_destroy_decompress', 'jpeg_stdio_dest', 'jpeg_stdio_src') {
            if ($syms -notmatch "\b$sym\b") { throw "libjpeg.lib does not contain $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'README') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))
    }
}

# --- headers zip -------------------------------------------------------------------
# Makefile.am's INSTINCLUDES plus the jconfig.h written above, which jpeglib.h
# includes and make install puts beside them.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
$mk = (Get-Content (Join-Path $root 'Makefile.am') -Raw) -replace '\\\r?\n', ' '
if ($mk -notmatch '(?m)^INSTINCLUDES\s*=\s*([^\r\n]*)$') { throw "No INSTINCLUDES in Makefile.am." }
$headers = @($Matches[1] -split '\s+' | Where-Object { $_ -like '*.h' }) + 'jconfig.h'
foreach ($h in $headers) {
    $p = Join-Path $root $h
    if (-not (Test-Path $p)) { throw "'$h' is missing from the source tree." }
    Copy-Item $p -Destination $incDst
}
Copy-Item (Join-Path $root 'README') -Destination $hdrRoot
foreach ($must in 'jpeglib.h', 'jconfig.h', 'jmorecfg.h', 'jerror.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libjpeg.lib (static)",
               "configuration: jconfig.vc, makejvcx.v16 file list, jmemnobs memory manager, /MD")
Write-PackageSummary $s
