<#
.SYNOPSIS
    rabbitmq-c: builds the static librabbitmq.4.lib (with SSL support against this
    repository's OpenSSL package) with CMake + the Visual C++ toolchain, and
    packages it the way FreeSWITCH's w32\rabbitmq-c.props expects (the layout the
    old rabbitmq-c-packaging project produced; consumer: mod_amqp).

    Package <pkg> = rabbitmq-c-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE
                                              <pkg>/include/{amqp.h, amqp_framing.h, amqp_ssl_socket.h, amqp_tcp_socket.h}   (compat shims)
                                              <pkg>/include/rabbitmq-c/{amqp.h, framing.h, ssl_socket.h, tcp_socket.h, export.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE
                                              <pkg>/binaries/<Platform>/<Config>/librabbitmq.4.lib   (static; "4" is rabbitmq-c's SOVERSION)
                                                                             /librabbitmq.4.pdb   (Debug only, if produced)
      SHA256SUMS.txt, <pkg>-BOM.txt

    OpenSSL is referenced, not linked, by the static library: consumers link the
    OpenSSL package themselves (and should define AMQP_STATIC; see the packaged
    rabbitmq-c.props). Dynamic CRT (/MD), rabbitmq-c's default.

    Environment (all optional): RABBITMQ_C_VERSION, BUILD_NUMBER, PKG_NAME,
    CONFIGS, PLATFORMS, OUT_DIR, BUILD_ROOT, RABBITMQ_C_URL, EXTRA_CMAKE, and
    OPENSSL_PKG_BASE / OPENSSL_PKG for the OpenSSL package (scripts\build.ps1 sets
    those from the plan or from release tags).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'rabbitmq-c'
$tc = Initialize-Toolchain
$extraCMake = [string](Get-EnvValue 'EXTRA_CMAKE' '')

$cmakeCmd = Get-Command cmake.exe -ErrorAction SilentlyContinue
if (-not $cmakeCmd) { throw "cmake.exe not found on PATH. Install CMake (>= 3.22) or Visual Studio's 'C++ CMake tools for Windows' component." }
$cmakeVersion = (& $cmakeCmd.Source --version | Select-Object -First 1)
foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " rabbitmq-c      : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
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

$tarball = Join-Path $s.BuildRoot "rabbitmq-c-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$depCache = Join-Path $s.BuildRoot 'deps'

$headerSrc = $null   # source tree of the first build
$exportH   = $null   # generated include/rabbitmq-c/export.h of the first build

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building rabbitmq-c $($s.Version)  [$plat / $config]  (NMake Makefiles, CMAKE_BUILD_TYPE=$config)"
        Write-Host "-------------------------------------------------------------------"

        $work   = Join-Path $s.BuildRoot "build-$plat-$config"
        $srcDir = Join-Path $work "rabbitmq-c-$($s.Version)"   # GitHub tag archive of v<ver>
        $bldDir = Join-Path $work 'build'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        if (-not (Test-Path $srcDir)) { throw "Tarball did not expand to '$srcDir'." }

        # The version rabbitmq-c's CMake derives from include/rabbitmq-c/amqp.h must match the manifest.
        $hdr = Get-Content (Join-Path $srcDir 'include\rabbitmq-c\amqp.h') -Raw
        $vparts = foreach ($k in 'MAJOR', 'MINOR', 'PATCH') { if ($hdr -match "(?m)^#define AMQP_VERSION_$k (\d+)") { $Matches[1] } else { throw "AMQP_VERSION_$k not found in rabbitmq-c/amqp.h" } }
        $srcVer = $vparts -join '.'
        if ($srcVer -ne $s.Version) { throw "rabbitmq-c source declares version $srcVer but deps.json says $($s.Version)." }

        $sslRoot = Get-OpenSSLRootForCMake -Platform $plat -Config $config -CacheDir $depCache

        # Mirrors the old rabbitmq-c-packaging vcxproj (cmake + the static target only),
        # minus the Visual Studio generator.
        $configureArgs = @(
            "-S `"$(ConvertTo-ForwardSlashes $srcDir)`"",
            "-B `"$(ConvertTo-ForwardSlashes $bldDir)`"",
            '-G "NMake Makefiles"',
            "-DCMAKE_BUILD_TYPE=$config",
            '-DBUILD_SHARED_LIBS=OFF',
            '-DBUILD_STATIC_LIBS=ON',
            '-DENABLE_SSL_SUPPORT=ON',
            "-DOPENSSL_ROOT_DIR=`"$(ConvertTo-ForwardSlashes $sslRoot)`"",
            '-DOPENSSL_USE_STATIC_LIBS=ON',
            '-DBUILD_EXAMPLES=OFF',
            '-DBUILD_TOOLS=OFF',
            '-DBUILD_API_DOCS=OFF',
            '-DBUILD_TESTING=OFF'
        )
        if ($extraCMake) { $configureArgs += $extraCMake }

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cmake $($configureArgs -join ' ') || exit /b 1
cmake --build "$bldDir" --target rabbitmq-static || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "rabbitmq-c build [$plat/$config]"

        # --- verify + stage ------------------------------------------------------
        $lib = Get-ChildItem -Recurse -File $bldDir -Filter 'librabbitmq.*.lib' | Select-Object -First 1
        if (-not $lib) {
            $have = Get-ChildItem -Recurse -File $bldDir -Filter '*.lib' | ForEach-Object { $_.FullName.Substring($bldDir.Length + 1) }
            throw "rabbitmq-c [$plat/$config] did not produce librabbitmq.<soversion>.lib. Found: $($have -join ', ')."
        }
        if ($lib.Name -ne 'librabbitmq.4.lib') { throw "rabbitmq-c produced '$($lib.Name)': its SOVERSION changed, FreeSWITCH's rabbitmq-c.props links librabbitmq.4.lib." }
        $libText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($lib.FullName))
        if ($libText -notmatch 'amqp_tcp_socket_new') { throw "librabbitmq.4.lib lacks amqp_tcp_socket_new -- unexpected build result." }
        if ($libText -notmatch 'SSL_CTX_new')         { throw "librabbitmq.4.lib has no OpenSSL references -- SSL support did not get enabled." }
        $gen = Join-Path $bldDir 'include\rabbitmq-c\export.h'
        if (-not (Test-Path $gen)) { throw "Generated export header not found at '$gen'." }

        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib.FullName -Destination $binDst
        Copy-Item (Join-Path $srcDir 'LICENSE') -Destination $pkgRoot
        if ($config -eq 'Debug') {
            $pdb = Get-ChildItem -Recurse -File $bldDir -Filter 'librabbitmq.*.pdb' | Select-Object -First 1
            if ($pdb) { Copy-Item $pdb.FullName -Destination $binDst }
        }
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $srcDir; $exportH = $gen }
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path (Join-Path $incDst 'rabbitmq-c') | Out-Null
Copy-Item (Join-Path $headerSrc 'LICENSE') -Destination $hdrRoot
foreach ($f in 'amqp.h', 'amqp_framing.h', 'amqp_ssl_socket.h', 'amqp_tcp_socket.h') { Copy-Item (Join-Path $headerSrc "include\$f") -Destination $incDst }
foreach ($f in 'amqp.h', 'framing.h', 'ssl_socket.h', 'tcp_socket.h') { Copy-Item (Join-Path $headerSrc "include\rabbitmq-c\$f") -Destination (Join-Path $incDst 'rabbitmq-c') }
Copy-Item $exportH -Destination (Join-Path $incDst 'rabbitmq-c')
foreach ($must in 'amqp.h', 'rabbitmq-c\amqp.h', 'rabbitmq-c\export.h', 'rabbitmq-c\ssl_socket.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("cmake: $cmakeVersion", "toolchain: $($tc.VsInstall)", "features: static, SSL (OpenSSL referenced, consumer links it), /MD")
Write-PackageSummary $s
