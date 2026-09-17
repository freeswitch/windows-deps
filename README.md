# windows-deps

One repository that builds the **Windows dependency packages
[FreeSWITCH](https://github.com/signalwire/freeswitch) consumes** (zlib, OpenSSL,
…), publishes each of them as a GitHub Release, and — because it knows which
dependency is built on which — rebuilds **only the part of the graph a change
touches**, in the right order, handing freshly built packages down the chain.

It is the successor of the per-library `*-packaging` repositories
(`openssl-packaging`, `zlib-packaging`, …). The package layout is unchanged, so
FreeSWITCH's `w32\*.props` only need a new download base and a build number.

## Layout

```
deps.json                       the manifest: every dependency, its version, its source tarball, what it depends on
deps/<name>/build.ps1           how to build + package <name> (one script per dependency)
deps/<name>/prereqs.ps1         optional: tools to install on a GitHub runner before building <name>
deps/<name>/freeswitch/w32/     reference MSBuild props for consuming the package in FreeSWITCH
scripts/common.ps1              shared helpers (toolchain, downloads, dependency packages, zips, checksums, BOM)
scripts/plan.ps1                decides what to (re)build, in which order, with which build numbers
scripts/build.ps1               builds one dependency: resolves version/build/dependency packages, runs deps/<name>/build.ps1
docker/Dockerfile               one Windows-container toolchain image for all dependencies
.github/workflows/build.yml     plan -> one job per dependency (graph-ordered) -> publish releases
.github/workflows/build-dep.yml the reusable per-dependency job
```

## The manifest

```json
{
  "repository": "freeswitch/windows-deps",
  "deps": {
    "zlib":    { "version": "1.3.2",  "source": "https://github.com/madler/zlib/releases/download/v{version}/zlib-{version}.tar.gz",         "deps": [] },
    "openssl": { "version": "3.4.7",  "source": "https://github.com/openssl/openssl/releases/download/openssl-{version}/openssl-{version}.tar.gz", "deps": ["zlib"] },
    "libpng":  { "version": "1.6.58", "source": "https://github.com/pnggroup/libpng/archive/refs/tags/v{version}.tar.gz",                   "deps": ["zlib"] },
    "libks":   { "version": "2.0.11", "source": "https://github.com/signalwire/libks/archive/refs/tags/v{version}.tar.gz",                  "deps": ["openssl"] },
    "signalwire-client-c": { "version": "2.0.5", "source": "https://github.com/signalwire/signalwire-c/archive/refs/tags/v{version}.tar.gz", "deps": ["libks", "openssl"] },
    "curl":    { "version": "7.88.1", "source": "https://github.com/curl/curl/releases/download/curl-{version_}/curl-{version}.tar.gz",       "deps": ["zlib", "openssl"] },
    "libpcap": { "version": "1.10.7", "source": "https://github.com/the-tcpdump-group/libpcap/archive/refs/tags/libpcap-{version}.tar.gz",  "deps": [] },
    "rabbitmq-c": { "version": "0.17.0", "source": "https://github.com/alanxz/rabbitmq-c/archive/refs/tags/v{version}.tar.gz",             "deps": ["openssl"] },
    "libpq":   { "version": "17.11",  "source": "https://ftp.postgresql.org/pub/source/v{version}/postgresql-{version}.tar.gz",     "deps": ["openssl"] },
    "mariadb-connector-c": { "version": "3.4.9", "source": "https://github.com/mariadb-corporation/mariadb-connector-c/archive/refs/tags/v{version}.tar.gz", "deps": [] },
    "g722_1":  { "version": "0.2.0",  "source": "https://github.com/freeswitch/libg7221/archive/refs/tags/v{version}.tar.gz",        "deps": [] },
    "ilbc":    { "version": "0.0.1",  "source": "https://github.com/freeswitch/libilbc/archive/refs/tags/v{version}.tar.gz",         "deps": [] },
    "libsilk": { "version": "1.0.9",  "source": "https://github.com/freeswitch/libsilk/archive/refs/tags/v{version}.tar.gz",         "deps": [] },
    "libtiff": { "version": "4.7.2",  "source": "https://gitlab.com/libtiff/libtiff/-/archive/v{version}/libtiff-v{version}.tar.gz",  "deps": [] },
    "broadvoice": { "version": "0.1.0", "source": "https://github.com/freeswitch/libbroadvoice/archive/refs/tags/v{version}.tar.gz",  "deps": [] },
    "opencv":  { "version": "4.10.0", "source": "https://github.com/opencv/opencv/archive/refs/tags/{version}.tar.gz",              "deps": [] },
    "pcre":    { "version": "10.48", "source": "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-{version}/pcre2-{version}.tar.gz", "deps": [] },
    "flite":   { "version": "2.2",    "source": "https://github.com/festvox/flite/archive/refs/tags/v{version}.tar.gz",           "deps": [] },
    "lua":     { "version": "5.3.6",  "source": "https://www.lua.org/ftp/lua-{version}.tar.gz",                                  "deps": [] }
  }
}
```

