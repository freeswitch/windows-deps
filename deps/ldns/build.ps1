<#
.SYNOPSIS
    ldns: builds the static ldns.lib with the Visual C++ toolchain and packages
    it for FreeSWITCH's w32\ldns.props. The consumer is mod_enum, which resolves
    NAPTR records through it.

    FreeSWITCH built this in tree: w32\download_LDNS.props fetched
    ldns-1.6.9-2-win.tar.gz from files.freeswitch.org -- a Windows repack that
    exists nowhere else -- and libs\win32\ldns\ldns-lib\ldns-lib.2017.vcxproj
    compiled it against three headers the tree keeps by hand (config.h, util.h
    and net.h), one of which still has @PACKAGE_VERSION@ in it where the version
    should be. This node builds 1.9.2 from NLnet Labs' own tag.

    Upstream has no Visual C++ build -- makewin.sh cross compiles with mingw --
    and the tag archive has no configure output in it, so this node does what
    configure does:
      * ldns\common.h, ldns\net.h and ldns\util.h, generated from the .in
        templates beside them, which is where the version macros and the
        LDNS_BUILD_CONFIG_* answers come from;
      * ldns\config.h, written here: what the platform has, plus configure.ac's
        own AH_BOTTOM trailer, minus the <unistd.h> include Visual C++ has no
        counterpart for;
      * gettimeofday, which net.c, tsig.c and util.c call unconditionally --
        configure never checks for it because every platform ldns targets has
        one, and Winsock does not.

    OpenSSL stays out, as it was out of the in tree build: LDNS_BUILD_CONFIG_HAVE_SSL
    is 0 and the DNSSEC, DANE and key handling that needs it compiles away.
    mod_enum asks this library for a resolver, a query and the NAPTR records that
    come back, none of which touches crypto.

    Upstream sources are taken as they come, with one exception kept as a diff in
    patches\: the public headers packet.h and resolver.h include <sys/time.h> for
    struct timeval, which the Windows SDK does not have. While the library is
    built, <strings.h>, <sys/time.h> and <unistd.h> come from stand ins written
    below; those are build time only and nothing ships them.

    Package <pkg> = ldns-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/ldns/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/ldns.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LDNS_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LDNS_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'ldns'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " ldns            : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "ldns-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = (Get-ChildItem $srcParent -Directory | Select-Object -First 1)
if (-not $root) { throw "The tag archive did not expand to a directory." }
$root = $root.FullName
foreach ($must in 'configure.ac', 'LICENSE', 'ldns\common.h.in', 'ldns\net.h.in', 'ldns\util.h.in') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}

# configure.ac carries the version in three m4 macros; AC_INIT joins them.
$configureAc = Get-Content (Join-Path $root 'configure.ac') -Raw
$verParts = foreach ($part in 'MAJOR', 'MINOR', 'MICRO') {
    if ($configureAc -notmatch "m4_define\(\[VERSION_$part\],\[([0-9]+)\]\)") { throw "configure.ac has no VERSION_$part." }
    $Matches[1]
}
$sourceVersion = $verParts -join '.'
if ($sourceVersion -ne $s.Version) { throw "The source tree declares version $sourceVersion but deps.json says $($s.Version)." }
Write-Host "configure.ac declares $sourceVersion"

# Everything this build changes in upstream sources lives in patches\ and is
# applied here; patch fails the build if a hunk no longer applies, which is how
# a fix landing upstream would announce itself.
foreach ($patch in (Get-ChildItem (Join-Path $PSScriptRoot 'patches') -Filter '*.patch' | Sort-Object Name)) {
    Write-Host "applying $($patch.Name)"
    & patch -p1 -i "$($patch.FullName)" -d "$root" --binary
    if ($LASTEXITCODE -ne 0) { throw "patch $($patch.Name) did not apply (exit $LASTEXITCODE)." }
}

# --- the headers configure generates ---------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Generating ldns\common.h, ldns\net.h and ldns\util.h ..."

