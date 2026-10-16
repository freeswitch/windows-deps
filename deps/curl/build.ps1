<#
.SYNOPSIS
    curl: builds libcurl as a DLL with CMake + the Visual C++ toolchain, against
    this repository's OpenSSL and zlib packages, and packages it for FreeSWITCH's
    w32\curl.props: libcurl.dll, its import library shipped as curl.lib, and the
    headers. curl.props links curl.lib and copies libcurl.dll next to the
    binaries.

    A DLL, not a static library, because FreeSWITCH hands curl handles across
    modules: the core creates them (switch_curl_easy_init) and modules set options
    and free them with curl_* directly. With a static curl every DLL carried its
    own libcurl and its own globals, and only the core's copy ever saw
    curl_global_init; curl 8's Windows timer divides by a frequency that
    curl_global_init sets, so a module freeing a core handle died dividing by
    zero. One libcurl.dll per process is what Linux has with libcurl.so.

    Features: OpenSSL (linked into the DLL from the static OpenSSL package),
    zlib (zlib.dll at run time), Win32 LDAP, IPv6, SSPI with NTLM, Kerberos and
    SPNEGO, HTTP/2 and IDN; no PSL, no SSH. Dynamic CRT (/MD).

    HTTP/2 comes from nghttp2, built here from its release and linked into
    libcurl.dll, so it is part of this package rather than a package of its own.
    Its version is $nghttp2Version below: changing it changes this node and
    rebuilds curl. IDN is Windows' own (USE_WIN32_IDN, IdnToAscii from
    Normaliz.dll), so it needs no library.

    Package <pkg> = curl-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING, COPYING.nghttp2
                                              <pkg>/include/curl/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING, COPYING.nghttp2
                                              <pkg>/binaries/<Platform>/<Config>/libcurl.dll
                                                                             /curl.lib     (import library)
                                                                             /libcurl.pdb
      SHA256SUMS.txt, <pkg>-BOM.txt

    The DLL is libcurl.dll in both configurations (curl's "-d" debug postfix is
    turned off), so the name the import library refers to is the one curl.props
    copies.

    Environment (all optional): CURL_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, CURL_URL, NGHTTP2_VERSION, NGHTTP2_URL,
    EXTRA_CMAKE, and ZLIB_PKG_BASE / ZLIB_PKG, OPENSSL_PKG_BASE / OPENSSL_PKG for
    the dependency packages (scripts\build.ps1 sets those from the plan or from
    release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'curl'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

# nghttp2, bundled into curl.lib for HTTP/2.
$nghttp2Version = [string](Get-EnvValue 'NGHTTP2_VERSION' '1.70.0')
$nghttp2Url     = [string](Get-EnvValue 'NGHTTP2_URL' "https://github.com/nghttp2/nghttp2/releases/download/v$nghttp2Version/nghttp2-$nghttp2Version.tar.gz")

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " curl            : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " zlib            : package $(Get-EnvValue 'ZLIB_PKG' '?') from $(Get-EnvValue 'ZLIB_PKG_BASE' '?')"
Write-Host " OpenSSL         : package $(Get-EnvValue 'OPENSSL_PKG' '?') from $(Get-EnvValue 'OPENSSL_PKG_BASE' '?')"
Write-Host " nghttp2         : $nghttp2Version (bundled) from $nghttp2Url"
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

$tarball = Join-Path $s.BuildRoot "curl-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$nghttp2Tarball = Join-Path $s.BuildRoot "nghttp2-$nghttp2Version.tar.gz"
Get-RemoteFile $nghttp2Url $nghttp2Tarball
$depCache = Join-Path $s.BuildRoot 'deps'

$zlibInclude = Join-Path (Get-DepPackageRoot -Dep zlib -Kind headers -CacheDir $depCache) 'include'
if (-not (Test-Path (Join-Path $zlibInclude 'zlib.h'))) { throw "zlib.h not found in the zlib headers package (looked in '$zlibInclude')." }

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building curl $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "curl-$($s.Version)"
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        $verLine = Select-String -Path (Join-Path $srcDir 'include\curl\curlver.h') -Pattern '#define\s+LIBCURL_VERSION\s+"([^"]+)"' | Select-Object -First 1
        if ($verLine -and $verLine.Matches[0].Groups[1].Value -ne $s.Version) { throw "curl source declares version $($verLine.Matches[0].Groups[1].Value) but deps.json says $($s.Version)." }

        # zlib import library of the matching configuration (consumers ship zlib[d].dll
        # via zlib.props); OpenSSL as a conventional root for FindOpenSSL.
        $zd = if ($config -eq 'Debug') { 'd' } else { '' }
        $zroot   = Get-DepPackageRoot -Dep zlib -Kind binaries -CacheDir $depCache -Platform $plat -Config $config
        $zlibLib = Join-Path $zroot "binaries\$plat\$config\lib\zlib$zd.lib"
        if (-not (Test-Path $zlibLib)) { throw "zlib$zd.lib not found in the zlib binaries package for $plat/$config (looked for '$zlibLib')." }
        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache

        # --- nghttp2: the library alone, static, same CRT as curl -----------------
        $ngSrc = Join-Path $work "nghttp2-$nghttp2Version"
        $ngBld = Join-Path $work 'nghttp2-build'
        $ngIns = Join-Path $work 'nghttp2-install'
        Expand-Tarball $nghttp2Tarball $work $tc
        if (-not (Test-Path $ngSrc)) { throw "nghttp2 tarball did not expand to '$ngSrc'." }
        $ngArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $ngSrc)`"",
            "-B `"$(ConvertTo-ForwardSlashes $ngBld)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            "-DCMAKE_INSTALL_PREFIX=`"$(ConvertTo-ForwardSlashes $ngIns)`"",
            '-DENABLE_LIB_ONLY=ON',
            '-DBUILD_SHARED_LIBS=OFF',
            '-DBUILD_STATIC_LIBS=ON',
            '-DBUILD_TESTING=OFF',
            '-DENABLE_DOC=OFF',
            '-DENABLE_FAILMALLOC=OFF'
        )
        $ngBat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($ngArgs -join ' ') || exit /b 1
