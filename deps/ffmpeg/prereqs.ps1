# Prerequisites of the FFmpeg build that a GitHub windows runner does not have
# preinstalled (the Docker image installs the same via its Dockerfile).
#   - NASM  : assembles the x86 code of FFmpeg and x264
#   - MSYS2 packages: make, pkgconf and diffutils for FFmpeg's and x264's
#     configure + make, bzip2 for Cisco's openh264-<ver>-win64.dll.bz2.
#     MSYS2 itself is preinstalled on the runner at C:\msys64.
$ErrorActionPreference = 'Stop'
choco install -y --no-progress nasm
if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }
Write-Host "nasm : $((Get-Command nasm -ErrorAction SilentlyContinue).Source)"

$bash = 'C:\msys64\usr\bin\bash.exe'
if (-not (Test-Path $bash)) { throw "MSYS2 not found at C:\msys64 (the windows runner images ship it there)." }
& $bash -lc 'pacman -Sy --noconfirm --needed make pkgconf diffutils bzip2'
if ($LASTEXITCODE -ne 0) { throw "pacman failed ($LASTEXITCODE)" }
foreach ($t in 'make', 'pkgconf', 'diff', 'bunzip2') {
    $p = "C:\msys64\usr\bin\$t.exe"
    if (-not (Test-Path $p)) { throw "$p is missing after pacman" }
    Write-Host ("{0,-8}: {1}" -f $t, $p)
}
