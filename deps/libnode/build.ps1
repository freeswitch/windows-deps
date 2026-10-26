<#
.SYNOPSIS
    libnode: builds Node.js as a shared library (libnode.dll) with Node's own
    vcbuild.bat and packages the DLL, its import library and the V8 headers for
    FreeSWITCH's w32\libnode.props. The consumer is mod_v8, which embeds V8
    through libnode on Windows the way it uses Debian's libnode-dev on Linux.

    This node replaces the freeswitch/libnode-packaging repository and does what
    its build-libnode.ps1 did -- the same vcbuild invocation, the same
    common.gypi patch, the same package layout -- with the package named and
    versioned like every other one here. The source is the release tarball from
    nodejs.org rather than a git clone, so the build needs no git.

    vcbuild.bat locates Visual Studio and enters its environment by itself, and
    from Node 24 on it insists on ClangCL: the install needs the "C++ Clang
    Compiler for Windows" and "MSBuild support for LLVM (clang-cl) toolset"
    components besides the C++ workload. NASM assembles the bundled OpenSSL and
    Python runs gyp. `dll` configures --shared, `nonpm` leaves npm out, which
    mod_v8 has no use for.

    libplatform: Node compiles V8's libplatform into libnode, but marks its API
    dllexport only under BUILDING_V8_PLATFORM_SHARED, which Node's common.gypi
    does not define. Without it mod_v8 cannot link
    v8::platform::NewDefaultPlatform. The script adds the define next to
    BUILDING_V8_SHARED in common.gypi, whose defines reach every target, and
    checks the export is in the DLL after the build.

    Package <pkg> = libnode-<version>_<build>:
      <pkg>-headers.zip                  <pkg>/LICENSE
                                         <pkg>/include/...   (deps\v8\include: v8*.h, cppgc\, libplatform\)
      <pkg>-binaries-x64-<config>.zip    <pkg>/LICENSE
                                         <pkg>/binaries/x64/<Config>/{libnode.dll, libnode.lib}
                                                                    /libnode.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    LICENSE is Node's aggregated licence file: Node itself plus everything linked
    into libnode.dll (V8, OpenSSL, ICU, libuv, zlib, ...).

    x64 only: Node does not build for 32 bit Windows.

    Environment (all optional): LIBNODE_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LIBNODE_URL, VCBUILD_ARGS (extra vcbuild.bat
    arguments).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'libnode'
