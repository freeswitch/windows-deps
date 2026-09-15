<#
.SYNOPSIS
    Lua: builds lua<major><minor>.dll (5.3.x -> lua53.dll) and its import library
    with the Visual C++ toolchain, and packages it the way FreeSWITCH's w32\lua.props
    expects (the layout files.freeswitch.org served; consumer: mod_lua).

    Lua ships no build system for Windows beyond the two command lines in its own
    "Building Lua on Windows" notes, and FreeSWITCH used to compile it from a
    hand-written vcxproj (libs\win32\lua\lua.2015.vcxproj, removed in FS-10980).
    This reproduces that: every src\*.c except the lua.c / luac.c front ends,
    compiled with LUA_BUILD_AS_DLL so the API is exported, dynamic CRT (/MD,
    /MDd in Debug), linked into one DLL.

    Package <pkg> = lua-<version>_<build>:
      <pkg>-headers.zip                       <pkg>/README, <pkg>/doc/readme.html (license)
                                              <pkg>/include/{lua.h, luaconf.h, lualib.h, lauxlib.h, lua.hpp}
      <pkg>-binaries-<platform>-<config>.zip  <pkg>/README, <pkg>/doc/readme.html
                                              <pkg>/binaries/<Platform>/<Config>/{lua53.dll, lua53.lib}
                                                                             /lua53.pdb   (Debug only)
      SHA256SUMS.txt, <pkg>-BOM.txt

    Environment (all optional): LUA_VERSION, BUILD_NUMBER, PKG_NAME, CONFIGS,
    PLATFORMS, OUT_DIR, BUILD_ROOT, LUA_URL, LUA_LIB_NAME (default lua<major><minor>),
    EXTRA_CFLAGS.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\common.ps1')

$s  = Get-BuildSettings 'lua'
$tc = Initialize-Toolchain
$extraCFlags = [string](Get-EnvValue 'EXTRA_CFLAGS' '')

foreach ($c in $s.Configs) {
    if ($c -notin @('Release', 'Debug')) { throw "Unsupported configuration '$c' (use 'Release' and/or 'Debug')." }
}

# The two front ends are programs, not part of the library; ltests.c only exists in
# the git mirror and needs LUA_USER_H=ltests.h.
$skipSources = @('lua.c', 'luac.c', 'ltests.c')

Write-Host "==================================================================="
Write-Host " lua             : $($s.Version) (build $($s.Build), package $($s.Pkg))"
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

$tarball = Join-Path $s.BuildRoot "lua-$($s.Version).tar.gz"
Get-RemoteFile $s.SourceUrl $tarball

$headerSrc = $null   # src\ of the first build
$srcRoot   = $null   # tarball root of the first build
$libName   = $null

