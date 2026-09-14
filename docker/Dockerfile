# escape=`
#
# Toolchain image for building every dependency in this repository on Windows:
# Visual Studio 2022 Build Tools (MSVC + Windows SDK + nmake), Strawberry Perl
# and NASM (OpenSSL), CMake (zlib and other CMake-based libraries).
#
# The image contains ONLY the toolchain. The repository is mounted at C:\src at
# run time, so script changes never require rebuilding the (slow, multi-GB)
# image, and the dependency to build is selected with `-Dep <name>`:
#
#   docker build -t windows-deps docker
#
#   docker run --rm --cpus 8 --memory 8g -v ${PWD}:C:\src windows-deps -Dep zlib
#   docker run --rm --cpus 8 --memory 8g -v ${PWD}:C:\src windows-deps -Dep openssl
#
# Output lands in .\artifacts\<dep>\ on the host (OUT_DIR defaults to
# C:\src\artifacts\<dep>). Dependency packages are resolved from this
# repository's release tags or from <DEP>_PKG_BASE / <DEP>_PKG environment
# variables (e.g. -e ZLIB_PKG_BASE=C:\src\artifacts\zlib -e ZLIB_PKG=zlib-1.3.2_0
# to use a zlib you just built in the same tree); see README.md.
#
# Requires Windows containers. The host must be able to run a Windows base image
# of an equal-or-older build than the host (process isolation), otherwise run
# with `--isolation=hyperv`.

ARG WINDOWS_BASE=mcr.microsoft.com/windows/servercore:ltsc2025
FROM ${WINDOWS_BASE}

# The Visual Studio bootstrapper. aka.ms/vs/17/release installs the latest VS 2022
# Build Tools.
ARG VS_BOOTSTRAPPER_URL=https://aka.ms/vs/17/release/vs_buildtools.exe

SHELL ["powershell", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# ---------------------------------------------------------------------------
# 1. Chocolatey + the non-VS prerequisites of all dependencies:
#    - strawberryperl : OpenSSL's Configure is written in Perl
#    - nasm           : assembles OpenSSL's x86/x64 crypto modules
#    - cmake          : zlib (and other CMake-based libraries)
#    tar.exe (for unpacking source tarballs) ships with the base image.
# ---------------------------------------------------------------------------
RUN [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; `
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

RUN choco install -y --no-progress strawberryperl nasm; `
    if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }

RUN choco install -y --no-progress cmake --installargs 'ADD_CMAKE_TO_SYSTEM_PATH=System'; `
    if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }; `
    if (-not (Test-Path 'C:\Program Files\CMake\bin\cmake.exe')) { throw 'cmake.exe not found after install' }; `
    & 'C:\Program Files\CMake\bin\cmake.exe' --version

# ---------------------------------------------------------------------------
# 2. Visual Studio 2022 Build Tools: the C++ workload (MSVC v143 + Windows SDK +
#    nmake + rc). The build scripts enter this environment via vcvarsall.bat.
#    Exit code 3010 == success-but-reboot-required, which is fine in an image.
# ---------------------------------------------------------------------------
RUN Invoke-WebRequest -Uri $env:VS_BOOTSTRAPPER_URL -OutFile C:\vs_buildtools.exe; `
    Write-Host 'Installing Visual Studio Build Tools (this takes a while)...'; `
    $p = Start-Process -FilePath C:\vs_buildtools.exe -Wait -PassThru -ArgumentList `
        '--quiet','--wait','--norestart','--nocache', `
        '--installPath','C:\BuildTools', `
        '--add','Microsoft.VisualStudio.Workload.VCTools', `
        '--includeRecommended'; `
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "VS Build Tools install failed ($($p.ExitCode))" }; `
    Remove-Item C:\vs_buildtools.exe -Force

# ---------------------------------------------------------------------------
# 3. Entry point: the dispatcher from the mounted repository.
# ---------------------------------------------------------------------------
# NOTE: do NOT set `ENV PATH` here -- the Windows base image exports the variable
# as `Path` (mixed case) and Docker's ${...} substitution is case-sensitive, so
# `${PATH}` would expand to empty and wipe System32 from the path. The installers
# register their dirs in the machine PATH (which container processes inherit), and
# scripts/common.ps1 prepends the tool dirs defensively at runtime.

WORKDIR C:\src

ENTRYPOINT ["C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\src\\scripts\\build.ps1"]
CMD ["-Dep", "zlib"]
