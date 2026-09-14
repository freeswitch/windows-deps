<#
.SYNOPSIS
    curl: builds libcurl as a STATIC library with CMake + the Visual C++
    toolchain, against this repository's OpenSSL and zlib packages, and packages
    it the way FreeSWITCH's w32\curl.props expects (the layout the old
    curl-packaging project produced): the static library is shipped as curl.lib
    and consumers define CURL_STATICLIB and link OpenSSL, zlib and Wldap32
    themselves (curl.props imports openssl.props and zlib.props for that).

    Features match the old packages: OpenSSL (static), zlib (via the zlib import
    library -> zlib.dll at run time), Win32 LDAP, IPv6, SSPI/NTLM via the Windows
    defaults; no HTTP/2, no IDN. Dynamic CRT (/MD).

    Package <pkg> = curl-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/curl/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/<Platform>/<Config>/curl.lib       (static libcurl; libcurl-d.lib renamed in Debug)
                                                                             /libcurl-d.pdb  (Debug only: the compiler PDB of the static lib)
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): CURL_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, CURL_URL, EXTRA_CMAKE, and ZLIB_PKG_BASE /
    ZLIB_PKG, OPENSSL_PKG_BASE / OPENSSL_PKG for the dependency packages
    (scripts\build.ps1 sets those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'curl'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

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

        # Mirrors the old curl-packaging vcxproj: static libcurl with OpenSSL + zlib,
        # everything else at curl's Windows defaults (Win32 LDAP on, SSPI on, IDN
        # off, /MD). Only the library target is built.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DBUILD_CURL_EXE=OFF',
            '-DBUILD_TESTING=OFF',
            '-DCURL_USE_OPENSSL=ON',
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON',
            '-DCURL_ZLIB=ON',
            "-DZLIB_INCLUDE_DIR=`"$(ConvertTo-ForwardSlashes $zlibInclude)`"",
            "-DZLIB_LIBRARY=`"$(ConvertTo-ForwardSlashes $zlibLib)`""
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target libcurl || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "curl build [$plat/$config]"

        # --- verify + stage ------------------------------------------------------
        # curl's CMake: static lib named libcurl.lib, Debug postfix "-d".
        $postfix = if ($config -eq 'Debug') { '-d' } else { '' }
        $lib = Join-Path $bldDir "lib\libcurl$postfix.lib"
        if (-not (Test-Path $lib)) {
            $have = Get-ChildItem -Recurse -File $bldDir -Filter '*.lib' | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
            throw "curl [$plat/$config] did not produce lib\libcurl$postfix.lib. Found: $($have -join ', ')."
        }
        $libText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($lib))
        if ($libText -notmatch 'inflateInit_') { throw "libcurl$postfix.lib has no zlib references -- zlib support did not get enabled." }
        if ($libText -notmatch 'SSL_CTX_new')  { throw "libcurl$postfix.lib has no OpenSSL references -- OpenSSL support did not get enabled." }
        if ($libText -notmatch 'ldap_init')    { throw "libcurl$postfix.lib has no LDAP references -- Win32 LDAP did not get enabled (the old packages had it)." }

        $binDst = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination (Join-Path $binDst 'curl.lib')      # the name curl.props links
        if ($config -eq 'Debug') {
            # Compiler PDB of the static library, wherever the generator put it.
            $pdb = Get-ChildItem -Recurse -File $bldDir -Filter "libcurl$postfix.pdb" | Select-Object -First 1
            if (-not $pdb) { $pdb = Get-ChildItem -Recurse -File (Join-Path $bldDir 'lib') -Filter '*.pdb' | Sort-Object Length -Descending | Select-Object -First 1 }
            if ($pdb) { Copy-Item $pdb.FullName -Destination (Join-Path $binDst "libcurl$postfix.pdb") }
            else { Write-Host "  NOTE: no PDB found for the Debug static library; continuing without it." -ForegroundColor Yellow }
        }
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir }
    }
}

# --- headers zip: the public headers (include/curl/*.h) ---------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include\curl'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Get-ChildItem (Join-Path $headerSrc 'include\curl') -File -Filter '*.h' | Copy-Item -Destination $incDst
foreach ($must in 'curl.h', 'curlver.h', 'easy.h', 'multi.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\curl\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "features: static libcurl, OpenSSL (static), zlib (import lib), Win32 LDAP, /MD")
Write-PackageSummary $s