cmake --build "$ngBld" || exit /b 1
cmake --install "$ngBld" || exit /b 1
"@
        Invoke-BuildBatch -Script $ngBat -BatchFile (Join-Path $work 'nghttp2.bat') -LogFile (Join-Path $s.OutDir "nghttp2-$plat-$config.log") -Label "nghttp2 build [$plat/$config]"
        $ngLib = Join-Path $ngIns 'lib\nghttp2.lib'
        $ngInc = Join-Path $ngIns 'include'
        if (-not (Test-Path $ngLib)) { throw "nghttp2 [$plat/$config] did not install lib\nghttp2.lib." }
        $ngVer = Select-String -Path (Join-Path $ngInc 'nghttp2\nghttp2ver.h') -Pattern '#define\s+NGHTTP2_VERSION\s+"([^"]+)"' | Select-Object -First 1
        if (-not $ngVer -or $ngVer.Matches[0].Groups[1].Value -ne $nghttp2Version) { throw "nghttp2 source does not declare version $nghttp2Version." }

        # libcurl.dll with OpenSSL + zlib, everything else at curl's Windows
        # defaults (Win32 LDAP on, /MD). Only the library target is built. The
        # OpenSSL package is static, so OpenSSL is linked into the DLL. curl 8 looks for libpsl,
        # libidn2 and libssh2 by default and stops without libpsl; they are switched
        # off explicitly. HTTP/2 uses the nghttp2 built above
        # (NGHTTP2_USE_STATIC_LIBS makes curl compile with NGHTTP2_STATICLIB), and
        # IDN uses Windows' own instead of libidn2.
        # SSPI (NTLM, Kerberos, SPNEGO through Windows) now defaults to on only with
        # Schannel; the old packages had it next to OpenSSL, so it is set on. NTLM
        # became opt-in as well, and FreeSWITCH offers it as an auth-scheme
        # (mod_xml_curl, mod_xml_cdr, mod_httapi, ...), so it is enabled too.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DBUILD_SHARED_LIBS=ON',
            '-DBUILD_STATIC_LIBS=OFF',
            '-DCMAKE_DEBUG_POSTFIX=',
            '-DBUILD_CURL_EXE=OFF',
            '-DBUILD_TESTING=OFF',
            '-DCURL_USE_OPENSSL=ON',
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON',
            '-DCURL_ZLIB=ON',
            "-DZLIB_INCLUDE_DIR=`"$(ConvertTo-ForwardSlashes $zlibInclude)`"",
            "-DZLIB_LIBRARY=`"$(ConvertTo-ForwardSlashes $zlibLib)`"",
            '-DCURL_USE_LIBPSL=OFF',
            '-DUSE_NGHTTP2=ON',
            '-DNGHTTP2_USE_STATIC_LIBS=ON',
            "-DNGHTTP2_INCLUDE_DIR=`"$(ConvertTo-ForwardSlashes $ngInc)`"",
            "-DNGHTTP2_LIBRARY=`"$(ConvertTo-ForwardSlashes $ngLib)`"",
            '-DUSE_LIBIDN2=OFF',
            '-DUSE_WIN32_IDN=ON',
            '-DCURL_USE_LIBSSH2=OFF',
            '-DCURL_WINDOWS_SSPI=ON',
            '-DCURL_ENABLE_NTLM=ON'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') > "$(Join-Path $work 'configure.log')" 2>&1 || (type "$(Join-Path $work 'configure.log')" & exit /b 1)