`deps` is the dependency graph: `openssl` and `libpng` need `zlib`, `libks`,
`rabbitmq-c` and `libpq` need `openssl`, `signalwire-client-c` needs `libks` and
`openssl`, `curl` needs `zlib` and `openssl`, `libpcap`, `lua`, `flite`, `pcre`, `opencv`, `broadvoice`, `g722_1`, `ilbc`, `libsilk`, `libtiff` and `mariadb-connector-c` stand alone, so each is built
after its dependencies and against their packages. The graph must be acyclic; `scripts/plan.ps1` validates it. Node
names are the package names FreeSWITCH already uses (`signalwire-client-c`, not
the repository name `signalwire-c`). In `source`, `{version}` expands to the
version and `{version_}` to the version with dots replaced by underscores
(curl tags its releases `curl-7_88_1`).

## Packages, versions and build numbers

Every dependency is published as a GitHub Release of this repository:

| | |
|---|---|
| Release tag | `<name>-v<version>_<build>`, e.g. `openssl-v3.4.7_2` |
| Package name | `<name>-<version>_<build>`, e.g. `openssl-3.4.7_2` — the zip prefix **and** the top-level folder inside every zip |
| Assets | `<pkg>-headers.zip`, `<pkg>-binaries-<platform>-<config>.zip` (x64 × Release/Debug by default), `SHA256SUMS.txt`, `<pkg>-BOM.txt` |

`<version>` is the upstream version from `deps.json`. `<build>` is the package
build number, the same idea as the `<lib>BuildNumber` FreeSWITCH already uses for
curl, libpq or libks: it separates *packages* of one upstream version. It is
**never written in the manifest**; `plan.ps1` derives it from the tags that
already exist: the next build of `openssl` `3.4.7` is `max(N in openssl-v3.4.7_N)
+ 1`, starting at 1. A build number goes up whenever a package is rebuilt:

- the dependency's own directory or version changed;
- a dependency it depends on (transitively) was rebuilt — e.g. bumping zlib
  produces `openssl-v3.4.7_<n+1>` although OpenSSL itself did not change;
- something that goes into every package changed (`scripts/common.ps1`,
  `scripts/build.ps1`, `docker/`): every package is rebuilt — unless the commit
  message scopes it: `[deps: libks,signalwire-client-c]` rebuilds only those
  nodes (plus their dependents, as always), `[deps: none]` says the shared
  change does not affect any package, `[deps: all]` is the default. Changes to
  `scripts/plan.ps1`, the workflows or docs never trigger rebuilds;
- a manual rebuild was requested.

