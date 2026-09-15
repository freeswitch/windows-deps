<#
.SYNOPSIS
    Flite: builds the static flite.lib (core + usenglish + cmulex + the five US
    voices mod_flite registers) with the Visual C++ toolchain, and packages it the
    way FreeSWITCH's w32\flite.props expects (the layout files.freeswitch.org
    served; consumer: mod_flite).

    Flite has no usable Windows build system -- its own flite.sln only builds the
    SAPI engine -- so FreeSWITCH used to carry a hand written project for it
    (libs\win32\flite\flite.2015.vcxproj, dropped in FS-11086 when flite moved to
    precompiled binaries). This reproduces that project with cl and lib: the same
    directories, the same defines (CST_AUDIO_NONE, NO_UNION_INITIALIZATION), the
    dynamic CRT, one static library. Which sources a directory contributes is read
    from its own Makefile (SRCS), so a version bump picks up upstream's changes;
    only the platform dependent files are pinned here.

    Package <pkg> = flite-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/COPYING
                                              <pkg>/include/*.h
                                                  (w32\flite.props renames include\ to flite\ on extraction,
                                                   because mod_flite includes <flite/flite.h>)
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/COPYING
                                              <pkg>/binaries/<Platform>/<Config>/flite.lib
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): FLITE_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, FLITE_URL, EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'flite'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

# Directories that went into the old flite.lib. The voices are the ones mod_flite
# registers (kal, kal16, awb, rms, slt); cmu_time_awb comes with them. The other
# languages flite 2.2 ships (grapheme, indic) are left out, as before.
$srcDirs = @('src\cg', 'src\hrg', 'src\lexicon', 'src\regex', 'src\speech', 'src\stats',
             'src\synth', 'src\utils', 'src\wavesynth',
             'lang\cmulex', 'lang\usenglish', 'lang\cmu_time_awb',
             'lang\cmu_us_awb', 'lang\cmu_us_kal', 'lang\cmu_us_kal16',
             'lang\cmu_us_rms', 'lang\cmu_us_slt')
# Platform dependent: upstream picks these through make variables (AUDIODRIVER,
# MMAPTYPE, STDIOTYPE), so they are named here, exactly as the old vcxproj had them.
$extraSources = [ordered]@{
    'src\audio' = @('audio.c', 'au_command.c', 'au_none.c', 'au_streaming.c')
    'src\utils' = @('cst_mmap_win32.c', 'cst_file_stdio.c')
}

# Reads "SRCS = a.c b.c \<newline> c.c" out of a directory's Makefile.
function Get-MakefileSources([string]$Dir) {
    $mk = Join-Path $Dir 'Makefile'
    if (-not (Test-Path $mk)) { throw "No Makefile in '$Dir'." }
    $text = (Get-Content $mk -Raw) -replace '\\\r?\n', ' '
    # The voice Makefiles write their sources as cmu_us_$(VOXNAME)*.c, so the plain
    # assignments of the same file have to be substituted first.
    $vars = @{}
    foreach ($m in [regex]::Matches($text, '(?m)^([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*([^\r\n]*)$')) {
        $vars[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
    }
    if (-not $vars.ContainsKey('SRCS')) { throw "No SRCS in '$mk'." }
    $value = $vars['SRCS']
    for ($i = 0; $i -lt 4 -and $value -match '\$\(' ; $i++) {
        $value = [regex]::Replace($value, '\$\(([A-Za-z_][A-Za-z0-9_]*)\)', {
            param($m)
            if ($vars.ContainsKey($m.Groups[1].Value)) { $vars[$m.Groups[1].Value] } else { $m.Value }
        })
    }
    if ($value -match '\$\(') { throw "Unresolved variable in SRCS of '$mk': $value" }
    $names = $value -split '\s+' | Where-Object { $_ -like '*.c' }
    if (-not $names) { throw "SRCS in '$mk' lists no .c files." }
    $names
}

Write-Host "==================================================================="
Write-Host " flite           : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "flite-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building flite $($s.Version)  [$plat / $config]  (cl + lib, static)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "flite-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }

        # The version upstream declares must match the manifest.
        $vh = Get-Content (Join-Path $root 'include\flite_version.h') -Raw -ErrorAction SilentlyContinue
        if ($vh -and $vh -match 'FLITE_PROJECT_VERSION\s+"([0-9][0-9.]*)"') {
            if ($Matches[1] -ne $s.Version) { throw "Flite source declares version $($Matches[1]) but deps.json says $($s.Version)." }
        } else {
            Write-Host "WARNING: could not read the version from include\flite_version.h, not cross-checked."
        }

        # --- the source list, per directory ---------------------------------------
        # One cl invocation per directory: object files of different directories share
        # names (every cmu_us_* voice repeats them) and cl takes only one /Fo.
        $byDir = [ordered]@{}
        foreach ($d in $srcDirs) { $byDir[$d] = @(Get-MakefileSources (Join-Path $root $d)) }
        foreach ($k in $extraSources.Keys) {
            if ($byDir.Contains($k)) { $byDir[$k] = @($byDir[$k]) + $extraSources[$k] } else { $byDir[$k] = $extraSources[$k] }
        }
        $total = 0
        foreach ($d in $byDir.Keys) {
            foreach ($n in $byDir[$d]) {
                if (-not (Test-Path (Join-Path $root "$d\$n"))) { throw "'$d\$n' is listed in the Makefile but missing." }
            }
            $total += $byDir[$d].Count
        }
        Write-Host ("sources: {0} files from {1} directories" -f $total, $byDir.Count)
        if ($total -lt 120) { throw "Only $total sources collected -- the tree layout changed." }

        $objRoot = Join-Path $work 'obj'
        $binDir  = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objRoot, $binDir | Out-Null

        # Same knobs as the old vcxproj: no audio backend, no union initialisers
        # (MSVC C does not take them), dynamic CRT.
        $crt = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $inc = @('include', 'lang\usenglish', 'lang\cmulex') | ForEach-Object { "/I`"$(Join-Path $root $_)`"" }
        $common = "/nologo /c $crt $opt /W3 /DWIN32 /D_LIB /DCST_AUDIO_NONE=1 /DNO_UNION_INITIALIZATION=1 /D_CRT_SECURE_NO_WARNINGS /Dinline=__inline $extraCFlags"

        $clLines = @()
        $objects = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($d in $byDir.Keys) {
            $i++
            $objDir = Join-Path $objRoot ($d -replace '[\\/]', '_')
            New-Item -ItemType Directory -Force -Path $objDir | Out-Null
            $rsp = Join-Path $work ("cl-{0:d2}.rsp" -f $i)
            $lines = @($common, ($inc -join ' '), "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"")
            foreach ($n in $byDir[$d]) {
                $lines += "`"$(Join-Path $root "$d\$n")`""
                $objects.Add((Join-Path $objDir ($n -replace '\.c$', '.obj')))
            }
            Set-Content -Path $rsp -Value $lines -Encoding ASCII
            $clLines += "cl @`"$rsp`" || exit /b 1"
        }

        $lib = Join-Path $binDir 'flite.lib'
        $libRsp = @('/nologo', "/OUT:`"$lib`"") + ($objects | ForEach-Object { "`"$_`"" })
        Set-Content -Path (Join-Path $work 'lib.rsp') -Value $libRsp -Encoding ASCII

        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
$($clLines -join "`n")
lib @"$(Join-Path $work 'lib.rsp')" || exit /b 1
dumpbin /nologo /linkermember:1 "$lib" > "$(Join-Path $work 'symbols.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "flite build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        if (-not (Test-Path $lib)) { throw "flite [$plat/$config] did not produce flite.lib." }
        foreach ($o in $objects) { if (-not (Test-Path $o)) { throw "Object '$o' was not produced." } }
        $syms = Get-Content (Join-Path $work 'symbols.txt') -Raw
        foreach ($sym in 'flite_init', 'flite_text_to_wave', 'flite_voice_select',
                         'register_cmu_us_awb', 'register_cmu_us_kal', 'register_cmu_us_kal16',
                         'register_cmu_us_rms', 'register_cmu_us_slt', 'usenglish_init', 'cmu_lex_init') {
            if ($syms -notmatch "\b$sym\b") { throw "flite.lib does not contain $sym -- the source selection is wrong." }
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
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst | Out-Null
Copy-Item -Path (Join-Path $headerSrc 'include\*.h') -Destination $incDst
Copy-Item (Join-Path $headerSrc 'COPYING') -Destination $hdrRoot -ErrorAction SilentlyContinue
foreach ($must in 'flite.h', 'cst_wave.h', 'cst_voice.h', 'cst_val.h') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: flite.lib (static)",
               "features: CST_AUDIO_NONE, voices cmu_us_kal/kal16/awb/rms/slt + cmu_time_awb, /MD")
Write-PackageSummary $s
