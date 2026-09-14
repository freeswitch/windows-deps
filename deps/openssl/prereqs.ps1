# Prerequisites of the OpenSSL build that a GitHub windows runner does not have
# preinstalled (the Docker image installs the same via its Dockerfile).
#   - Strawberry Perl : OpenSSL's Configure is written in Perl
#   - NASM            : assembles OpenSSL's x86/x64 crypto modules
$ErrorActionPreference = 'Stop'
choco install -y --no-progress strawberryperl nasm
if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }
Write-Host "perl : $((Get-Command perl -ErrorAction SilentlyContinue).Source)"
Write-Host "nasm : $((Get-Command nasm -ErrorAction SilentlyContinue).Source)"