type "$(Join-Path $work 'configure.log')"
cmake --build "$bldDir" --target libcurl_shared || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "curl build [$plat/$config]"

        # --- verify + stage ------------------------------------------------------
        # curl's CMake: libcurl.dll plus import library libcurl_imp.lib (no debug
        # postfix, see above), wherever the generator put them.
        $dll = Get-ChildItem -Recurse -File $bldDir -Filter 'libcurl.dll' | Select-Object -First 1
        $imp = Get-ChildItem -Recurse -File $bldDir -Filter 'libcurl_imp.lib' | Select-Object -First 1
        if (-not $dll -or -not $imp) {
            $have = Get-ChildItem -Recurse -File $bldDir -Include '*.dll', '*.lib' | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
            throw "curl [$plat/$config] did not produce libcurl.dll and libcurl_imp.lib. Found: $($have -join ', ')."
        }
        # The feature line curl's CMake prints must carry what FreeSWITCH relies on.
        $features = Select-String -Path (Join-Path $work 'configure.log') -Pattern '^-- Features: (.*)$' | Select-Object -First 1
        if (-not $features) { throw "curl [$plat/$config]: CMake printed no feature list." }
        foreach ($f in 'SSL', 'libz', 'IPv6', 'SSPI', 'NTLM', 'Kerberos', 'SPNEGO', 'HTTP2', 'IDN') {
            if ($features.Matches[0].Groups[1].Value -notmatch "(^| )$f( |$)") { throw "curl [$plat/$config] is built without $f (features: $($features.Matches[0].Groups[1].Value))." }
        }

        # Exports the API, and imports only system DLLs and zlib: OpenSSL and
        # nghttp2 are inside, so neither may show up as a dependency.
        $dumpBat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
dumpbin /nologo /exports "$($dll.FullName)" > "$(Join-Path $work 'exports.txt')" || exit /b 1
dumpbin /nologo /dependents "$($dll.FullName)" > "$(Join-Path $work 'dependents.txt')" || exit /b 1
"@
        Invoke-BuildBatch -Script $dumpBat -BatchFile (Join-Path $work 'dump.bat') -LogFile (Join-Path $work 'dump.log') -Label "libcurl.dll inspection [$plat/$config]"
        $exports = Get-Content (Join-Path $work 'exports.txt') -Raw
        foreach ($sym in 'curl_global_init', 'curl_easy_init', 'curl_easy_perform', 'curl_easy_cleanup', 'curl_easy_setopt',
                         'curl_mime_init', 'curl_formadd', 'curl_slist_append', 'curl_version_info') {
            if ($exports -notmatch "\b$sym\b") { throw "libcurl.dll [$plat/$config] does not export $sym." }
        }
        $deps = @(Get-Content (Join-Path $work 'dependents.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' })
        Write-Host "  libcurl.dll imports: $($deps -join ', ')"
        $zd = if ($config -eq 'Debug') { 'd' } else { '' }
        if ($deps -notcontains "zlib$zd.dll") { throw "libcurl.dll [$plat/$config] does not import zlib$zd.dll -- zlib support did not get enabled." }
        foreach ($d in $deps) {
            if ($d -match 'nghttp2|libcrypto|libssl') { throw "libcurl.dll [$plat/$config] imports $d; it should have been linked in." }
        }
        $dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dll.FullName))
        if ($dllText -notmatch 'OpenSSL 3\.') { throw "libcurl.dll [$plat/$config] carries no OpenSSL." }

        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $dll.FullName -Destination $binDst
        Copy-Item $imp.FullName -Destination (Join-Path $binDst 'curl.lib')      # the name curl.props links
        $pdb = Get-ChildItem -Recurse -File $bldDir -Filter 'libcurl.pdb' | Select-Object -First 1
        if ($pdb) { Copy-Item $pdb.FullName -Destination $binDst }
        else { Write-Host "  NOTE: no libcurl.pdb found; continuing without it." -ForegroundColor Yellow }
        Copy-Item (Join-Path $srcDir 'COPYING') -Destination $pkgRoot
        Copy-Item (Join-Path $ngSrc 'COPYING') -Destination (Join-Path $pkgRoot 'COPYING.nghttp2')
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir; $ngLicenseSrc = $ngSrc }
    }
}

# --- headers zip: the public headers (include/curl/*.h) ---------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\curl'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Get-ChildItem (Join-Path $headerSrc 'include\curl') -File -Filter '*.h' | Copy-Item -Destination $incDst
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot
Copy-Item (Join-Path $ngLicenseSrc 'COPYING') -Destination (Join-Path $hdrRoot 'COPYING.nghttp2')
foreach ($must in 'curl.h', 'curlver.h', 'easy.h', 'multi.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\curl\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)",
               "bundled: nghttp2 $nghttp2Version ($nghttp2Url), linked into libcurl.dll",
               "features: libcurl.dll, OpenSSL (linked in), zlib (zlib.dll), Win32 LDAP, SSPI, NTLM, Kerberos, SPNEGO, HTTP2, IDN (Win32), /MD")
Write-PackageSummary $s
