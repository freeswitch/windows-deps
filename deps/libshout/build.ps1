<#
.SYNOPSIS
    libshout: builds the static libshout.lib (the Icecast source client mod_shout
    uses) with the Visual C++ toolchain and packages it for FreeSWITCH's
    w32\shout.props.

    FreeSWITCH used to build this in tree: w32\download_libshout.props fetched
    libshout-2.2.2.tar.gz from files.freeswitch.org and
    libs\win32\libshout\libshout.2017.vcxproj compiled ten of its sources against
    two headers the tree keeps by hand (libs\win32\libshout\compat.h and
    shout\shout.h). This node builds 2.4.6 -- the version mod_shout's own
    CHECK_SHOUT_MIN_VERSION already anticipates -- from upstream's release.

    2.4.6 has no Windows build of its own (win32\ holds a Visual C++ 6 project and
    nothing else) and no Windows config.h, so this node supplies both pieces the
    way configure would:
      * config.h, written here, saying what the platform has: Winsock2,
        getaddrinfo/getnameinfo, inet_pton, sockaddr_storage.ss_family, pthreads;
      * include\shout\shout.h, generated from upstream's shout.h.in by filling in
        SHOUT_THREADSAFE and SHOUT_TLS.

    Upstream sources are taken as they come, with one exception kept as a diff in
    patches\: format_webm.c offsets void * pointers, a GCC extension the Visual C++
    compiler rejects, and shout.c calls into that file unconditionally.

    What goes in is upstream's own file list: libshout_la_SOURCES with PROTOCOLS,
    FORMATS and CODECS expanded, plus the convenience libraries under src\common
    (avl, net, timing, httpp, thread). Vorbis, Theora and Speex stay out -- they
    are optional codecs for Ogg streams, and mod_shout streams MP3 -- and so does
    TLS, which the in tree build never had either. Ogg itself is not optional:
    shout.c calls shout_open_ogg unconditionally, so the node builds against this
    repository's libogg package.

    Threads stay on, as in the in tree build: src\common\thread\thread.c is
    pthread code, so it compiles against this repository's pthreads package and
    the resulting library refers to pthread symbols, which the consumer resolves
    through pthreads.props.

    Package <pkg> = libshout-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/shout/shout.h
                                              <pkg>/include/os.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/libshout.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBSHOUT_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBSHOUT_URL, EXTRA_CFLAGS, and
    LIBOGG_PKG_BASE / LIBOGG_PKG, PTHREADS_PKG_BASE / PTHREADS_PKG for the
    dependency packages.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libshout'
$tc = Initialize-Toolchain
$extraCFlags  = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libshout        : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " pthreads        : package $(Get-EnvValue 'PTHREADS_PKG' '?') from $(Get-EnvValue 'PTHREADS_PKG_BASE' '?')"
Write-Host " libogg          : package $(Get-EnvValue 'LIBOGG_PKG' '?') from $(Get-EnvValue 'LIBOGG_PKG_BASE' '?')"
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
$depCache = Join-Path $s.BuildRoot 'deps'

$oggInclude = Join-Path (Get-DepPackageRoot -Dep libogg -Kind headers -CacheDir $depCache) 'include'
if (-not (Test-Path (Join-Path $oggInclude 'ogg\ogg.h'))) { throw "ogg\ogg.h not found in the libogg headers package (looked in '$oggInclude')." }

# Headers MSVC does not have, which the sources include on this platform:
# sock.h takes <compat.h> where POSIX would give it <unistd.h> (FreeSWITCH kept
# the same one line file in tree), and encoding.c calls strcasecmp.
$shim = Join-Path $s.BuildRoot 'winshim'
Reset-Directory $shim
Set-Content -Path (Join-Path $shim 'compat.h') -Encoding ASCII -Value @(
    '/* Windows stand in for <unistd.h>, as libs\win32\libshout\compat.h is in the FreeSWITCH tree. */',
    '#include <config.h>')
New-Item -ItemType Directory -Force -Path (Join-Path $shim 'sys') | Out-Null
Set-Content -Path (Join-Path $shim 'sys\select.h') -Encoding ASCII -Value @(
    '/* Windows stand in for <sys/select.h>: select and fd_set come from winsock2. */',
    '#ifndef WINDOWS_DEPS_SYS_SELECT_H',
    '#define WINDOWS_DEPS_SYS_SELECT_H',
    '#include <winsock2.h>',
    '#endif')
Set-Content -Path (Join-Path $shim 'strings.h') -Encoding ASCII -Value @(
    '/* Windows stand in for <strings.h>; the POSIX names themselves are mapped in config.h. */',
    '#ifndef WINDOWS_DEPS_STRINGS_H',
    '#define WINDOWS_DEPS_STRINGS_H',
    '#include <string.h>',
    '#endif')

$tarball = Join-Path $s.BuildRoot "libshout-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

