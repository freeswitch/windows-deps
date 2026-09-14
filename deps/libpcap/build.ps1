<#
.SYNOPSIS
    libpcap: builds the static pcap_static.lib with CMake + the Visual C++
    toolchain and packages it the way FreeSWITCH's w32\libpcap.props expects (the
    layout the old libpcap-packaging project produced).

    Built without a packet-capture driver SDK (-DPCAP_TYPE=null): the library
    reads and writes pcap/pcapng files, which is what FreeSWITCH uses it for; it
    cannot capture live traffic. Remote capture (rpcap) is off, so OpenSSL is not
    involved and this node has no dependencies. Static CRT (/MT), libpcap's
    default on MSVC and what the old packages shipped. flex/bison come from
    winflexbison, downloaded at build time (WINFLEX_VERSION / WINFLEX_URL).

    Package <pkg> = libpcap-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/include/{pcap.h, pcap-bpf.h, pcap-namedb.h, LICENSE}
                                              <pkg>/include/pcap/*.h
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/binaries/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/pcap_static.lib
                                                                             /pcap_static.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LIBPCAP_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBPCAP_URL, EXTRA_CMAKE, WINFLEX_VERSION,
    WINFLEX_URL.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libpcap'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')
$winflexVer = [string](Get-EnvValue 'WINFLEX_VERSION' '2.5.25')
$winflexUrl = [string](Get-EnvValue 'WINFLEX_URL' "https://github.com/lexxmark/winflexbison/releases/download/v$winflexVer/win_flex_bison-$winflexVer.zip")

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.19) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " libpcap         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " winflexbison    : $winflexVer ($winflexUrl)"
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

$tarball = Join-Path $s.BuildRoot "libpcap-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

# --- flex + bison (winflexbison) -------------------------------------------------
$toolsDir  = Join-Path $s.BuildRoot 'tools'
$flexZip   = Join-Path $toolsDir "win_flex_bison-$winflexVer.zip"
$flexDir   = Join-Path $toolsDir "win_flex_bison-$winflexVer"
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
Get-RemoteFile $winflexUrl $flexZip
Expand-Archive -Path $flexZip -DestinationPath $flexDir -Force
$winFlex  = Join-Path $flexDir 'win_flex.exe'
$winBison = Join-Path $flexDir 'win_bison.exe'
foreach ($t in $winFlex, $winBison) { if (-not (Test-Path $t)) { throw "winflexbison archive does not contain '$(Split-Path $t -Leaf)'." } }

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building libpcap $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "libpcap-libpcap-$($s.Version)"   # GitHub tag archive of tag libpcap-<ver>
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        $srcVer = (Get-Content (Join-Path $srcDir 'VERSION') -Raw).Trim()
        if ($srcVer -ne $s.Version) { throw "libpcap source declares version $srcVer but deps.json says $($s.Version)." }

        # Mirrors the old libpcap-packaging vcxproj (cmake + static library only).
        # -D_CRT_DECLARE_NONSTDC_NAMES is what its patched CMakeLists.txt added:
        # libpcap defines __STDC__, which makes the UCRT hide strdup() & co.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DPCAP_TYPE=null',
            '-DENABLE_REMOTE=OFF',
            '-DUSE_STATIC_RT=ON',
            '-DCMAKE_C_FLAGS=-D_CRT_DECLARE_NONSTDC_NAMES',
            "-DLEX_EXECUTABLE=`"$(ConvertTo-ForwardSlashes $winFlex)`"",
            "-DYACC_EXECUTABLE=`"$(ConvertTo-ForwardSlashes $winBison)`""
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target pcap_static || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "libpcap build [$plat/$config]"

        # --- verify + stage ------------------------------------------------------
        $lib = Join-Path $bldDir 'pcap_static.lib'
        if (-not (Test-Path $lib)) {
            $have = Get-ChildItem -Recurse -File $bldDir -Filter '*.lib' | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
            throw "libpcap [$plat/$config] did not produce pcap_static.lib. Found: $($have -join ', ')."
        }
        $libText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($lib))
        if ($libText -notmatch 'pcap_dump_open')     { throw "pcap_static.lib does not contain pcap_dump_open -- unexpected build result." }
        if ($libText -match 'PacketOpenAdapter')     { throw "pcap_static.lib references the Npcap Packet API although PCAP_TYPE=null was requested." }
        if ($libText -match 'SSL_CTX_new')           { throw "pcap_static.lib references OpenSSL although remote capture is off (this node declares no OpenSSL dependency)." }

        $binRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)\binaries"
        $binDst  = Join-Path $binRoot "$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $srcDir 'LICENSE') -Destination $binRoot
        if ($config -eq 'Debug') {
            $pdb = Join-Path $bldDir 'pcap_static.pdb'   # COMPILE_PDB_NAME set by libpcap's CMake
            if (-not (Test-Path $pdb)) { $pdb = Get-ChildItem -Recurse -File $bldDir -Filter 'pcap_static*.pdb' | Select-Object -First 1 -ExpandProperty FullName }
            if ($pdb) { Copy-Item $pdb -Destination (Join-Path $binDst 'pcap_static.pdb') }
            else { Write-Host "  NOTE: pcap_static.pdb not found; continuing without it." -ForegroundColor Yellow }
        }
        New-PackageZip (Join-Path $stage "bin-$plat-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir }
    }
}

# --- headers zip ---------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path (Join-Path $incDst 'pcap') | Out-Null
foreach ($f in 'pcap.h', 'pcap-bpf.h', 'pcap-namedb.h', 'LICENSE') { Copy-Item (Join-Path $headerSrc $f) -Destination $incDst }
Get-ChildItem (Join-Path $headerSrc 'pcap') -File -Filter '*.h' | Copy-Item -Destination (Join-Path $incDst 'pcap')
foreach ($must in 'pcap.h', 'pcap\pcap.h', 'pcap\dlt.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "winflexbison: $winflexVer", "features: static, PCAP_TYPE=null (savefiles only), no remote capture, /MT")
Write-PackageSummary $s
