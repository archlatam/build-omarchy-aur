# build-omarchy-aur

Secure AUR package builder for Arch-based systems (Omarchy/Arch). It compiles
AUR packages inside a disposable Arch Linux Docker container, runs a static
security scan on the package files beforehand, and copies the resulting
`.pkg.tar.zst` back to the host so it can be installed with `pacman -U`.

## Features

- Ephemeral build container based on `archlinux:latest` with `base-devel`,
  running `makepkg` as a non-root user.
- Static security scan of `PKGBUILD`, `*.install`, `*.patch` and `*.sh` files
  before building: high-risk patterns **abort** the build, softer flags only
  print a warning.
- Optional offline compile phase (`ISOLATE=1`): dependencies and sources are
  resolved with network, then `build()`/`package()` run with no network.
- Built packages are copied to the script's own directory on the host.
- Automatic cleanup: after each build only the AUR-tracked files remain in the
  package subdirectory (sources, `pkg/`, `src/` and duplicate packages are
  removed).
- Containers are always removed when the build finishes.

## Requirements

- Docker with a running daemon. If your user is not in the `docker` group, the
  script falls back to `sudo docker` (it will prompt for your password).
- An Arch-based host (repo layout/ABI matches Arch Linux).

## Quick start

```bash
cd build-omarchy-aur
./build-omarchy-aur.sh          # normal build (with network)
ISOLATE=1 ./build-omarchy-aur.sh  # two-phase build; compile runs offline
```

When prompted, paste one of these:

```
https://aur.archlinux.org/brave-bin.git
https://aur.archlinux.org/packages/brave-bin
brave-bin
```

The first run builds the `omarchy-aur-builder` Docker image (base image +
`base-devel`), which can take a few minutes.

## How it works

1. The host script ensures the Docker daemon is reachable (starts it via
   `systemctl` if needed, falls back to `sudo docker`).
2. It normalizes the given URL/name and clones the AUR package into a mounted
   volume (`/res/<pkgname>`).
3. `scan-pkgbuild.sh` inspects the package files inside the container.
4. `makepkg -s --noconfirm --nocheck` installs missing dependencies and builds
   the package.
5. The resulting `.pkg.tar.zst` is copied to the script directory root.
6. `git clean -fdx` plus `git checkout -- .` strip all build leftovers from
   the clone, keeping only the tracked AUR sources.
7. The container is removed and the install command is printed.

## Security model

The scanner aborts the build if it detects high-risk patterns:

- Downloads piped straight into an interpreter (`curl ... | bash`, etc.)
- `curl`/`wget` with `-k` / `--insecure` / `--no-check-certificate`
- Obfuscation/decoding of payloads (`base64 -d`, `xxd -r`, `openssl enc/dgst`)
- Embedded code execution (`eval`, `bash -c`, `sh -c`, `python -c`,
  `python -e`, `node -e`, `perl -e`)
- Reverse shells / exfiltration (`nc -e`, `/dev/tcp`, `/dev/udp`, `mkfifo`)
- System compromise (`>/etc/passwd`, `>/etc/shadow`, `>/etc/sudoers`,
  `usermod` to wheel, `LD_PRELOAD`)
- Credential harvesting (`~/.ssh`, `.bash_history`, `.gnupg`)

Softer patterns only warn; they are commonly used legitimately and deserve
manual review rather than an automatic block:

- SUID/SGID (`setuid`, `setgid`, `chmod 4xxx`) — e.g. `chrome-sandbox` in
  browser packages
- `npm`/`yarn`/`pnpm` or `pip` installing directly from a URL
- `npm run build/start`, `./configure --prefix`

> The scan is a first-pass filter, not a substitute for reading the `PKGBUILD`.
> Sophisticated payloads can be obfuscated past a static grep.

### ISOLATE mode

Phase 1 (network): syncs pacman, installs dependencies and downloads/extracts
the sources with `makepkg -o`. The container is committed. Phase 2 (no network)
compiles and packages with `makepkg --noextract --nodeps`. This closes the
build phase against data exfiltration and second-stage payload downloads.

## AUR search & risk screening (`search-aur.sh`)

`search-aur.sh` queries the full AUR metadata
(`packages-meta-ext-v1.json.gz`), applies combinable filters, sorts the
results, and annotates each package with a security **risk** score and a
potential **typosquatting** match. It is complementary to the build scanner:
use it *before* deciding which package to build or trust.

### Requirements

- `curl` and `jq`.
- `python3` (optional, only needed for typosquatting detection).

### Usage

```
./search-aur.sh [options] [N]
```

`N` (optional, default 100) is the number of results to show.

General search options:

| Option | Meaning |
| --- | --- |
| `-q <regex>` | search in name + description + keywords (case-insensitive regex) |
| `-v <n>` | minimum votes (`NumVotes >= n`) |
| `-p <x>` | minimum popularity (e.g. `0.5`) |
| `-s <field>` | sort by `name`, `popularity` (default), `votes` or `modified` |
| `-r` | reverse the sort order |

Security (metadata) filters:

| Option | Meaning |
| --- | --- |
| `-o` | only out-of-date packages (`OutOfDate != null`) |
| `-u` | only orphaned packages (no maintainer) |
| `-m <user>` | only packages from a maintainer (substring) |
| `-l <text>` | filter by license (substring) |
| `-i` | only packages with an `http://` (unencrypted) source URL |
| `-x` | only packages whose source URL points at a direct IP |
| `--short` | only packages using a URL shortener/pastebin (`bit.ly`, `tinyurl`, `t.co`, ...) |
| `--nolicense` | only packages with no declared license |
| `-c` | only recent submissions with high popularity (suspicious spikes) |
| `-k` | only packages with risky keywords (`keygen`, `crack`, `wallet`, `miner`, ...) |
| `--risk <n>` | only show packages with a risk score >= n (the `risk` column is always printed) |

Typosquatting options (require `python3`):

| Option | Meaning |
| --- | --- |
| `-y` | only show packages whose name resembles a popular one |
| `-d <n>` | maximum edit distance to consider a match (default 1) |
| `-w <n>` | maximum votes for a package to be considered suspicious (default 200) |
| `--typo-scan <n>` | candidate scan window for `-y` (default 3000) |

### Risk score

Each package is given a `risk` score (0 = no signals, max ~9). It is a
*review hint, not a verdict* — legitimate packages can score points for
innocuous signals such as a missing license declaration.

| Signal | Points |
| --- | --- |
| No maintainer (orphaned) | +1 |
| Out-of-date | +1 |
| `http://` source URL (not encrypted) | +1 |
| Source URL pointing at a direct IP | +2 |
| Source URL using a shortener/pastebin | +2 |
| No declared license | +1 |
| Submitted recently (< 60 days) | +1 |

### How typosquatting detection works

With `-y`, the script does not just scan the top-`N` results (which are all
famous, high-vote packages). It scans a wider **candidate window**: the top
`--typo-scan` packages (default 3000) by popularity **with fewer than `-w`
votes** (default 200). It then normalizes each name (lowercase, strips common
suffixes like `-git`, `-bin`, `-static`) and compares it against ~80 well-known
package names with a Levenshtein edit distance. Names shorter than 4 characters
are ignored to avoid noise (e.g. `pi` vs `pip`). If nothing is found, a hint
(`-d 2` / `-w 5000` give more reach) is printed.

### Examples

```bash
./search-aur.sh 50                                    # top 50 by popularity
./search-aur.sh -q 'git' -v 500 20                    # search + minimum votes
./search-aur.sh --risk 3 -s votes 10                  # risk >= 3, ranked by votes
./search-aur.sh -o -i -x -s modified 50               # out-of-date / http / direct IP, most recent
./search-aur.sh -k -u --risk 2 20                     # risky keywords + orphans, risk >= 2
./search-aur.sh -y                                    # typosquats across the wide scan window
./search-aur.sh -y -d 2 -w 500 10                     # wider distance / more votes
```

> Note: the risk threshold is `--risk <n>` (a long flag); `-r` is reserved for
> reversing the sort order.

## Output and installation

After a successful build the package is available at:

```
~/Downloads/build-omarchy-aur/<pkgname>-<version>-x86_64.pkg.tar.zst
```

Install it on the host with:

```bash
sudo pacman -U ~/Downloads/build-omarchy-aur/*.pkg.tar.zst
```

Omarchy/Arch accepts unsigned local packages (`LocalFileSigLevel = Optional` by
default), so no signature is required. Existing runtime dependencies are
resolved automatically by pacman.

## Cleanup behavior

- The build subdirectory keeps only git-tracked AUR files (`PKGBUILD`,
  `.SRCINFO`, `*.install`, `*.sh`, `*.patch`, ...).
- Downloaded source archives, `pkg/`, `src/` and the duplicate
  `.pkg.tar.zst` inside the clone are deleted.
- When the script finishes, no build container is left behind.

## Troubleshooting

- **Docker daemon is inactive / permission denied**: the script starts the
  service and falls back to `sudo docker`. For passwordless use, add your user
  to the `docker` group (`sudo usermod -aG docker $USER`) and re-login.
- **Scanner edits do not take effect**: the scanner is baked into the image at
  build time. Recreate the image so the container picks it up:

  ```bash
  docker rmi omarchy-aur-builder:latest
  ./build-omarchy-aur.sh   # rebuilds the image on the next run
  ```

## Known limitations

- GPG signing of the built packages is not implemented yet.
- Network isolation applies to the compile phase only; dependency resolution
  and source download require network access.