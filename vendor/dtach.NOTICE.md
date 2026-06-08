# dtach — vendored binary + corresponding source

- **Binary:** `vendor/dtach` — SHA-256 `8184fabf28aaa9797031e1fba23def54238212b0ea4bb5b59f92984f6fb3d872`
- **Corresponding source:** `vendor/dtach-0.9.tar.gz` — SHA-256 `32e9fd6923c553c443fab4ec9c1f95d83fa47b771e6e1dafb018c567291492f3`
- **Version:** 0.9 (binary reports `dtach - version 0.9`)
- **Arch:** arm64 (Mach-O); links only `/usr/lib` system libraries (`libutil`, `libSystem`) — standalone, no Homebrew dependency.
- **Obtained from:** Homebrew `dtach 0.9` (`/opt/homebrew/Cellar/dtach/0.9/bin/dtach`), copied **unmodified**.
- **License:** GPL-2.0-or-later (full text in the source tarball's `COPYING`).

## How it's used
Cherminal invokes `dtach` as a **separate executable** (`posix_spawn`/exec), never
linked into the app — "mere aggregation" under the GPL. The unmodified binary is
copied into the app bundle's **`Contents/MacOS/dtach`** (the standard home for a
helper executable) at build time (see `project.yml` → the "Bundle dtach" build
script) so persistent sessions work without a Homebrew install; `Dtach.binaryPath`
prefers the bundled copy (`Bundle.main.url(forAuxiliaryExecutable:)`) and falls
back to `PATH`.

## GPL compliance
Committing this binary to the repo conveys it to anyone who clones, so under GPLv2
§3 the **corresponding source must accompany it** — third-party URLs alone are not
sufficient under GPLv2. The complete corresponding source for dtach 0.9 is
therefore vendored **on the same medium** as `vendor/dtach-0.9.tar.gz` (verify with
the SHA-256 above). It is the upstream 0.9 release:

- Upstream: https://github.com/crigler/dtach (tag `v0.9`) · https://dtach.sourceforge.net/
- Release tarball mirror: https://sourceforge.net/projects/dtach/files/dtach/0.9/
- Homebrew formula (build recipe): https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/d/dtach.rb

The bundled binary is the unmodified Homebrew build of this source.
