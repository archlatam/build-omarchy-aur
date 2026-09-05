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