<#
.SYNOPSIS
    ffmpeg: builds FFmpeg as shared libraries (avcodec-62.dll, avformat-62.dll,
    ...) with the MSVC toolchain and packages the DLLs, their import libraries
    and the public headers for FreeSWITCH's w32\ffmpeg.props. The consumer is
    mod_av.

    This node replaces the freeswitch/ffmpeg-packaging repository and does what
    its build-deps.ps1 and build-ffmpeg.ps1 did -- the same configure line, the
    same two variants, the same layout inside the zips -- with the package named
    and versioned like every other one here.

    FFmpeg has no MSBuild or CMake project: configure and make need a POSIX
    shell, which MSYS2 provides (make, pkgconf, diffutils, and bzip2 for the
    openh264 download). The compiler is MSVC throughout (--toolchain=msvc), so
    nothing of MSYS2 ends up in the DLLs. NASM assembles the x86 code of FFmpeg
    and x264.

    Variants (VARIANTS, both by default), packaged side by side:
      openh264  LGPL, H.264 encoding through Cisco's openh264 (--enable-libopenh264)
      x264      GPL,  H.264 encoding through x264 (--enable-gpl --enable-libx264)
    Both decode H.264 with FFmpeg's own decoder.

    openh264 is not compiled here. Cisco ships the binary and carries the H.264
    patent licence for it, so FreeSWITCH downloads Cisco's DLL itself (at build
    time w32\download_openh264.props, at install time the MSI's
    Setup.CA.DownloadOpenH264) and no package of ours contains it. avcodec is
    linked against an import library made from the exports of that DLL and
    against the wels headers of the same release. OPENH264_VERSION must
    therefore be the release FreeSWITCH downloads: the headers fix the layout
    of the encoder parameters and of the decoder's vtable, and 2.x inserted
    FlushFrame in the middle of ISVCDecoder. The DLL comes over plain HTTP from
    Cisco, so the script checks that it is Cisco-signed and of that version.

    x264 is built from a pinned commit of its stable branch as
    libx264-<X264_BUILD>.dll, which the x264 zips carry next to avcodec. It sits
    behind a DLL boundary, so one release-CRT x264 serves both configurations.

    Package <pkg> = ffmpeg-<version>_<build>:
      <pkg>-headers.zip                           <pkg>/LICENSE   (LGPL 2.1)
                                                  <pkg>/include/{libavcodec,libavformat,...}/*.h
      <pkg>-<variant>-binaries-x64-<config>.zip   <pkg>/binaries/<variant>/x64/<Config>/
                                                      av*.dll, sw*.dll and their import .lib
                                                      *.pdb                        (Debug only)
                                                      LICENSE                      (LGPL 2.1 / GPL 2)
                                                      OPENH264_BINARY_LICENSE.txt  (openh264)
                                                      libx264-<X264_BUILD>.dll     (x264)
      SHA256SUMS.txt, <pkg>-BOM.txt

    The variant is part of the path inside the zips, so both extract into one
    libs\<pkg>\ without overwriting each other. x64 only, as before.

    Environment (all optional): FFMPEG_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, FFMPEG_URL, VARIANTS, OPENH264_VERSION,
    OPENH264_DLL_URL, OPENH264_URL, X264_COMMIT, X264_URL, MSYS2_ROOT, MAKE_JOBS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'ffmpeg'
$tc = Initialize-Toolchain

# openh264: the release FreeSWITCH downloads (see the synopsis).
$openh264Version = [string](Get-EnvValue 'OPENH264_VERSION' '2.7.0')
$openh264DllUrl  = [string](Get-EnvValue 'OPENH264_DLL_URL' "https://ciscobinary.openh264.org/openh264-$openh264Version-win64.dll.bz2")
$openh264Url     = [string](Get-EnvValue 'OPENH264_URL' "https://github.com/cisco/openh264/archive/refs/tags/v$openh264Version.tar.gz")
# x264: the head of its stable branch (X264_BUILD 165) when this was written.
$x264Commit = [string](Get-EnvValue 'X264_COMMIT' 'b35605ace3ddf7c1a5d67a2eb553f034aef41d55')
$x264Url    = [string](Get-EnvValue 'X264_URL' "https://code.videolan.org/videolan/x264/-/archive/$x264Commit/x264-$x264Commit.tar.gz")
$variants = @(([string](Get-EnvValue 'VARIANTS' 'openh264 x264')) -split '\s+' | Where-Object { $_ })
$jobs     = [string](Get-EnvValue 'MAKE_JOBS' $env:NUMBER_OF_PROCESSORS)

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}
foreach ($p in $s.Platforms) {
    if ($p -ne 'x64') { throw "Unsupported platform '$p': FFmpeg is packaged for x64 only." }
}
foreach ($v in $variants) {
    if ($v -notin @('openh264', 'x264')) { throw "Unsupported variant '$v' (use 'openh264' and/or 'x264')." }
}

# MSYS2: preinstalled at C:\msys64 on GitHub runners, C:\tools\msys64 from choco.
$msys2Root = Get-EnvValue 'MSYS2_ROOT'
if (-not $msys2Root) {
    $msys2Root = @('C:\msys64', 'C:\tools\msys64') | Where-Object { Test-Path (Join-Path $_ 'usr\bin\bash.exe') } | Select-Object -First 1
}
if (-not $msys2Root -or -not (Test-Path (Join-Path $msys2Root 'usr\bin\bash.exe'))) {
    throw "MSYS2 not found (looked in C:\msys64 and C:\tools\msys64; set MSYS2_ROOT)."
}
foreach ($t in 'make', 'pkgconf', 'diff', 'bunzip2') {
    if (-not (Test-Path (Join-Path $msys2Root "usr\bin\$t.exe"))) {
        throw "MSYS2 at $msys2Root has no $t.exe: pacman -S make pkgconf diffutils bzip2 (see deps\ffmpeg\prereqs.ps1)."
    }
}
$bash = Join-Path $msys2Root 'usr\bin\bash.exe'
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) { throw "nasm is not on PATH (see deps\ffmpeg\prereqs.ps1)." }

Write-Host "==================================================================="
Write-Host " ffmpeg          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Variants        : $($variants -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
if ($variants -contains 'openh264') { Write-Host " openh264        : $openh264Version (import library of $openh264DllUrl)" }
if ($variants -contains 'x264')     { Write-Host " x264            : $x264Commit" }
Write-Host " MSYS2           : $msys2Root"
Write-Host " make -j         : $jobs"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# C:\a\b -> /c/a/b
function ConvertTo-MsysPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') { return "/$($Matches[1].ToLower())/$($Matches[2])" }
    $p
}

# Runs a bash script under MSYS2 inside the MSVC x64 environment. vcvarsall puts
# cl, link and nasm on PATH; MSYS2_PATH_TYPE=inherit hands that PATH to the login
# shell, which puts /usr/bin in front of it -- and coreutils' link.exe would then
# shadow MSVC's, so the script moves cl.exe's directory back to the front.
function Invoke-MsysScript([string]$Script, [string]$Name, [string]$Label) {
    $sh = Join-Path $s.BuildRoot "$Name.sh"
    $prelude = 'set -e' + "`n" + 'export PATH="$(cygpath -u "$CL_DIR"):$PATH"' + "`n"
    [System.IO.File]::WriteAllText($sh, ((($prelude + $Script) -replace "`r`n", "`n").TrimEnd() + "`n"))
    $bat = @"
@echo on
call "$($tc.VcVarsAll)" x64 || exit /b 1
set CL_DIR=
for /f "delims=" %%i in ('where cl.exe') do if not defined CL_DIR set "CL_DIR=%%~dpi"
if not defined CL_DIR (echo cl.exe is not on PATH after vcvarsall & exit /b 1)
set MSYS2_PATH_TYPE=inherit
set CHERE_INVOKING=1
set MSYSTEM=MSYS
"$bash" -lc "bash '$(ConvertTo-MsysPath $sh)'" || exit /b 1
"@
    Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $s.BuildRoot "$Name.bat") -LogFile (Join-Path $s.OutDir "$Name.log") -Label $Label
}

# Runs one batch in the MSVC x64 environment (dumpbin, lib).
function Invoke-VcBatch([string]$Commands, [string]$Name, [string]$Label) {
    $bat = "@echo on`r`ncall `"$($tc.VcVarsAll)`" x64 || exit /b 1`r`n$Commands"
    Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $s.BuildRoot "$Name.bat") -LogFile (Join-Path $s.BuildRoot "$Name.log") -Label $Label
}

# --- FFmpeg source -------------------------------------------------------------
$tarball = Join-Path $s.BuildRoot "ffmpeg-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
Expand-Tarball $tarball $s.BuildRoot $tc
$src = Join-Path $s.BuildRoot "ffmpeg-$($s.Version)"
if (-not (Test-Path (Join-Path $src 'configure'))) { throw "Tarball did not expand to an FFmpeg tree at '$src'." }
$declared = (Get-Content (Join-Path $src 'VERSION') -Raw).Trim()
if ($declared -ne $s.Version) { throw "VERSION in the tarball says $declared but deps.json says $($s.Version)." }

# The libraries and their majors, which name the DLLs (avcodec-62.dll). postproc
# only exists up to FFmpeg 7 and only in GPL builds.
$majors = [ordered]@{}
# The define sits in version_major.h or, for libavutil, in version.h.
foreach ($l in 'avutil', 'avcodec', 'avformat', 'avdevice', 'avfilter', 'swscale', 'swresample', 'postproc') {
    if (-not (Test-Path (Join-Path $src "lib$l"))) { continue }
    $name = $l.ToUpper()
    foreach ($vh in 'version_major.h', 'version.h') {
        $f = Join-Path $src "lib$l\$vh"
        if ((Test-Path $f) -and ((Get-Content $f -Raw) -match "#define\s+LIB${name}_VERSION_MAJOR\s+([0-9]+)")) { $majors[$l] = $Matches[1]; break }
    }
    if (-not $majors.Contains($l)) { throw "lib$l declares no LIB${name}_VERSION_MAJOR." }
}
Write-Host ("FFmpeg $($s.Version) libraries: " + (($majors.Keys | ForEach-Object { "$_-$($majors[$_])" }) -join ', '))

# --- openh264: import library + headers of Cisco's release ---------------------
$depsPrefix = @{}
$openh264Signer = $null
if ($variants -contains 'openh264') {
    $ohPrefix = Join-Path $s.BuildRoot 'deps-openh264'
    $ohInc = Join-Path $ohPrefix 'include\wels'
    $ohLib = Join-Path $ohPrefix 'lib'
    New-Item -ItemType Directory -Force -Path $ohInc, (Join-Path $ohLib 'pkgconfig') | Out-Null

    $bz = Join-Path $s.BuildRoot "openh264-$openh264Version-win64.dll.bz2"
    Get-RemoteFile $openh264DllUrl $bz
    & (Join-Path $msys2Root 'usr\bin\bunzip2.exe') -f -k $bz
    if ($LASTEXITCODE -ne 0) { throw "bunzip2 failed on $bz." }
    $ohDll = $bz -replace '\.bz2$', ''
    if (-not (Test-Path $ohDll)) { throw "bunzip2 did not produce $ohDll." }

    $sig = Get-AuthenticodeSignature $ohDll
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O="?CISCO SYSTEMS') {
        throw "$ohDll is not validly signed by Cisco (status $($sig.Status), signer '$($sig.SignerCertificate.Subject)')."
    }
    $fileVersion = (Get-Item $ohDll).VersionInfo.FileVersion
    if (-not $fileVersion -or -not $fileVersion.StartsWith("$openh264Version.")) {
        throw "$ohDll is version '$fileVersion', expected $openh264Version.*."
    }
    $openh264Signer = $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    Write-Host "openh264 DLL $fileVersion, signed by $openh264Signer"

    # An import library naming openh264.dll -- the file name FreeSWITCH gives it.
    $expFile = Join-Path $s.BuildRoot 'openh264-exports.txt'
    Invoke-VcBatch "dumpbin /nologo /exports `"$ohDll`" > `"$expFile`" || exit /b 1" 'openh264-exports' 'openh264 dumpbin /exports'
    $names = @(Get-Content $expFile | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\w+)\s*$') { $Matches[1] } })
    foreach ($must in 'WelsCreateSVCEncoder', 'WelsDestroySVCEncoder', 'WelsCreateDecoder', 'WelsDestroyDecoder', 'WelsGetCodecVersion') {
        if ($names -notcontains $must) { throw "openh264 $openh264Version does not export $must." }
    }
    $def = Join-Path $s.BuildRoot 'openh264.def'
    Set-Content -Path $def -Encoding ASCII -Value (@('LIBRARY openh264.dll', 'EXPORTS') + $names)
    Invoke-VcBatch "lib /nologo /def:`"$def`" /machine:X64 /out:`"$ohLib\openh264.lib`" || exit /b 1" 'openh264-lib' 'openh264 import library'

    # The wels headers of the same release, and nothing else of its tree.
    $ohTarball = Join-Path $s.BuildRoot "openh264-$openh264Version.tar.gz"
    Get-RemoteFile $openh264Url $ohTarball
    & $tc.Tar -xf $ohTarball -C $s.BuildRoot "openh264-$openh264Version/codec/api/wels"
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract codec/api/wels from '$ohTarball'." }
    $ohApi = Join-Path $s.BuildRoot "openh264-$openh264Version\codec\api\wels"
    if (-not (Test-Path $ohApi)) { throw "openh264 tarball has no codec\api\wels at '$ohApi'." }
    Copy-Item (Join-Path $ohApi '*.h') -Destination $ohInc
    $cv = Get-Content (Join-Path $ohInc 'codec_ver.h') -Raw
    $hv = foreach ($part in 'MAJOR', 'MINOR', 'REVISION') {
        if ($cv -notmatch "#define\s+OPENH264_$part\s+\(?([0-9]+)\)?") { throw "codec_ver.h defines no OPENH264_$part." }
        $Matches[1]
    }
    if (($hv -join '.') -ne $openh264Version) { throw "codec_ver.h declares $($hv -join '.') but OPENH264_VERSION is $openh264Version." }

    @"
prefix=$(ConvertTo-ForwardSlashes $ohPrefix)
includedir=`${prefix}/include
libdir=`${prefix}/lib

Name: openh264
Description: OpenH264 (import library of Cisco's prebuilt DLL)
Version: $openh264Version
Libs: -L`${libdir} -lopenh264
Cflags: -I`${includedir}
"@ | Set-Content -Encoding ASCII (Join-Path $ohLib 'pkgconfig\openh264.pc')
    $depsPrefix['openh264'] = $ohPrefix
}

# --- x264: shared libx264-<X264_BUILD>.dll ------------------------------------
$x264Dll = $null
$x264Build = $null
if ($variants -contains 'x264') {
    $xPrefix = Join-Path $s.BuildRoot 'deps-x264'
    $xTarball = Join-Path $s.BuildRoot "x264-$x264Commit.tar.gz"
    Get-RemoteFile $x264Url $xTarball
    Expand-Tarball $xTarball $s.BuildRoot $tc
    $xSrc = Join-Path $s.BuildRoot "x264-$x264Commit"
    if (-not (Test-Path (Join-Path $xSrc 'configure'))) { throw "x264 tarball did not expand to '$xSrc'." }
    if ((Get-Content (Join-Path $xSrc 'x264.h') -Raw) -notmatch '#define\s+X264_BUILD\s+([0-9]+)') { throw "x264.h defines no X264_BUILD." }
    $x264Build = $Matches[1]

    Invoke-MsysScript -Name 'build-x264' -Label 'x264 build' -Script @"
cd "$(ConvertTo-MsysPath $xSrc)"
CC=cl ./configure --enable-shared --disable-cli --disable-opencl --prefix="$(ConvertTo-MsysPath $xPrefix)" --extra-cflags="-MD -O2"
make -j$jobs
make install
"@
    $x264Dll = Join-Path $xPrefix "bin\libx264-$x264Build.dll"
    if (-not (Test-Path $x264Dll)) { throw "x264 did not install $x264Dll." }
    # FFmpeg's MSVC link turns -lx264 into libx264.lib; x264 installs the import
    # library as libx264.dll.lib.
    $xLib = Join-Path $xPrefix 'lib\libx264.lib'
    if (-not (Test-Path $xLib)) {
        $imp = Get-ChildItem (Join-Path $xPrefix 'lib') -File | Where-Object { $_.Name -match '^libx264.*\.lib$' } | Select-Object -First 1
        if (-not $imp) { throw "x264 installed no import library under $xPrefix\lib." }
        Copy-Item $imp.FullName $xLib
    }
    $depsPrefix['x264'] = $xPrefix
}

# --- FFmpeg, per variant and configuration -------------------------------------
# The configure line of ffmpeg-packaging. MSVC builds need optimisation to link,
# so Debug is -O2 too and differs by the debug CRT, --enable-debug and -debug.
# --target-os=win32 is FFmpeg's name for Windows on x64 as well.
$commonArgs = '--toolchain=msvc --arch=x86_64 --target-os=win32 --enable-shared --disable-static --enable-optimizations ' +
              '--disable-programs --disable-doc --enable-runtime-cpudetect --enable-w32threads --pkg-config=pkg-config --pkg-config-flags=--static'
$variantArgs = @{ openh264 = '--enable-libopenh264'; x264 = '--enable-gpl --enable-libx264' }
$headerSrc = $null
foreach ($variant in $variants) {
    $prefixWin = ConvertTo-ForwardSlashes $depsPrefix[$variant]
    $libs = @($majors.Keys | Where-Object { $_ -ne 'postproc' -or $variant -eq 'x264' })

    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building FFmpeg $($s.Version)  [$variant / x64 / $config]"
        Write-Host "-------------------------------------------------------------------"
        $crt, $ldflags, $dbg = if ($config -eq 'Debug') { '-MDd', '-debug', '--enable-debug' } else { '-MD', '', '--disable-debug' }
        $bdir    = Join-Path $s.BuildRoot "build-$variant-$config"
        $install = Join-Path $bdir 'install'
        $configureArgs = @(
            $commonArgs,
            "--extra-cflags=`"-I$prefixWin/include -DHAVE_UNISTD_H=0 -D_WIN32_WINNT=0x0602 -DWINVER=0x0602 $crt -O2`"",
            "--extra-cxxflags=`"$crt -O2`"",
            "--extra-ldflags=`"-libpath:$prefixWin/lib $ldflags`"",
            $dbg, $variantArgs[$variant]
        ) -join ' '
        $script = @"
export PKG_CONFIG_PATH="$(ConvertTo-MsysPath $depsPrefix[$variant])/lib/pkgconfig"
mkdir -p "$(ConvertTo-MsysPath $bdir)"
cd "$(ConvertTo-MsysPath $bdir)"
"$(ConvertTo-MsysPath $src)/configure" --prefix="$(ConvertTo-MsysPath $install)" $configureArgs || { tail -n 80 ffbuild/config.log; exit 1; }
make -j$jobs
make install
"@
        Invoke-MsysScript -Script $script -Name "build-$variant-$config" -Label "FFmpeg build [$variant/x64/$config]"

        # --- verify + stage --------------------------------------------------
        $binDst = Join-Path $stage "bin-$variant-$config\$($s.Pkg)\binaries\$variant\x64\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        foreach ($l in $libs) {
            $dll = Join-Path $install "bin\$l-$($majors[$l]).dll"
            if (-not (Test-Path $dll)) { throw "FFmpeg [$variant/$config] did not install $dll." }
            # MSVC builds install the import library next to the DLL.
            $imp = @((Join-Path $install "bin\$l.lib"), (Join-Path $install "lib\$l.lib")) | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $imp) { throw "FFmpeg [$variant/$config] installed no import library $l.lib." }
            Copy-Item $dll, $imp -Destination $binDst
            if ($config -eq 'Debug') {
                $pdb = Join-Path $bdir "lib$l\$l-$($majors[$l]).pdb"
                if (Test-Path $pdb) { Copy-Item $pdb -Destination $binDst }
                else { Write-Host "WARNING: no $l-$($majors[$l]).pdb under $bdir\lib$l; the Debug package goes without it." -ForegroundColor Yellow }
            }
        }

        # avcodec must import the codec library of its variant and nothing else
        # from outside Windows and FFmpeg.
        $depFile = Join-Path $s.BuildRoot "dependents-$variant-$config.txt"
        $avcodec = Join-Path $install "bin\avcodec-$($majors['avcodec']).dll"
        Invoke-VcBatch "dumpbin /nologo /dependents `"$avcodec`" > `"$depFile`" || exit /b 1" "dependents-$variant-$config" "avcodec dependents [$variant/$config]"
        $deps = @(Get-Content $depFile | ForEach-Object { if ($_ -match '^\s+(\S+\.dll)\s*$') { $Matches[1] } })
        $codecDll = if ($variant -eq 'x264') { "libx264-$x264Build.dll" } else { 'openh264.dll' }
        if ($deps -notcontains $codecDll) { throw "avcodec [$variant/$config] does not import $codecDll (imports: $($deps -join ', '))." }
        Write-Host "avcodec [$variant/$config] imports: $($deps -join ', ')"

        $lic = if ($variant -eq 'x264') { 'COPYING.GPLv2' } else { 'COPYING.LGPLv2.1' }
        Copy-Item (Join-Path $src $lic) -Destination (Join-Path $binDst 'LICENSE')
        if ($variant -eq 'openh264') {
            # Cisco's binary licence travels with software that uses its DLL.
            Copy-Item (Join-Path $PSScriptRoot 'OPENH264_BINARY_LICENSE.txt') -Destination $binDst
        } else {
            Copy-Item $x264Dll -Destination $binDst
        }
        New-PackageZip (Join-Path $stage "bin-$variant-$config\$($s.Pkg)") (Join-Path $s.OutDir ("$($s.Pkg)-$variant-binaries-x64-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = Join-Path $install 'include' }
    }
}

# --- headers zip -------------------------------------------------------------------
# The public headers do not depend on variant or configuration; take the first
# install's.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $headerSrc '*') -Destination $incDst -Recurse
Copy-Item (Join-Path $src 'COPYING.LGPLv2.1') -Destination (Join-Path $hdrRoot 'LICENSE')
foreach ($must in 'libavcodec\avcodec.h', 'libavformat\avformat.h', 'libavutil\avconfig.h', 'libavutil\ffversion.h', 'libswscale\swscale.h', 'libswresample\swresample.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
$dllNames = ($majors.Keys | ForEach-Object { "$_-$($majors[$_]).dll" }) -join ', '
$bom = @("toolchain: $($tc.VsInstall), MSYS2 $msys2Root",
         "libraries: $dllNames",
         "variants: $($variants -join ', ')",
         "configure: $commonArgs --extra-cflags=`"-I<deps> -DHAVE_UNISTD_H=0 -D_WIN32_WINNT=0x0602 -DWINVER=0x0602 -MD|-MDd -O2`" --enable-debug|--disable-debug")
foreach ($v in $variants) { $bom += "configure ${v}: $($variantArgs[$v])" }
if ($variants -contains 'openh264') { $bom += "openh264: $openh264Version, import library of $openh264DllUrl (signed by $openh264Signer), headers $openh264Url" }
if ($variants -contains 'x264')     { $bom += "x264: $x264Commit (X264_BUILD $x264Build) from $x264Url, libx264-$x264Build.dll bundled" }
Write-Bom $s $bom
Write-PackageSummary $s