The build number is part of the folder name inside the zips (unlike the old
CDN packages, where the folder was `curl-7.88.0` for every build). FreeSWITCH's
download task skips a package whose folder already exists under `libs\`, so this
is what makes a rebuilt package actually get picked up.

The `*-BOM.txt` asset records the source tarball and the exact dependency
packages (name + tag) a package was built against.

## How a change becomes builds

1. **plan** (`scripts/plan.ps1`, runs on every push to the default branch that
   touches `deps.json`, `deps/`, `scripts/`, `docker/` or the workflows):
   diffs the push, maps changed files to nodes (`deps/<name>/…` → `<name>`;
   `deps.json` → nodes whose version/source/deps changed; `scripts/common.ps1`,
   `scripts/build.ps1`, `docker/` → all, or what `[deps: …]` in the commit
   message says), adds nodes that have never been released for their current version,
   expands the set to all transitive dependents, sorts it topologically and
   assigns tags. Output: `plan.json` (also a workflow artifact).
   Files under `deps/<name>/freeswitch/` are the exception: they only say how
   FreeSWITCH consumes the package, never what goes into it, so editing them
   rebuilds nothing.
2. **one job per node** (`build.yml`): `needs` mirrors the graph edges, so
   `openssl` runs after `zlib`; each job is gated on the plan and skipped when
   its node is not affected (`!cancelled()` lets a job run when its upstream
   was *skipped*, but not when it *failed*). A job downloads the packages of
   dependencies built earlier in the same run (workflow artifacts) and takes
   the rest from their GitHub Releases, then runs `scripts/build.ps1 -Dep <name>
   -Plan plan.json -LocalPackages pkgs` and uploads `pkg-<name>`.
3. **publish**: one Release per affected node with the planned tag, only if
   every affected build succeeded, so the set of releases is consistent.

Examples: a commit touching only `deps/openssl/` rebuilds `openssl` (one job),
unless it touches nothing but `deps/openssl/freeswitch/`.
Bumping zlib in `deps.json` rebuilds `zlib`, then `openssl` against the new zlib
package from the same run. Editing `scripts/common.ps1` rebuilds everything.

Manual runs (*Actions → Build dependencies → Run workflow*) take a list of
nodes (or `all`) whose dependents are rebuilt too, and a `publish` switch;
without it they only produce workflow artifacts.

Runs on one ref are serialized (`concurrency`), so two pushes cannot compute the
same build number.

## Building locally

### With Docker (Windows containers)

The image holds the toolchain only (VS 2022 Build Tools, Perl, NASM, CMake, and
Meson + Ninja + Python + win_flex/win_bison for libpq); the
repository is mounted, so script edits need no image rebuild:

```powershell
docker build -t windows-deps docker