$tc = Initialize-Toolchain
$extraArgs = [string](Get-EnvValue 'VCBUILD_ARGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}
foreach ($p in $s.Platforms) {
    if ($p -ne 'x64') { throw "Unsupported platform '$p': Node.js builds only for x64 here (there is no 32 bit Windows build)." }
}

Write-Host "==================================================================="
Write-Host " libnode         : $($s.Version) (build $($s.Build), package $($s.Pkg))"
Write-Host " Source URL      : $($s.SourceUrl)"
Write-Host " Platforms       : $($s.Platforms -join ', ')"
Write-Host " Configs         : $($s.Configs -join ', ')"
Write-Host " Extra vcbuild   : $extraArgs"
Write-Host " VS install      : $($tc.VsInstall)"
Write-Host " Build root      : $($s.BuildRoot)"
Write-Host " Output dir      : $($s.OutDir)"
Write-Host "==================================================================="

Reset-Directory $s.BuildRoot
New-Item -ItemType Directory -Force -Path $s.OutDir | Out-Null
$stage = Join-Path $s.BuildRoot 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# One source tree serves every configuration: vcbuild builds into out\<Config>.
# Python extracts it, not Windows' bsdtar: test\fixtures\copy\utf\ holds a folder
# named in Chinese, bsdtar converts names through the ANSI code page, cannot, and
# fails the whole extraction (excluding the folder does not help, the name is
# converted before the pattern is matched). Python, which the build needs for
# gyp anyway, reads the names as UTF-8. The 'data' filter, where this Python has
# it, refuses absolute paths and links leaving the tree.
$tarball = Join-Path $s.BuildRoot "node-v$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball
$python = (Get-Command python -ErrorAction Stop).Source
Write-Host "Extracting $tarball with $python ..."
& $python -I -c "import sys, tarfile; kw = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}; tarfile.open(sys.argv[1]).extractall(sys.argv[2], **kw)" $tarball $s.BuildRoot
if ($LASTEXITCODE -ne 0) { throw "Failed to extract '$tarball' into '$($s.BuildRoot)'." }
$src = Join-Path $s.BuildRoot "node-v$($s.Version)"
if (-not (Test-Path $src)) { throw "Tarball did not expand to '$src'." }

# The version node_version.h declares must match the manifest.
$nh = Get-Content (Join-Path $src 'src\node_version.h') -Raw
$ver = foreach ($part in 'MAJOR', 'MINOR', 'PATCH') {
    if ($nh -notmatch "#define\s+NODE_${part}_VERSION\s+([0-9]+)") { throw "node_version.h defines no NODE_${part}_VERSION." }
    $Matches[1]
}
if (($ver -join '.') -ne $s.Version) { throw "node_version.h declares $($ver -join '.') but deps.json says $($s.Version)." }

# The V8 a consumer compiles against, for the BOM.
$vh = Get-Content (Join-Path $src 'deps\v8\include\v8-version.h') -Raw
$v8 = foreach ($part in 'MAJOR_VERSION', 'MINOR_VERSION', 'BUILD_NUMBER', 'PATCH_LEVEL') {
    if ($vh -notmatch "#define\s+V8_$part\s+([0-9]+)") { throw "v8-version.h defines no V8_$part." }
    $Matches[1]
}
$v8Version = $v8 -join '.'
Write-Host "Node $($s.Version) bundles V8 $v8Version"

# Export libplatform from libnode.dll (see the synopsis).
$gypi = Join-Path $src 'common.gypi'
$txt  = Get-Content $gypi -Raw
if ($txt -match 'BUILDING_V8_PLATFORM_SHARED') {
    Write-Host "common.gypi already defines BUILDING_V8_PLATFORM_SHARED."
} else {
    $anchor = "(?m)^([ \t]*)'BUILDING_V8_SHARED=1',"
    if ($txt -notmatch $anchor) { throw "common.gypi has no 'BUILDING_V8_SHARED=1' to add BUILDING_V8_PLATFORM_SHARED next to." }
    $txt = $txt -replace $anchor, "`$1'BUILDING_V8_SHARED=1',`n`$1'BUILDING_V8_PLATFORM_SHARED=1',"
    [System.IO.File]::WriteAllText($gypi, $txt)
    Write-Host "Patched common.gypi: BUILDING_V8_PLATFORM_SHARED=1."
}

# What mod_v8 cannot do without: the platform the patch above exports, and the
# entry points every embedder starts with.
$requiredExports = @('NewDefaultPlatform@platform@v8@@', 'Initialize@V8@v8@@', 'New@Isolate@v8@@', 'NewFromUtf8@String@v8@@')

$clangVersion = $null
foreach ($config in $s.Configs) {
    Write-Host "-------------------------------------------------------------------"
    Write-Host "Building libnode $($s.Version)  [x64 / $config]  (vcbuild dll $($config.ToLower()) x64 nonpm $extraArgs)"
    Write-Host "-------------------------------------------------------------------"

    $bat = @"
@echo on
cd /d "$src" || exit /b 1
call "$src\vcbuild.bat" dll $($config.ToLower()) x64 nonpm $extraArgs || exit /b 1
"@
    $log = Join-Path $s.OutDir "build-x64-$config.log"
    Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $s.BuildRoot "build-$config.bat") -LogFile $log -Label "libnode build [x64/$config]"
    if (-not $clangVersion) {
        $hit = Select-String -Path $log -Pattern 'Found Clang version (\S+)' | Select-Object -First 1
        if ($hit) { $clangVersion = $hit.Matches[0].Groups[1].Value }
    }

    # --- verify --------------------------------------------------------------
    $outDir = Join-Path $src "out\$config"
    $dll = Join-Path $outDir 'libnode.dll'
    $lib = Join-Path $outDir 'libnode.lib'
    $pdb = Join-Path $outDir 'libnode.pdb'
    foreach ($f in $dll, $lib) { if (-not (Test-Path $f)) { throw "libnode [x64/$config] did not produce $f." } }

    $expFile = Join-Path $s.BuildRoot "exports-$config.txt"
    $dump = @"
@echo on
call "$($tc.VcVarsAll)" x64 || exit /b 1
dumpbin /nologo /exports "$dll" > "$expFile" || exit /b 1
"@
    Invoke-BuildBatch -Script $dump -BatchFile (Join-Path $s.BuildRoot "dump-$config.bat") -LogFile (Join-Path $s.BuildRoot "dump-$config.log") -Label "libnode exports [x64/$config]"
    $exports = Get-Content $expFile -Raw
    foreach ($sym in $requiredExports) {
        if ($exports -notmatch [regex]::Escape($sym)) { throw "libnode.dll [$config] does not export ?$sym..." }
    }

    # --- stage ---------------------------------------------------------------
    $pkgRoot = Join-Path $stage "bin-x64-$config\$($s.Pkg)"
    $binDst  = Join-Path $pkgRoot "binaries\x64\$config"
    New-Item -ItemType Directory -Force -Path $binDst | Out-Null
    Copy-Item $dll, $lib -Destination $binDst
    if ($config -eq 'Debug') {
        if (Test-Path $pdb) { Copy-Item $pdb -Destination $binDst }
        else { Write-Host "WARNING: no libnode.pdb in $outDir; the Debug package goes without it." -ForegroundColor Yellow }
    }
    Copy-Item (Join-Path $src 'LICENSE') -Destination $pkgRoot
    New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-x64-$config.zip".ToLower()))
}

# --- headers zip -------------------------------------------------------------------
# deps\v8\include as it is: v8*.h, cppgc\ and libplatform\, the include directory
# mod_v8's #include <v8.h> and <libplatform/libplatform.h> expect.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item (Join-Path $src 'deps\v8\include\*') -Destination $incDst -Recurse
Copy-Item (Join-Path $src 'LICENSE') -Destination $hdrRoot
foreach ($must in 'v8.h', 'v8-version.h', 'libplatform\libplatform.h', 'cppgc\common.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
$clang = if ($clangVersion) { "ClangCL $clangVersion" } else { 'ClangCL (version not found in the log)' }
Write-Bom $s @("toolchain: $($tc.VsInstall), $clang", "v8: $v8Version",
               "vcbuild: dll <config> x64 nonpm $extraArgs".TrimEnd(),
               "patch: common.gypi BUILDING_V8_PLATFORM_SHARED=1 (exports libplatform)",
               "library: libnode.dll (shared) + libnode.lib (import)")
Write-PackageSummary $s