foreach ($plat in $s.Platforms) {
    $vcArch = Get-VcArch $plat
    foreach ($config in $s.Configs) {
        Write-Host "-------------------------------------------------------------------"
        Write-Host "Building lua $($s.Version)  [$plat / $config]  (cl + link, LUA_BUILD_AS_DLL)"
        Write-Host "-------------------------------------------------------------------"

        $work = Join-Path $s.BuildRoot "build-$plat-$config"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Expand-Tarball $tarball $work $tc
        $root = Join-Path $work "lua-$($s.Version)"
        if (-not (Test-Path $root)) { throw "Tarball did not expand to '$root'." }
        # lua.org ships the sources in src\; the github.com/lua/lua tag archive has
        # them at the top level instead.
        $src = if (Test-Path (Join-Path $root 'src\lua.h')) { Join-Path $root 'src' } else { $root }
        if (-not (Test-Path (Join-Path $src 'lua.h'))) { throw "lua.h not found under '$root'." }

        # The version lua.h declares must match the manifest, and it also gives the
        # DLL its name (5.3.x -> lua53).
        $luaH = Get-Content (Join-Path $src 'lua.h') -Raw
        $parts = foreach ($k in 'MAJOR', 'MINOR', 'RELEASE') {
            if ($luaH -match "(?m)^#define LUA_VERSION_$k\s+`"([^`"]+)`"") { $Matches[1] } else { throw "LUA_VERSION_$k not found in lua.h" }
        }
        $srcVer = $parts -join '.'
        if ($srcVer -ne $s.Version) { throw "Lua source declares version $srcVer but deps.json says $($s.Version)." }
        if (-not $libName) {
            $libName = [string](Get-EnvValue 'LUA_LIB_NAME' ("lua{0}{1}" -f $parts[0], $parts[1]))
            Write-Host "Library name    : $libName (.dll / .lib)"
        }

        $sources = Get-ChildItem $src -Filter '*.c' | Where-Object { $_.Name -notin $skipSources } | Sort-Object Name
        if ($sources.Count -lt 25) { throw "Only $($sources.Count) source files found in '$src' -- unexpected layout." }
        $objDir = Join-Path $work 'obj'
        $binDir = Join-Path $work 'bin'
        New-Item -ItemType Directory -Force -Path $objDir, $binDir | Out-Null

        # Matches the old vcxproj: dynamic CRT, LUA_BUILD_AS_DLL (that is what marks
        # the API __declspec(dllexport); Lua needs no .def file).
        $crt   = if ($config -eq 'Debug') { '/MDd' } else { '/MD' }
        $opt   = if ($config -eq 'Debug') { '/Od /Zi /D_DEBUG' } else { '/O2 /DNDEBUG' }
        $clRsp = @("/nologo /c $crt $opt /W3 /D_CRT_SECURE_NO_DEPRECATE /DLUA_BUILD_AS_DLL $extraCFlags",
                   "/Fo`"$objDir\\`"", "/Fd`"$objDir\compiler.pdb`"") +
                 ($sources | ForEach-Object { "`"$($_.FullName)`"" })
        Set-Content -Path (Join-Path $work 'cl.rsp') -Value $clRsp -Encoding ASCII

        $dll = Join-Path $binDir "$libName.dll"
        $lib = Join-Path $binDir "$libName.lib"
        $pdb = Join-Path $binDir "$libName.pdb"
        $linkRsp = @('/nologo /DLL', "/OUT:`"$dll`"", "/IMPLIB:`"$lib`"") +
                   $(if ($config -eq 'Debug') { @('/DEBUG', "/PDB:`"$pdb`"") } else { @() }) +
                   ($sources | ForEach-Object { "`"$(Join-Path $objDir ($_.BaseName + '.obj'))`"" })
        Set-Content -Path (Join-Path $work 'link.rsp') -Value $linkRsp -Encoding ASCII

        # link.exe does not expand wildcards, so both tools get explicit file lists
        # through response files (which also keeps us under the command line limit).
        $bat = @"
@echo on
call "$($tc.VcVarsAll)" $vcArch || exit /b 1
cl @"$(Join-Path $work 'cl.rsp')" || exit /b 1
link @"$(Join-Path $work 'link.rsp')" || exit /b 1
dumpbin /nologo /dependents "$dll" || exit /b 1
dumpbin /nologo /exports "$dll" > "$(Join-Path $work 'exports.txt')" || exit /b 1
"@
        $log = Join-Path $s.OutDir "build-$plat-$config.log"
        Invoke-BuildBatch -Script $bat -BatchFile (Join-Path $work 'build.bat') -LogFile $log -Label "lua build [$plat/$config]"

        # --- verify --------------------------------------------------------------
        foreach ($f in $dll, $lib) { if (-not (Test-Path $f)) { throw "lua [$plat/$config] did not produce $(Split-Path -Leaf $f)." } }
        $exports = Get-Content (Join-Path $work 'exports.txt') -Raw
        foreach ($sym in 'lua_newstate', 'luaL_openlibs', 'lua_pcallk', 'luaL_newstate') {
            if ($exports -notmatch "\b$sym\b") { throw "$libName.dll does not export $sym -- LUA_BUILD_AS_DLL did not take effect." }
        }

        # --- stage ---------------------------------------------------------------
        $pkgRoot = Join-Path $stage "bin-$plat-$config\$($s.Pkg)"
        $binDst  = Join-Path $pkgRoot "binaries\$plat\$config"
        New-Item -ItemType Directory -Force -Path $binDst, (Join-Path $pkgRoot 'doc') | Out-Null
        Copy-Item $dll, $lib -Destination $binDst
        if ($config -eq 'Debug' -and (Test-Path $pdb)) { Copy-Item $pdb -Destination $binDst }
        Copy-Item (Join-Path $root 'README') -Destination $pkgRoot -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $root 'doc\readme.html') -Destination (Join-Path $pkgRoot 'doc') -ErrorAction SilentlyContinue
        New-PackageZip $pkgRoot (Join-Path $s.OutDir ("$($s.Pkg)-binaries-$plat-$config.zip".ToLower()))

        if (-not $headerSrc) { $headerSrc = $src; $srcRoot = $root }
    }
}

# --- headers zip -------------------------------------------------------------------
Write-Host "-------------------------------------------------------------------"
Write-Host "Packaging headers ..."
$hdrRoot = Join-Path $stage "hdr\$($s.Pkg)"
$incDst  = Join-Path $hdrRoot 'include'
New-Item -ItemType Directory -Force -Path $incDst, (Join-Path $hdrRoot 'doc') | Out-Null
foreach ($h in 'lua.h', 'luaconf.h', 'lualib.h', 'lauxlib.h') {
    Copy-Item (Join-Path $headerSrc $h) -Destination $incDst
}
# lua.hpp is only in the lua.org release tarball, not in the git mirror; it is three
# includes wrapped in extern "C" and the old packages shipped it, so keep it.
$luaHpp = Join-Path $headerSrc 'lua.hpp'
if (Test-Path $luaHpp) {
    Copy-Item $luaHpp -Destination $incDst
} else {
    Write-Host "lua.hpp is missing from this source archive, generating it."
    @('// lua.hpp', '// Lua header files for C++', '// <<extern "C">> not supplied automatically because Lua also compiles as C++', '',
      'extern "C" {', '#include "lua.h"', '#include "lualib.h"', '#include "lauxlib.h"', '}') |
        Set-Content -Path (Join-Path $incDst 'lua.hpp') -Encoding ASCII
}
Copy-Item (Join-Path $srcRoot 'README') -Destination $hdrRoot -ErrorAction SilentlyContinue
Copy-Item (Join-Path $srcRoot 'doc\readme.html') -Destination (Join-Path $hdrRoot 'doc') -ErrorAction SilentlyContinue
foreach ($must in 'lua.h', 'luaconf.h', 'lualib.h', 'lauxlib.h', 'lua.hpp') {
    if (-not (Test-Path (Join-Path $incDst $must))) { throw "Headers package is missing include\$must." }
}
New-PackageZip $hdrRoot (Join-Path $s.OutDir ("$($s.Pkg)-headers.zip".ToLower()))

Write-Checksums $s.OutDir
Write-Bom $s @("toolchain: $($tc.VsInstall)", "library: $libName.dll + $libName.lib",
               "features: LUA_BUILD_AS_DLL, /MD, no lua.exe / luac.exe")
Write-PackageSummary $s
