<#
.SYNOPSIS
    pthreads-w32: builds pthread.dll and its import library with the Visual C++
    toolchain and packages them for FreeSWITCH's w32\pthreads.props.

    FreeSWITCH used to build this in tree: w32\download_pthreads.props fetched
    pthreads-w32-2-9-1.tar.gz from files.freeswitch.org and
    libs\win32\pthread\pthread.2017.vcxproj compiled it. The solution maps that
    project to its "Release DLL" / "Debug DLL" configurations, so what FreeSWITCH
    actually ships is the DLL; this node builds exactly that.

    The source is upstream's 2.9.1 release from sourceware.org, mirrored as an
    asset of this repository so the build does not depend on that host staying
    up: upstream has not released since 2012.

    The build follows the in tree project: one translation unit (pthread.c, which
    includes the rest), version.rc for the version resource, the same defines
    (_TIMESPEC_DEFINED, HAVE_CONFIG_H, __CLEANUP_C -- C cleanup style, so no
    structured exception handling), linked against ws2_32.lib. PTW32_STATIC_LIB is
    not defined: consumers use the import library, as they do today.

    The output keeps the name the in tree project gave it -- pthread.dll and
    pthread.lib -- so nothing in the tree has to learn a new file name. Upstream's
    own name for this build is pthreadVC2.dll, which is what the version resource
    inside the DLL still says, exactly as in the in tree build.

    Package <pkg> = pthreads-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/{pthread.h, sched.h,
                                                             semaphore.h}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/{pthread.dll,
                                                                                  pthread.lib}
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): PTHREADS_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, PTHREADS_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'pthreads'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

Write-Host "==================================================================="
Write-Host " pthreads-w32    : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "pthreads-w32-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null
$licenseName = $null
$sourceVersion = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building pthread.dll $($s.Version)  [$plat / $config]  (cl + link)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = (Get-ChildItem $work -Directory -Filter 'pthreads-w32-*' | Select-Object -First 1)
        if (-not $root) { throw "Tarball did not expand to a pthreads-w32-* directory." }
        $root = $root.FullName
        foreach ($must in 'pthread.c', 'config.h', 'version.rc', 'pthread.h', 'sched.h', 'semaphore.h') {
            if (-not (Test-Path (Join-Path $root $must))) { throw "'$must' is missing from the source tree." }
        }
        $license = @('COPYING.LIB', 'COPYING') | Where-Object { Test-Path (Join-Path $root $_) } | Select-Object -First 1
        if (-not $license) { throw 'No license file in the source tree.' }

        # This snapshot is CVS between releases: everything names it 2.9.1 -- the
        # tarball, the tree's libs\pthreads-w32-2-9-1, files.freeswitch.org -- while
        # pthread.h already declares 2.10.0. Record what the header says rather than
        # pretend it agrees with the manifest.
        $h = Get-Content (Join-Path $root 'pthread.h') -Raw
        if ($h -notmatch 'PTW32_VERSION\s+(\d+),(\d+),(\d+)') { throw 'No PTW32_VERSION in pthread.h.' }
        $sourceVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        Write-Host "pthread.h declares PTW32_VERSION $sourceVersion (packaged as $($s.Version))"

        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # The knobs the in tree vcxproj uses for its DLL configurations.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $rcArch = if ($plat -eq 'x64') { '/DPTW32_ARCHx64 /DWIN64' } else { '/DPTW32_ARCHx86' }
        $rcDbg  = if ($config -eq 'Debug') { '/D_DEBUG' } else { '/DNDEBUG' }

        $dll = Join-Path $binDir 'pthread.dll'
        $imp = Join-Path $binDir 'pthread.lib'
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cd /d "$root"
rc /nologo $rcDbg /DPTW32_RC_MSC $rcArch /fo "$objDir\version.res" version.rc || exit /b 1
cl /nologo /c $crt $opt /W3 /DWIN32 /D_WINDOWS /D_USRDLL /DHAVE_CONFIG_H /D__CLEANUP_C /D_TIMESPEC_DEFINED /D_CRT_SECURE_NO_DEPRECATE $extraCFlags /I"$root" /Fo"$objDir\pthread.obj" /Fd"$objDir\compiler.pdb" pthread.c || exit /b 1
link /nologo /DLL /OUT:"$dll" /IMPLIB:"$imp" "$objDir\pthread.obj" "$objDir\version.res" ws2_32.lib || exit /b 1
dumpbin /nologo /exports "$dll" > "$(Join-Path $work 'exports.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "pthreads build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        foreach ($f in $dll, $imp) {
            if (-not (Test-Path $f)) { throw "pthreads [$plat/$config] did not produce $(Split-Path -Leaf $f)." }
        }
        $exports = Get-Content (Join-Path $work 'exports.txt') -Raw
        foreach ($sym in 'pthread_create', 'pthread_join', 'pthread_detach', 'pthread_exit', 'pthread_self',
                         'pthread_mutex_init', 'pthread_mutex_lock', 'pthread_mutex_unlock', 'pthread_mutex_destroy',
                         'pthread_cond_init', 'pthread_cond_wait', 'pthread_cond_signal', 'pthread_cond_broadcast',
                         'pthread_key_create', 'pthread_getspecific', 'pthread_setspecific',
                         'sem_init', 'sem_wait', 'sem_post') {
            if ($exports -notmatch "\b$sym\b") { throw "pthread.dll does not export $sym." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst | Out-Null
        Copy-Item $dll, $imp -Destination $binDst
        Copy-Item (Join-Path $root $license) -Destination $pkgRoot
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $root; $licenseName = $license }
    }
}

# --- headers zip -------------------------------------------------------------------
# The three headers upstream installs.
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
foreach ($h in 'pthread.h', 'sched.h', 'semaphore.h') {
    Copy-Item (Join-Path $headerSrc $h) -Destination $incDst
}
Copy-Item (Join-Path $headerSrc $licenseName) -Destination $hdrRoot
foreach ($must in 'pthread.h', 'sched.h', 'semaphore.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: pthread.dll + pthread.lib (import library)",
               "cleanup style: C (__CLEANUP_C), as in the in tree build",
               "pthread.h declares PTW32_VERSION $sourceVersion")
Write-PackageSummary $s