$common = Get-Content (Join-Path $root 'ldns\common.h.in') -Raw
$commonMap = [ordered]@{
    'ldns_build_config_have_ssl'         = '0'
    'ldns_build_config_have_inttypes_h'  = '1'
    'ldns_build_config_have_attr_format' = '0'
    'ldns_build_config_have_attr_unused' = '0'
    'ldns_build_config_have_socklen_t'   = '1'
    'ldns_build_config_use_dane'         = '0'
    'ldns_build_config_have_b32_pton'    = '0'
    'ldns_build_config_have_b32_ntop'    = '0'
    'ldns_build_config_use_dsa'          = '0'
    'ldns_build_config_use_ed25519'      = '0'
    'ldns_build_config_use_ed448'        = '0'
}
foreach ($k in $commonMap.Keys) { $common = $common.Replace("@$k@", $commonMap[$k]) }
# ssize_t reaches the other public headers through this one.
$ssizeAnchor = '#define LDNS_BUILD_CONFIG_USE_ED448      '
$ssizeLine = ($common -split "`n" | Where-Object { $_.StartsWith($ssizeAnchor) } | Select-Object -First 1)
if (-not $ssizeLine) { throw "ldns\common.h.in no longer defines LDNS_BUILD_CONFIG_USE_ED448 where expected." }
$ssizeBlock = @'

/* The Windows SDK has no ssize_t, and the headers that use it -- buffer.h,
   parse.h, net.h -- all reach this one first. */
#if defined(_MSC_VER) && !defined(_SSIZE_T_DEFINED)
#include <BaseTsd.h>
typedef SSIZE_T ssize_t;
#define _SSIZE_T_DEFINED
#endif
'@
$common = $common.Replace($ssizeLine.TrimEnd("`r"), $ssizeLine.TrimEnd("`r") + "`r`n" + $ssizeBlock)
Set-Content -Path (Join-Path $root 'ldns\common.h') -Value $common -Encoding ASCII

$net = Get-Content (Join-Path $root 'ldns\net.h.in') -Raw
$net = $net.Replace('@include_sys_socket_h@', "#include <winsock2.h>`r`n#include <ws2tcpip.h>")
Set-Content -Path (Join-Path $root 'ldns\net.h') -Value $net -Encoding ASCII

$util = Get-Content (Join-Path $root 'ldns\util.h.in') -Raw
$util = $util.Replace('@include_inttypes_h@', '#include <inttypes.h>')
$util = $util.Replace('@include_systypes_h@', '#include <sys/types.h>')
$util = $util.Replace('@include_unistd_h@', '')
$util = $util.Replace('@PACKAGE_VERSION@', $s.Version)
$util = $util.Replace('@LDNS_VERSION_MAJOR@', $verParts[0])
$util = $util.Replace('@LDNS_VERSION_MINOR@', $verParts[1])
$util = $util.Replace('@LDNS_VERSION_MICRO@', $verParts[2])
Set-Content -Path (Join-Path $root 'ldns\util.h') -Value $util -Encoding ASCII