docker run --rm --cpus 8 --memory 8g -v ${PWD}:C:\src windows-deps -Dep zlib
docker run --rm --cpus 8 --memory 8g -v ${PWD}:C:\src windows-deps -Dep openssl
```

Output: `.\artifacts\<dep>\`. cmd.exe: replace `${PWD}` with `%cd%`.

### Natively

With Visual Studio 2022+ (C++ workload), CMake, and — for OpenSSL — Strawberry
Perl and NASM; libpq additionally needs Meson, Ninja, Python and
win_flex/win_bison (see `deps/libpq/prereqs.ps1`):

```powershell
.\scripts\build.ps1 -Dep zlib
.\scripts\build.ps1 -Dep openssl
```

Local builds have no plan: the version comes from `deps.json`, the build number
from `BUILD_NUMBER` (default `0`, i.e. `zlib-1.3.2_0`, clearly not a release),
and dependency packages from the environment or, failing that, from the latest
release of that dependency in this repository's tags — the same rule CI uses
(run `git fetch --tags` to have them). There is no lock file: the manifest plus
the tags are the only source of truth. To build openssl against a zlib you just
built locally (or before zlib has any release):

```powershell
$env:ZLIB_PKG_BASE = "$PWD\artifacts\zlib"   # directory (or URL) holding the zips
$env:ZLIB_PKG      = 'zlib-1.3.2_0'          # package name inside it
.\scripts\build.ps1 -Dep openssl
```

In Docker the same two variables are passed with `-e`, using the in-container
path `C:\src\artifacts\zlib`.

### Environment knobs

| Variable | Default | Meaning |
|---|---|---|
| `CONFIGS` | `Release Debug` | Configurations to build (space-separated). |
| `PLATFORMS` | `x64` | `x64` and/or `Win32`. |
| `OUT_DIR` | `<repo>\artifacts\<dep>` | Where zips, logs, checksums and BOM are written. |
| `BUILD_ROOT` | `C:\wd\<dep>` | Build tree (kept short: OpenSSL and nmake break past MAX_PATH). |
| `BUILD_NUMBER`, `PKG_NAME` | `0`, `<dep>-<ver>_<build>` | Set by the plan in CI. |
| `<DEP>_VERSION`, `<DEP>_URL` | from `deps.json` | Override a dependency's version / source tarball. |
| `<DEP>_PKG_BASE`, `<DEP>_PKG` | from plan / release tags | Where to take a dependency's package from (URL or directory) and its name. |
| OpenSSL: `ZLIB_MODE` | `zlib-dynamic` | `zlib-dynamic` (load `zlib.dll` at run time), `zlib` (link `zlibstatic.lib`), `none`. |
| OpenSSL: `OPENSSLDIR`, `EXTRA_CONFIG` | `C:/Program Files/FreeSWITCH/ssl`, `no-autoload-config` | Passed to `Configure`. |
| zlib: `EXTRA_CMAKE` | *(empty)* | Extra CMake configure arguments. |
| libpq: `PG_PREFIX` | `C:/Program Files/PostgreSQL/17` | `--prefix`; only reaches `pg_config_paths.h`, of which libpq uses `SYSCONFDIR` (where it looks for `pg_service.conf`). |
| libpq: `EXTRA_MESON` | *(empty)* | Extra `meson setup` arguments. |
| lua: `LUA_LIB_NAME`, `EXTRA_CFLAGS` | `lua<major><minor>`, *(empty)* | Name of the produced DLL/import library, extra `cl` flags. |

`<DEP>` is the dependency name upper-cased with `-` → `_` (`RABBITMQ_C_PKG_BASE`).

## Adding a dependency

1. Add a node to `deps.json` with its version, source URL template and `deps`.
2. Write `deps/<name>/build.ps1`: dot-source `scripts/common.ps1`, call
   `Get-BuildSettings '<name>'` and `Initialize-Toolchain`, fetch dependency
   packages with `Get-DepPackageRoot`, build inside `Invoke-BuildBatch`, stage
   files under `<pkg>/…`, zip with `New-PackageZip`, finish with
   `Write-Checksums`, `Write-Bom`, `Write-PackageSummary`. `deps/zlib` (CMake) and
   `deps/openssl` (nmake) are the two templates.
3. If the build needs tools a GitHub windows runner lacks, add
   `deps/<name>/prereqs.ps1` (and the same tools to `docker/Dockerfile`).
4. Add a job to `.github/workflows/build.yml` with `needs` listing `plan` plus
   the node's dependencies, copying the `if` pattern of the existing jobs, and
   add the node to the `publish` job's `needs`.
5. Add the reference props under `deps/<name>/freeswitch/w32/`.

## Consuming in FreeSWITCH

Each `deps/<name>/freeswitch/w32/` holds a copy of the corresponding files in
FreeSWITCH's `w32\`. They download from
`https://github.com/freeswitch/windows-deps/releases/download/<name>-v<ver>_<build>/`
into `libs\<name>-<ver>_<build>\`, and expose the version and build number as
`<name>Version` / `<name>BuildNumber` in `<name>-version.props`. Bumping a
package in FreeSWITCH is a change to those two values.

The build number is part of the folder name on purpose: FreeSWITCH's download
task skips a package whose folder already exists, so a rebuilt package would
otherwise never be picked up. libpng is the one node that also removed
something: FreeSWITCH used to build it in-tree from an unversioned tarball
(`libs\win32\libpng\libpng.2017.vcxproj`, `w32\download_libpng.props` and a
project in the solution — all gone), and `FreeSwitchCore` / `mod_png` import
`libpng.props` instead of referencing that project.

Notes carried over from the individual builders:

- **zlib 1.3.2 renamed its Windows outputs** (`z.dll`, `z.lib`, `zs.lib`);
  `deps/zlib/build.ps1` restores `zlib.dll` / `zlib.lib` / `zlibstatic.lib`
  (Debug: `zlibd…`) at link time via an injected CMake include, because the DLL
  name is baked into the import library.
- **OpenSSL loads zlib dynamically**: `--with-zlib-lib=zlib` (Debug: `zlibd`)
  is the DLL base name libcrypto `DSO_load()`s, i.e. exactly the DLL
  `zlib.props` deploys per configuration. Consumers link nothing extra. With
  the DLL absent, `COMP_zlib()` returns `NULL` and TLS treats compression as
  unavailable (OpenSSL 3.4's `cms -compress` crashes in that case: an upstream
  bug in `cms_cd.c`, not a packaging issue).
- **libks and signalwire-client-c** are built the way their own `win\` wrappers
  did it (CMake, target `ks2` / `signalwire_client2` only), minus the Visual
  Studio generator and minus the OpenSSL download from `files.freeswitch.org`.
  `Get-OpenSSLRootForCMake` (in `scripts/common.ps1`) assembles a conventional
  `include\` + `lib\` root from the openssl package so `FindOpenSSL` finds it
  via `OPENSSL_ROOT_DIR`; OpenSSL is linked statically into `ks2.dll`.
  `HUNTER_WIKI=ON` skips HunterGate, which both projects only need for their
  test harnesses. The libks headers package deliberately contains
  `libks\CMakeLists.txt` and `libks\cmake\ksutil.cmake` next to
  `libks\src\include`: signalwire-c's `FindLibKS.cmake` reads the version from
  the former and includes the latter. Neither library uses a debug postfix, so
  Debug files are `ks2.*` / `signalwire_client2.*` too. libks's public headers
  include `<openssl/ssl.h>`, so a consumer of the libks package also needs the
  OpenSSL headers on its include path (in FreeSWITCH: import `openssl.props`
  next to `libks.props`); nothing extra is linked.
- **curl is a static libcurl** shipped as `curl.lib` (Debug: curl's
  `libcurl-d.lib`, renamed the same way, plus its compiler PDB), like the old
  `curl-packaging` output. Consumers define `CURL_STATICLIB` and link OpenSSL,
  zlib (import library, `zlib.dll` at run time) and `Wldap32.lib`; the packaged
  `curl.props` imports `openssl.props` and `zlib.props` for that. The build
  verifies that zlib, OpenSSL and Win32 LDAP references are present in the
  library, i.e. that the feature set of the old packages was reproduced. The
  version stays on the 7.88 line (7.88.1) as FreeSWITCH ships; bumping to 8.x
  is a plain `deps.json` change.
- **libpcap is a static `pcap_static.lib` built with `PCAP_TYPE=null`**: it
  reads and writes pcap/pcapng files (what FreeSWITCH uses it for) and cannot
  capture live traffic, because no Npcap SDK is involved — same as the old
  packages. Remote capture is off, so OpenSSL is not used and the node has no
  dependencies (the old wrapper passed OpenSSL paths, and 1.10.4's CMake pulled
  OpenSSL in unconditionally; 1.10.7 only looks for it with `ENABLE_REMOTE`).
  Static CRT (`/MT`), libpcap's MSVC default and what the old packages had.
  The old wrapper's patched `CMakeLists.txt` boils down to
  `-D_CRT_DECLARE_NONSTDC_NAMES` (libpcap defines `__STDC__`, which makes the
  UCRT hide `strdup` & co.); the script passes that via `CMAKE_C_FLAGS` instead
  of patching. flex/bison are winflexbison, fetched at build time
  (`WINFLEX_VERSION`, default 2.5.25).
- **rabbitmq-c is the static `librabbitmq.4.lib`** with SSL support (the `4` is
  rabbitmq-c's SOVERSION; the build fails loudly if upstream ever changes it,
  because `rabbitmq-c.props` links that name). Only `mod_amqp` uses it. The
  package carries the deprecated top-level shims (`amqp.h`, `amqp_tcp_socket.h`,
  …) that `mod_amqp` includes as well as `rabbitmq-c/*.h` and the generated
  `rabbitmq-c/export.h`. The packaged `rabbitmq-c.props` now defines
  `AMQP_STATIC` (without it the API is declared `dllimport` and linking the
  static library only works with LNK4217 warnings, which is how the old
  packages were consumed) and imports `openssl.props`, since the static library
  references OpenSSL. 0.17.0 was chosen over FreeSWITCH's current 0.15.0 because
  0.16.0 and 0.17.0 are security releases; every `amqp_*` function `mod_amqp`
  calls is still present.
- **libpq is built with Meson**: PostgreSQL 17 removed `src\tools\msvc`, the
  MSBuild generator the old `libpq-packaging` drove, so the node configures the
  tree with Meson and builds the single shared `libpq` target — the server, psql
  and contrib are never compiled. Everything optional is off
  (`-Dauto_features=disabled`) except SSL and LDAP (`wldap32`, as the old
  `config.pl` had it). OpenSSL comes from this repository's package and is
  linked **statically** into `libpq.dll`: no OpenSSL DLL has to sit next to it,
  and since PostgreSQL links the DLL against its own `/DEF:` export list, only
  the `PQ*` API is exported, so the private copy of OpenSSL inside cannot clash
  with the one FreeSWITCH links itself. libpq does not use zlib — only the
  server and `pg_dump` do — so the node depends on `openssl` alone. The source
  is the official `postgresql-<version>.tar.gz` from `ftp.postgresql.org`, not a
  GitHub tag archive. The headers zip reproduces the old package's layout
  (`include\`, `include\libpq\`, `include\internal\`) plus the handful of
  headers PostgreSQL 17's `libpq-int.h` newly pulls in, so `include\internal`
  still resolves on its own; `mod_pgsql`, `mod_cdr_pg_csv` and the core's
  `switch_pgsql` need nothing beyond `libpq-fe.h`. Dynamic CRT (`/MD`, `/MDd`),
  like FreeSWITCH. `CC=cl` is set for the build because Strawberry Perl puts an
  ancient `ccache` on the machine PATH, which Meson would otherwise adopt as a
  compiler launcher.
- **mariadb-connector-c uses Schannel, not OpenSSL**, which is upstream's Windows
  default and what the previous packages did (hence the `Secur32.lib` in
  `mod_mariadb`'s link line), so the node depends on nothing else in the graph.
  `WITH_CURL=OFF` drops the AWS IAM plugin and with it a libcurl dependency;
  zlib comes from the bundled copy. The package keeps the layout the old one had:
  `libmariadb.dll`, its import library, the static `mariadbclient.lib`, the PDB
  and the client plugins under `plugin\`. Two things changed upstream since 3.0.9:
  `pvio_npipe` is now linked into the library instead of being a separate plugin
  (named pipes still work), and `client_ed25519` and `parsec` were added. The
  headers are exactly what upstream installs, so `mysql.h` — all `mod_mariadb`
  includes — is complete, while `mysql\client_plugin.h` still does not compile
  with MSVC (it pulls `ma_pvio.h`, which uses `ssize_t`, and `ma_compress.h`,
  which is not installed); that was already true of the 3.0.9 packages.
- **broadvoice replaces another in tree build.** FreeSWITCH fetched
  `broadvoice-<version>.tar.gz` from files.freeswitch.org with
  `w32\download_broadvoice.props` and compiled it through
  `libs\win32\broadvoice\libbroadvoice.2017.vcxproj`; this node does the same
  compilation from the GitHub release of `freeswitch/libbroadvoice` and ships
  `libbroadvoice.dll` plus its import library. The file list is upstream's own
  `libbroadvoice_la_SOURCES` from `src\Makefile.am`, plus `msvc\gettimeofday.c`,
  which its `WIN32SOURCES` adds for this platform; `BROADVOICE_EXPORTS` marks the
  API `__declspec(dllexport)` while building, so `mod_bv`, which does not define
  it, links through the import library. Only the three headers upstream installs
  are packaged, under `include\broadvoice\`, and `broadvoice.props` puts both
  `include\` and `include\broadvoice\` on the include path, because `mod_bv`
  writes `#include "broadvoice.h"` — the top level `broadvoice.h` of the
  autotools build is generated by configure and never existed on Windows.
- **g722_1 replaces the last in tree codec build.** `w32\download_g722_1.props`
  fetched `g722_1-<version>.tar.gz` from files.freeswitch.org and
  `libs\win32\libg722_1\libg722_1.2017.vcxproj` compiled it; this node runs the
  same compilation on the GitHub release of `freeswitch/libg7221` and ships the
  static `libg722_1.lib` that `mod_siren` linked before. The file list is
  upstream's `libg722_1_la_SOURCES` from `src\Makefile.am` plus
  `msvc\gettimeofday.c`, which its `WIN32SOURCES` adds for this platform. The
  public header declares no `dllimport` or `dllexport`, so a consumer needs no
  define, and `g722_1.props` puts both `include\` and `include\g722_1\` on the
  include path, because `mod_siren` writes `#include "g722_1.h"` — the top level
  `g722_1.h` of the autotools build is generated by configure and never existed
  on Windows. One upstream quirk: `g722_1_encode_release()` is a bare `free(s)`,
  so it may only be called on a state `g722_1_encode_init()` allocated;
  `mod_siren` keeps the state in its own struct and never calls it.
- **ilbc is the same story.** `w32\download_iLBC.props` fetched
  `ilbc-<version>.tar.gz` from files.freeswitch.org and
  `libs\win32\ilbc\libilbc.2017.vcxproj` compiled it; this node runs that
  compilation on the GitHub release of `freeswitch/libilbc` and ships the
  static `libilbc.lib`. The file list is upstream's `libilbc_la_SOURCES` from
  `src\Makefile.am`; its `WIN32SOURCES` also names `msvc\gettimeofday.c`, but
  nothing in the codec calls it and the in tree project left it out, so this
  node does too rather than put a second `gettimeofday` into the link. The
  public header declares nothing platform specific either, and `ilbc.props`
  puts both `include\` and `include\ilbc\` on the include path, because
  `mod_ilbc` writes `#include "ilbc.h"`. Both modes it registers are checked:
  20 ms / 160 samples / 38 bytes and 30 ms / 240 samples / 50 bytes.
- **libsilk is the last of the in tree codec builds**, and the only one that
  also moves version: the tree pinned 1.0.8, the node packages the 1.0.9
  release of `freeswitch/libsilk`. `w32\download_libsilk.props` fetched the
  tarball from files.freeswitch.org and
  `libs\win32\libsilk\Silk_FIX.2017.vcxproj` compiled it; the node compiles
  upstream's `libSKP_SILK_SDK_la_SOURCES` from `Makefile.am`, the same 109
  files that project listed -- 1.0.9 only renamed
  `SKP_Silk_apply_sine_window_new.c` back to `SKP_Silk_apply_sine_window.c`.
  The static library is called `libsilk.lib` after the package, where the in
  tree project called it `Silk_FIX.lib`; nothing links it by the old name any
  more, `libsilk.props` names it. The headers are upstream's
  `library_include_HEADERS` under `include\silk\`, the four `interface\`
  headers `mod_silk` compiles against plus the `src\` headers upstream
  installs beside them, and the sheet puts both `include\` and
  `include\silk\` on the include path for its `#include
  "SKP_Silk_SDK_API.h"`. The consumer test checks
  `SKP_Silk_SDK_get_version()` against the manifest.
- **libtiff jumps 4.0.7 to 4.7.2 and changes build system.** The tree kept a
  hand written list of 36 sources in
  `libs\win32\libtiff\libtiff.2017.vcxproj` and copied `tif_config.vc.h` /
  `tiffconf.vc.h` into place before compiling; 4.7 ships neither file, so the
  node drives upstream's CMake, which generates them. The source is the GitLab
  archive of the `v4.7.2` tag. Codecs match what the old project defined --
  CCITT (what fax needs), PackBits, LZW, ThunderScan, NeXT, LogLuv -- and
  everything needing a third party library stays off: the old project compiled
  `tif_zip.c`, `tif_jpeg.c`, `tif_ojpeg.c` and `tif_pixarlog.c` but never
  defined `ZIP_SUPPORT` or `JPEG_SUPPORT`, so those codecs were already inert,
  and the node needs no `zlib` edge. Upstream sets `CMAKE_DEBUG_POSTFIX` with a
  plain `set()` that a `-D` cannot override, so the library keeps its own names
  -- `tiff.lib` release, `tiffd.lib` debug -- and `tiff.props` selects between
  them through `$(LibraryConfiguration)`, as `opencv.props` does. The consumer
  test is spandsp's fax path: the same 12 TIFF-FX fields `t4_tx.c` registers
  through `TIFFSetTagExtender` / `TIFFMergeFieldInfo`, then a G4 page written
  and read back row by row.
- **opencv is a world build**, one `opencv_world<ver>.dll` plus its import
  library and the whole include tree, exactly the shape the 3.4.1 packages had.
  The jump from 3.4.1 to 4.10.0 is safe for `mod_cv` even though it still uses a
  few pieces of the legacy C API: 4.x keeps `IplImage`, `cvCreateImage`,
  `cvReleaseImage`, `cvPoint`, `cvSize` in `core\core_c.h` and `core\types_c.h`,
  and still ships `highgui\highgui_c.h`. What 4.x does drop is the old
  `include\opencv\` directory, so `opencv.props` expects
  `include\opencv2\opencv.hpp` and no longer puts `include\opencv\` on the
  include path. The library name carries the version (`opencv_world341` becomes
  `opencv_world4100`), which is the other line the property sheet has to follow.
  Nothing is downloaded while building: IPP and FFmpeg both fetch prebuilt
  binaries from `opencv_3rdparty` at configure time, so both are off; bindings,
  tests, apps and samples are off too, and so is `gapi`, which did not exist in
  the packages this replaces. The video capture backends are off as well
  (`WITH_MSMF`, `WITH_DSHOW`, `WITH_DIRECTX`, and `WITH_OBSENSOR`, which reaches
  for Media Foundation on its own): FreeSWITCH hands mod_cv its own frames and
  never opens a capture device, and without them the DLL no longer depends on
  Media Foundation or Direct3D, so it also loads on Server Core. The 3.4.1
  packages had the same problem through the Video for Windows backend.
- **pcre is PCRE2**, kept under the name FreeSWITCH packages it as: the core's
  `switch_regex.c` has been on the pcre2 API since the PCRE2 conversion, and the
  packages were already 10.x. Upstream's own CMake does everything, so the
  package is simply the install tree: `bin\` (the DLLs plus pcre2grep and
  pcre2test), `lib\` (import and static libraries, the CMake and pkg-config
  files) and `LICENCE.md`, with `include\` split into the headers zip. Only the
  8 bit code unit width is built, which is what `<pcre2.h>` with
  `PCRE2_CODE_UNIT_WIDTH 8` needs; JIT stays off, because nothing in FreeSWITCH
  calls `pcre2_jit_compile`. The `d` postfix on Debug files (`pcre2-8d.dll`)
  comes from upstream's CMakeLists, not from us. Note that the old
  `pcre-packaging` repository is not the ancestor of these packages — it still
  builds PCRE 8.34 from a hand written vcxproj.
- **flite is compiled by hand too**, and for the same reason: its own flite.sln
  only builds the SAPI engine, so FreeSWITCH used to carry a project for the
  library (`libs\win32\flite\flite.2015.vcxproj`, dropped in FS-11086 when flite
  moved to precompiled binaries). `deps/flite/build.ps1` rebuilds that with `cl`
  and `lib`: the same directories, the same defines (`CST_AUDIO_NONE`,
  `NO_UNION_INITIALIZATION`), dynamic CRT, one static `flite.lib` holding the
  core, `usenglish`, `cmulex` and the five voices `mod_flite` registers (kal,
  kal16, awb, rms, slt, plus cmu_time_awb). Which files a directory contributes
  is read from its own `Makefile` (`SRCS`, with `$(VOXNAME)` and friends
  expanded), so a version bump follows upstream; only the platform dependent
  picks are pinned in the script — the audio backend (`au_none`, `au_command`)
  and the `cst_mmap_win32` / `cst_file_stdio` flavours, exactly as the old
  project had them. Each directory is compiled in its own `cl` run, because the
  voices repeat file names and `cl` takes a single `/Fo`. The headers ship under
  `include\`, which `flite.props` renames to `flite\` while extracting, since
  `mod_flite` includes `<flite/flite.h>`. Debian packages 2.2 with patches, none
  of which apply here: they are autotools, docs and lintian fixes, and the one
  C change (`64bit`) only generalises a check that upstream already spells
  `_M_X64` for MSVC.
- **lua is compiled by hand**: upstream ships no build system for Windows beyond
  the two command lines in its own notes, and FreeSWITCH used to carry a vcxproj
  for it (`libs\win32\lua\lua.2015.vcxproj`, dropped in FS-10980 when lua moved
  to precompiled binaries). `deps/lua/build.ps1` does the same with `cl` and
  `link` directly: every `src\*.c` except the `lua.c` / `luac.c` front ends,
  `LUA_BUILD_AS_DLL` (which is what marks the API `__declspec(dllexport)`, so no
  .def file is needed), dynamic CRT, into `lua53.dll` + `lua53.lib`, plus
  `lua53.pdb` in Debug. Both tools get their file lists through response files,
  because `link.exe` does not expand wildcards. The source is the release tarball
  from lua.org, not the github.com/lua/lua tag archive: that one is the
  development mirror, it keeps the sources at the top level, carries the test
  suite, and has no `lua.hpp` — which the packages have always shipped (the
  script generates it when a source archive lacks it). `lua.exe` and `luac.exe`
  are not built, as before.
- **OpenSSL packages are `/MT`**, zlib packages `/MD`, as their predecessors
  were.
- **libpng replaces FreeSWITCH's in-tree build** (`libs\win32\libpng`, which
  compiled an unversioned tarball into `libpng16.dll`). The package keeps the
  `libpng16` names libpng's own CMake produces on MSVC (`libpng16.dll` +
  `libpng16.lib`, `libpng16_static.lib`, Debug postfix `d`). It is linked
  against the zlib *import* library of the same configuration, so
  `libpng16.dll` needs `zlib.dll` (Debug: `zlibd.dll`) at run time — the
  packaged `libpng.props` imports `zlib.props` for that. `FreeSwitchCore` and
  `mod_png` switch from the `ProjectReference` to importing `libpng.props`.
