<#
.SYNOPSIS
    SQLite: builds the static sqlite3.lib from the canonical source tree with the
    Visual C++ toolchain and packages it for FreeSWITCH's w32\sqlite.props. The
    consumer is FreeSwitchCore, which links it into the core DLL.

    The source is the tag archive of github.com/sqlite/sqlite, not the prepared
    amalgamation zip, and the amalgamation is generated here as an intermediate
    step -- "make sqlite3.c", the way sqlite.org's own doc/compile-for-windows.md
    describes it. That needs no TCL installation: the tree builds jimsh0.exe from
    autosetup\jimsh0.c with cl and runs its generators with that. Generating the
    amalgamation takes about fifteen seconds.

    FreeSWITCH already builds from an amalgamation: w32\download_sqlite.props
    fetched a prepared zip from a mirror in github.com/freeswitch/sqlite and
    libs\win32\sqlite\sqlite.2017.vcxproj compiled sqlite3.c. The solution maps
    that project's Debug|x64 and Release|x64 to its static configurations, so the
    package is a static library, built with the same knobs the project used: /MD,
    THREADSAFE=1, and SQLITE_DEBUG in debug.

    Package <pkg> = sqlite-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/LICENSE.md
                                              <pkg>/include/{sqlite3.h, sqlite3ext.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/LICENSE.md
                                              <pkg>/binaries/<Platform>/<Config>/sqlite3.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): SQLITE_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, SQLITE_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'sqlite'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " sqlite          : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "sqlite-version-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$srcParent = Join-Path $s.BuildRoot 'src'
Reset-Directory $srcParent
Expand-Tarball $tarball $srcParent $tc
$root = (Get-ChildItem $srcParent -Directory | Select-Object -First 1)
if (-not $root) { throw "The tag archive did not expand to a directory." }
$root = $root.FullName
foreach ($must in 'Makefile.msc', 'VERSION', 'LICENSE.md', 'autosetup\jimsh0.c') {
    if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
}

# What the tree says it is must match the manifest.
$sourceVersion = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ($sourceVersion -ne $s.Version) { throw "The source tree declares version $sourceVersion but deps.json says $($s.Version)." }
Write-Host "source tree VERSION $sourceVersion"

# --- the amalgamation, generated the documented way ---------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Generating sqlite3.c (nmake /f Makefile.msc sqlite3.c, with the tree's own jimsh) ..."
Write-Host "-------------------------------------------------------------------"
$gen = @"
@echo on
call "$($tc.VcVarsAll)" $(Get-VcArch $s.Platforms[0]) || exit /b 1
cd /d "$root"
nmake /f Makefile.msc sqlite3.c || exit /b 1
"@
Invoke-BuildBatch -Script $gen -BatchFile (Join-Path $s.BuildRoot 'generate.bat') `
                  -LogFile (Join-Path $s.OutDir 'generate.log') -Label 'sqlite amalgamation'
foreach ($f in 'sqlite3.c', 'sqlite3.h', 'sqlite3ext.h') {
    if (-not (Test-Path (Join-Path $root $f))) { throw "'$f' was not generated." }
    Write-Host ("  {0,12:N0}  {1}" -f (Get-Item (Join-Path $root $f)).Length, $f)
}
$h = Get-Content (Join-Path $root 'sqlite3.h') -Raw
if ($h -notmatch '#define\s+SQLITE_VERSION\s+"([0-9][0-9.]*)"') { throw "No SQLITE_VERSION in the generated sqlite3.h." }
if ($Matches[1] -ne $s.Version) { throw "The generated header declares $($Matches[1]), not $($s.Version)." }

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building sqlite3.lib $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The same knobs the in tree vcxproj used for its static configurations.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG /DSQLITE_DEBUG' } else { '/O2 /DNDEBUG' }
        $lib = Join-Path $binDir 'sqlite3.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cl /nologo /c $crt $opt /W3 /D_CRT_SECURE_NO_DEPRECATE /D_CRT_NONSTDC_NO_DEPRECATE /DWIN32 /D_LIB /DTHREADSAFE=1 $extraCFlags /Fo"$objDir\sqlite3.obj" /Fd"$objDir\compiler.pdb" "$(Join-Path $root 'sqlite3.c')" || exit /b 1
lib /nologo /OUT:"$lib" "$objDir\sqlite3.obj" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "sqlite build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "sqlite [$plat/$config] did not produce sqlite3.lib." }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'sqlite3_open', 'sqlite3_open_v2', 'sqlite3_close', 'sqlite3_exec',
                         'sqlite3_prepare_v2', 'sqlite3_step', 'sqlite3_finalize', 'sqlite3_reset',
                         'sqlite3_bind_text', 'sqlite3_column_text', 'sqlite3_errmsg', 'sqlite3_free',
                         'sqlite3_get_table', 'sqlite3_free_table', 'sqlite3_libversion', 'sqlite3_threadsafe') {
            if ($syms -notmatch "\b$sym\b") { throw "sqlite3.lib does not contain $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $lib -Destination $binDst
        Copy-Item (Join-Path $root 'LICENSE.md') -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))
    }
}

# --- headers zip -------------------------------------------------------------------
# Both headers come out of the generation step, not the source tree.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($f in 'sqlite3.h', 'sqlite3ext.h') {
    Copy-Item (Join-Path $root $f) -Destination $incDst
}
Copy-Item (Join-Path $root 'LICENSE.md') -Destination $hdrRoot
foreach ($must in 'sqlite3.h', 'sqlite3ext.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: sqlite3.lib (static)",
               "amalgamation: generated from the source tree with its own jimsh",
               "options: THREADSAFE=1, /MD")
Write-PackageSummary $s