# Only the headers are needed here; the import library is the consumer's business,
# which pthreads.props hands it.
$pthreadsInclude = Join-Path (Get-DepPackageRoot -Dep pthreads -Kind headers -CacheDir $depCache) 'include'
if (-not (Test-Path (Join-Path $pthreadsInclude 'pthread.h'))) { throw "pthread.h not found in the pthreads headers package (looked in '$pthreadsInclude')." }

# Expands GNU make style $(NAME) references against the assignments of one
# Makefile.am; an unset name expands to nothing, which is what the conditionals
# this build does not enable (vorbis, theora, speex, tls) amount to.
function Get-MakeSources([string]$MakefilePath, [string]$VariableName) {
    $text = (Get-Content $MakefilePath -Raw) -replace '\\\r?\n', ' '
    $vars = @{}
    $depth = 0
    foreach ($line in ($text -split '\r?\n')) {
        # Assignments guarded by an automake conditional belong to features this
        # build does not enable (vorbis, theora, speex, tls), so they stay unset.
        if ($line -match '^\s*if(eq|neq|def|ndef)?\s') { $depth++; continue }
        if ($line -match '^\s*endif\b') { if ($depth -gt 0) { $depth-- }; continue }
        if ($line -match '^\s*else\b') { continue }
        if ($depth -gt 0) { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $vars[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if (-not $vars.ContainsKey($VariableName)) { throw "No $VariableName in $MakefilePath." }
    $value = $vars[$VariableName]
    for ($i = 0; $i -lt 8; $i++) {
        $expanded = [regex]::Replace($value, '\$\(([A-Za-z_][A-Za-z0-9_]*)\)', {
            param($m) if ($vars.ContainsKey($m.Groups[1].Value)) { $vars[$m.Groups[1].Value] } else { '' } })
        if ($expanded -eq $value) { break }
        $value = $expanded
    }
    @($value -split '\s+' | Where-Object { $_ -like '*.c' })
}

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libshout $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "libshout-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
        $src = Join-Path $root 'src'

        # The version upstream's configure.ac declares must match the manifest.
        $ac = Get-Content (Join-Path $root 'configure.ac') -Raw -ErrorAction SilentlyContinue
        if ($ac -and $ac -match 'AC_INIT\(\[libshout\],\s*\[([0-9][0-9.]*)\]') {
            if ($Matches[1] -ne $s.Version) { throw "libshout source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from configure.ac, not cross-checked."
        }

        # --- the two files configure would have produced ---------------------------
        $ver = $s.Version -split '\.'
        $configH = @"
/* config.h for the Visual C++ build of libshout, written by windows-deps.
   Upstream ships no Windows configuration; these are the answers configure
   would reach on this platform. */
#ifndef WINDOWS_DEPS_LIBSHOUT_CONFIG_H
#define WINDOWS_DEPS_LIBSHOUT_CONFIG_H
#define PACKAGE "libshout"
#define PACKAGE_NAME "libshout"
#define PACKAGE_VERSION "$($s.Version)"
#define VERSION "$($s.Version)"

#define HAVE_WINSOCK2_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETNAMEINFO 1
#define HAVE_STRUCT_SOCKADDR_STORAGE_SS_FAMILY 1
#define HAVE_SOCKLEN_T 1

#define HAVE_PTHREAD 1
#define HAVE_OGG 1

#define HAVE_STDARG_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_C99_INTTYPES 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIMEB_H 1
#define HAVE_FTIME 1

/* configure normally defines these; shout_version() reports them. */
#define LIBSHOUT_MAJOR $($ver[0])
#define LIBSHOUT_MINOR $($ver[1])
#define LIBSHOUT_MICRO $($ver[2])

/* Not every caller of these POSIX names includes <strings.h>; on glibc they come
   with <string.h>. Since config.h is included first everywhere, map them here. */
#if defined(_MSC_VER)
#define strcasecmp  _stricmp
#define strncasecmp _strnicmp
#endif

/* Every source includes config.h first, which makes this the place to settle
   two Windows details once: the socket headers in their required order
   (ws2tcpip.h is where getaddrinfo and getnameinfo are declared), and
   libshout's own MSVC typedefs -- ssize_t and the fixed width types -- which
   it keeps in os.h. */
#if defined(_MSC_VER)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <os.h>
#endif
#endif
"@
        Set-Content -Path (Join-Path $root 'config.h') -Value $configH -Encoding ASCII

        $shoutH = Get-Content (Join-Path $root 'include\shout\shout.h.in') -Raw
        $shoutH = $shoutH -replace '@SHOUT_THREADSAFE@', '1' -replace '@SHOUT_TLS@', '0'
        if ($shoutH -match '@[A-Za-z_]+@') { throw "shout.h.in has placeholders this build does not fill: $($Matches[0])." }
        Set-Content -Path (Join-Path $root 'include\shout\shout.h') -Value $shoutH -Encoding ASCII

        # Everything this build changes in upstream sources lives in patches\ and is
        # applied here; patch fails the build if a hunk no longer applies, which is
        # how a fix landing upstream would announce itself.
        foreach ($patch in (Get-ChildItem (Join-Path $PSScriptRoot 'patches') -Filter '*.patch' | Sort-Object Name)) {
            Write-Host "applying $($patch.Name)"
            & patch -p1 -i "$($patch.FullName)" -d "$root" --binary
            if ($LASTEXITCODE -ne 0) { throw "patch $($patch.Name) did not apply (exit $LASTEXITCODE)." }
        }

        # --- source list, upstream's own -------------------------------------------
        $names = Get-MakeSources (Join-Path $src 'Makefile.am') 'libshout_la_SOURCES' | ForEach-Object { $_ }
        if ($names.Count -lt 14) { throw "Only $($names.Count) sources in src\Makefile.am -- the tree layout changed." }
        $sources = foreach ($n in $names) {
            $p = Join-Path $src ($n -replace '/', '\')
            if (-not (Test-Path $p)) { throw "'$n' is listed in src\Makefile.am but missing." }
            $p
        }
        foreach ($sub in @(@('avl', 'libiceavl_la_SOURCES'), @('net', 'libicenet_la_SOURCES'),
                           @('timing', 'libicetiming_la_SOURCES'), @('httpp', 'libicehttpp_la_SOURCES'),
                           @('thread', 'libicethread_la_SOURCES'))) {
            $dir = Join-Path $src "common\$($sub[0])"
            foreach ($n in (Get-MakeSources (Join-Path $dir 'Makefile.am') $sub[1])) {
                # httpp/encoding.c is Icecast server side code: nothing in libshout
                # calls the httpp_encoding API, and it does pointer arithmetic on
                # void *, which is a GCC extension the Visual C++ compiler rejects.
                if ($n -eq 'encoding.c') { continue }
                $p = Join-Path $dir $n
                if (-not (Test-Path $p)) { throw "'common\$($sub[0])\$n' is listed in Makefile.am but missing." }
                $sources += $p
            }
        }
        $dupes = $sources | Group-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { $_.Count -gt 1 }
        if ($dupes) { throw "Duplicate source file names: $(($dupes | ForEach-Object { $_.Name }) -join ', ')." }
        Write-Host ("sources: {0} files" -f $sources.Count)

        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # _TIMESPEC_DEFINED keeps pthreads-w32 from redefining struct timespec,
        # which the Visual C++ runtime headers already declare; the in tree project
        # defines it for the same reason.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $incDirs = @((Join-Path $root 'include'), $src, (Join-Path $src 'common'), $root, $shim, $oggInclude, $pthreadsInclude)
        $inc = $incDirs | ForEach-Object { "/I`"$_`"" }
        $clRsp = @("/nologo /c $crt $opt /W3 /DWIN32 /D_WIN32 /D_LIB /DHAVE_CONFIG_H /D_TIMESPEC_DEFINED /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE $extraCFlags",
                   ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $lib = Join-Path $binDir 'libshout.lib'
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
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libshout build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        # Everything mod_shout calls.
        if (-not (Test-Path $lib)) { throw "libshout [$plat/$config] did not produce libshout.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'shout_init', 'shout_shutdown', 'shout_new', 'shout_free', 'shout_open', 'shout_close',
                         'shout_send', 'shout_sync', 'shout_get_error', 'shout_set_host', 'shout_set_port',
                         'shout_set_user', 'shout_set_password', 'shout_set_mount', 'shout_set_protocol',
                         'shout_set_format', 'shout_set_content_format', 'shout_set_audio_info',
                         'shout_set_name', 'shout_set_url', 'shout_set_description', 'shout_set_meta',
                         'shout_version') {
            if ($syms -notmatch "\b$sym\b") { throw "libshout.lib does not contain $sym -- the source selection is wrong." }
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
# The one public header, as generated above; upstream installs it as
# $(includedir)/shout/shout.h and mod_shout writes #include <shout/shout.h>.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\shout'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerSrc 'include\shout\shout.h') -Destination $incDst
# shout.h includes <os.h> on Windows for its MSVC typedefs. Upstream only
# distributes that header, never installs it -- it has no Windows install to
# speak of -- so the package carries it next to shout\.
Copy-Item (Join-Path $headerSrc 'include\os.h') -Destination (Join-Path $hdrRoot 'include')
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
$h = Get-Content (Join-Path $incDst 'shout.h') -Raw
if (-not (Test-Path (Join-Path $hdrRoot 'include\os.h'))) { throw 'Headers package is missing include\os.h.' }
foreach ($must in 'shout_set_content_format', 'SHOUT_FORMAT_MP3', 'SHOUT_THREADSAFE') {
    if ($h -notmatch "\b$must\b") { throw "include\shout\shout.h does not declare $must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: libshout.lib (static)",
               "features: HTTP/ICY/xaudiocast protocols, MP3, Ogg, WebM and text formats, threads",
               "without: TLS, Vorbis, Theora, Speex",
               "links against: this repository's libogg package, and pthreads-w32 at the consumer")
Write-PackageSummary $s