foreach ($h in 'common.h', 'net.h', 'util.h') {
    # configure's own substitutions only; /*@unused@*/ and friends are splint annotations.
    $left = Select-String -Path (Join-Path $root "ldns\$h") -AllMatches `
            -Pattern '@(ldns_build_config_[a-z0-9_]+|include_[a-z_]+|PACKAGE_VERSION|LDNS_VERSION_[A-Z]+)@'
    if ($left) { throw "ldns\$h still has placeholders: $($left.Matches.Value -join ', ')" }
}

# --- ldns\config.h ---------------------------------------------------------------
$configH = @"
/* ldns/config.h for the Visual C++ build of ldns, written by windows-deps.
   Upstream generates this with autoheader and configure, neither of which runs
   here; these are the answers configure reaches on this platform. The trailer
   below is configure.ac's AH_BOTTOM, minus the <unistd.h> include Visual C++
   has no counterpart for. */
#ifndef WINDOWS_DEPS_LDNS_CONFIG_H
#define WINDOWS_DEPS_LDNS_CONFIG_H

#define PACKAGE "ldns"
#define PACKAGE_NAME "ldns"
#define PACKAGE_VERSION "$($s.Version)"
#define PACKAGE_STRING "ldns $($s.Version)"
#define PACKAGE_BUGREPORT "dns-team@nlnetlabs.nl"
#define VERSION PACKAGE_VERSION

#define STDC_HEADERS 1
#define HAVE_STDLIB_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDBOOL_H 1
#define HAVE__BOOL 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRING_H 1
#define HAVE_TIME_H 1
#define HAVE_WINSOCK2_H 1
#define HAVE_WS2TCPIP_H 1
#define USE_WINSOCK 1

/* Winsock carries the BSD socket API these check for. */
#define HAVE_GETADDRINFO 1
#define HAVE_GETNAMEINFO 1
#define HAVE_FREEADDRINFO 1
#define HAVE_GAI_STRERROR 1
#define HAVE_INET_PTON 1
#define HAVE_INET_NTOP 1
#define HAVE_DECL_INET_PTON 1
#define HAVE_DECL_INET_NTOP 1
#define HAVE_IOCTLSOCKET 1
#define HAVE_SOCKLEN_T 1
#define HAVE_STRUCT_ADDRINFO 1
#define HAVE_STRUCT_SOCKADDR_STORAGE 1
#define HAVE_STRUCT_SOCKADDR_IN6 1
#define HAVE_STRUCT_IN6_ADDR 1

#define HAVE_MALLOC 1
#define HAVE_REALLOC 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMSET 1
#define HAVE_SNPRINTF 1
#define HAVE_STRTOUL 1
#define HAVE_ISBLANK 1
#define HAVE_ISASCII 1

/* rand and srand under their BSD names: the trailer would otherwise make them
   function-like macros, and keys.c calls random() without arguments. */
#define HAVE_RANDOM 1
#define random rand
#define srandom srand

/* Visual C++ spells these with a leading underscore. */
#define strcasecmp  _stricmp
#define strncasecmp _strnicmp
#define strdup      _strdup

/* ---- configure.ac AH_BOTTOM ---------------------------------------------- */
#include <stdio.h>
#include <string.h>
#include <assert.h>

#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN 1234
#endif

#ifndef BIG_ENDIAN
#define BIG_ENDIAN 4321
#endif

#ifndef BYTE_ORDER
#ifdef WORDS_BIGENDIAN
#define BYTE_ORDER BIG_ENDIAN
#else
#define BYTE_ORDER LITTLE_ENDIAN
#endif /* WORDS_BIGENDIAN */
#endif /* BYTE_ORDER */

#if STDC_HEADERS
#include <stdlib.h>
#include <stddef.h>
#endif

#ifdef HAVE_STDINT_H
#include <stdint.h>
#endif

#ifdef HAVE_WINSOCK2_H
#include <winsock2.h>
#endif

#ifdef HAVE_WS2TCPIP_H
#include <ws2tcpip.h>
#endif

/* detect if we need to cast to unsigned int for FD_SET to avoid warnings */
#ifdef HAVE_WINSOCK2_H
#define FD_SET_T (u_int)
#else
#define FD_SET_T
#endif

/* Types Winsock does not spell the POSIX way. */
typedef unsigned short in_port_t;
typedef unsigned int in_addr_t;

#ifdef __cplusplus
extern "C" {
#endif

int ldns_b64_ntop(uint8_t const *src, size_t srclength,
	 	  char *target, size_t targsize);
/**
 * calculates the size needed to store the result of b64_ntop
 */
/*@unused@*/
static inline size_t ldns_b64_ntop_calculate_size(size_t srcsize)
{
	return ((((srcsize + 2) / 3) * 4) + 1);
}
int ldns_b64_pton(char const *src, uint8_t *target, size_t targsize);
/**
 * calculates the size needed to store the result of ldns_b64_pton
 */
/*@unused@*/
static inline size_t ldns_b64_pton_calculate_size(size_t srcsize)
{
	return (((((srcsize + 3) / 4) * 3)) + 1);
}

/**
 * Given in dnssec_zone.c, also used in dnssec_sign.c
 */
int ldns_dname_compare_v(const void *a, const void *b);

/* Winsock has no gettimeofday; this build compiles one next to the sources. */
int gettimeofday(struct timeval *tv, void *tz);

#ifndef HAVE_SLEEP
/* use windows sleep, in millisecs, instead */
#define sleep(x) Sleep((x)*1000)
#endif

#ifndef HAVE_TIMEGM
#include <time.h>
time_t timegm (struct tm *tm);
#endif /* !TIMEGM */
#ifndef HAVE_GMTIME_R
struct tm *gmtime_r(const time_t *timep, struct tm *result);
#endif
#ifndef HAVE_ASCTIME_R
char *asctime_r(const struct tm *tm, char *buf);
#endif
#ifndef HAVE_LOCALTIME_R
struct tm *localtime_r(const time_t *timep, struct tm *result);
#endif
#ifndef HAVE_STRLCPY
size_t strlcpy(char *dst, const char *src, size_t siz);
#endif

#ifdef USE_WINSOCK
#define SOCK_INVALID ((INT_PTR)INVALID_SOCKET)
#define close_socket(_s) do { if (_s != SOCK_INVALID) {closesocket(_s); _s = -1;} } while(0)
#else
#define SOCK_INVALID -1
#define close_socket(_s) do { if (_s != SOCK_INVALID) {close(_s >= -1 ? _s : -1); _s = -1;} } while(0)
#endif

#ifdef __cplusplus
}
#endif

#endif /* WINDOWS_DEPS_LDNS_CONFIG_H */
"@
Set-Content -Path (Join-Path $root 'ldns\config.h') -Value $configH -Encoding ASCII

# --- gettimeofday ----------------------------------------------------------------
$gtod = @'
/* gettimeofday for the Visual C++ build of ldns, written by windows-deps.
   net.c, tsig.c and util.c call it unconditionally: configure never checks for
   it because every platform ldns targets has one. Winsock does not. */
#include <ldns/config.h>

int gettimeofday(struct timeval *tv, void *tz)
{
	/* FILETIME counts 100ns ticks from 1601-01-01 and timeval seconds from
	   1970-01-01; 11644473600 seconds lie between the two epochs. */
	static const unsigned __int64 epoch_offset = 116444736000000000ULL;
	FILETIME ft;
	unsigned __int64 ticks;

	(void)tz;
	if (!tv) {
		return -1;
	}
	GetSystemTimeAsFileTime(&ft);
	ticks = ((unsigned __int64)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
	ticks = (ticks - epoch_offset) / 10;
	tv->tv_sec = (long)(ticks / 1000000ULL);
	tv->tv_usec = (long)(ticks % 1000000ULL);
	return 0;
}
'@
Set-Content -Path (Join-Path $root 'compat\msvc_gettimeofday.c') -Value $gtod -Encoding ASCII

# --- headers Visual C++ does not have --------------------------------------------
# The sources include <strings.h>, <sys/time.h> and <unistd.h> unconditionally.
# These stand in for them while the library is compiled; nothing ships them.
$shim = Join-Path $s.BuildRoot 'msvc-include'
New-Item -ItemType Directory -Force -Path (Join-Path $shim 'sys') | Out-Null
Set-Content -Path (Join-Path $shim 'strings.h') -Encoding ASCII -Value @'
/* <strings.h> stand in for the Visual C++ build; the POSIX names ldns takes
   from it are mapped in ldns/config.h. */
#include <string.h>
'@
Set-Content -Path (Join-Path $shim 'sys\time.h') -Encoding ASCII -Value @'
/* <sys/time.h> stand in for the Visual C++ build: struct timeval comes from
   Winsock, and gettimeofday is declared in ldns/config.h. */
#include <winsock2.h>
#include <time.h>
'@
Set-Content -Path (Join-Path $shim 'unistd.h') -Encoding ASCII -Value @'
/* <unistd.h> stand in for the Visual C++ build. */
#include <io.h>
#include <process.h>
'@

# --- what goes in ----------------------------------------------------------------
# Upstream's library sources, minus linktest.c, which is a main() that exists to
# prove the library links. The compat sources are the four functions this
# platform does not have -- gmtime_r, localtime_r, strlcpy and the base64 pair --
# plus the gettimeofday written above.
$sources = @(
    'buffer.c', 'dane.c', 'dname.c', 'dnssec.c', 'dnssec_sign.c', 'dnssec_verify.c',
    'dnssec_zone.c', 'duration.c', 'edns.c', 'error.c', 'higher.c', 'host2str.c',
    'host2wire.c', 'keys.c', 'net.c', 'packet.c', 'parse.c', 'radix.c', 'rbtree.c',
    'rdata.c', 'resolver.c', 'rr.c', 'rr_functions.c', 'sha1.c', 'sha2.c',
    'str2host.c', 'tsig.c', 'update.c', 'util.c', 'wire2host.c', 'zone.c',
    'compat\b64_ntop.c', 'compat\b64_pton.c', 'compat\gmtime_r.c',
    'compat\localtime_r.c', 'compat\strlcpy.c', 'compat\msvc_gettimeofday.c'
)
foreach ($f in $sources) {
    if (-not (Test-Path (Join-Path $root $f))) { throw "'$f' is missing from the source tree." }
}
$fileList = ($sources | ForEach-Object { '"' + (Join-Path $root $_) + '"' }) -join ' '

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building ldns.lib $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $lib = Join-Path $binDir 'ldns.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cd /d "$root"
cl /nologo /c $crt $opt /W3 /DWIN32 /D_LIB /DHAVE_CONFIG_H /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE $extraCFlags /I"$shim" /I"$root" /Fo"$objDir\\" /Fd"$objDir\compiler.pdb" $fileList || exit /b 1
lib /nologo /OUT:"$lib" "$objDir\*.obj" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "ldns build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "ldns [$plat/$config] did not produce ldns.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        # mod_enum's own list, plus the version string.
        foreach ($sym in 'ldns_resolver_new', 'ldns_resolver_new_frm_file', 'ldns_resolver_query',
                         'ldns_resolver_push_nameserver', 'ldns_resolver_set_timeout',
                         'ldns_resolver_set_retry', 'ldns_resolver_set_random',
                         'ldns_resolver_deep_free', 'ldns_dname_new_frm_str', 'ldns_pkt_rr_list_by_type', 'ldns_pkt_free',
                         'ldns_rr_list_rr', 'ldns_rr_list_rr_count', 'ldns_rr_list_sort',
                         'ldns_rr_list_deep_free', 'ldns_rr2str', 'ldns_str2rdf_a',
                         'ldns_str2rdf_aaaa', 'ldns_version') {
            if ($syms -notmatch "\b$sym\b") { throw "ldns.lib does not contain $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'LICENSE') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))
    }
}

# --- headers zip -------------------------------------------------------------------
# What upstream installs: ldns\*.h without config.h, which is this build's own
# answer sheet and no business of a consumer.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\ldns'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Get-ChildItem (Join-Path $root 'ldns') -Filter '*.h' |
    Where-Object { $_.Name -ne 'config.h' } |
    Copy-Item -Destination $incDst
Copy-Item (Join-Path $root 'LICENSE') -Destination $hdrRoot
foreach ($must in 'ldns.h', 'common.h', 'net.h', 'util.h', 'packet.h', 'resolver.h', 'rr.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\ldns\$must." }
}
if (Test-Path (Join-Path $incDst 'config.h')) { throw "config.h must stay out of the headers package." }
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: ldns.lib (static)",
               "headers: ldns\common.h, net.h and util.h generated from the .in templates",
               "options: no OpenSSL (LDNS_BUILD_CONFIG_HAVE_SSL 0), Winsock")
Write-PackageSummary $s
