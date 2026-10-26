# Prerequisites of the libnode build that a GitHub windows runner does not have
# preinstalled (the Docker image installs the same via its Dockerfile).
#   - NASM : assembles the x64 modules of the OpenSSL Node bundles
# Python is preinstalled. ClangCL, which vcbuild.bat requires from Node 24 on, is
# part of the runner's Visual Studio; it is checked here so a runner image without
# it fails in seconds rather than after the configure step.
$ErrorActionPreference = 'Stop'
choco install -y --no-progress nasm
if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }
Write-Host "nasm   : $((Get-Command nasm -ErrorAction SilentlyContinue).Source)"
Write-Host "python : $((Get-Command python -ErrorAction SilentlyContinue).Source)"

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset -property installationPath
if (-not $vs) { throw "No Visual Studio with the ClangCL components (VC.Llvm.Clang, VC.Llvm.ClangToolset); vcbuild.bat needs them for Node >= 24." }
Write-Host "clang  : $vs\VC\Tools\Llvm\x64\bin\clang.exe"
