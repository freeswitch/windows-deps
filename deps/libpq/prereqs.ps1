# Prerequisites of the libpq build that a GitHub windows runner does not have
# preinstalled (the Docker image installs the same via its Dockerfile).
# PostgreSQL 17 is built with Meson, and its meson.build probes perl, python,
# flex and bison at configure time even for a libpq-only build.
#   - Strawberry Perl : PostgreSQL generates C sources with perl
#   - winflexbison3   : win_flex.exe / win_bison.exe, the names PostgreSQL's
#                       FLEX/BISON defaults look for on Windows
#   - meson + ninja   : the build system (python itself is preinstalled on the
#                       runner, as is pip)
$ErrorActionPreference = 'Stop'
choco install -y --no-progress strawberryperl winflexbison3
if ($LASTEXITCODE -ne 0) { throw "choco install failed ($LASTEXITCODE)" }
python -m pip install --disable-pip-version-check --no-cache-dir 'meson~=1.7' 'ninja~=1.11'
if ($LASTEXITCODE -ne 0) { throw "pip install meson/ninja failed ($LASTEXITCODE)" }
foreach ($t in 'perl', 'python', 'win_flex', 'win_bison', 'meson', 'ninja') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $c) { throw "$t is not on PATH after installing the prerequisites" }
    Write-Host ("{0,-10}: {1}" -f $t, $c.Source)
}
