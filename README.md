# edidrandr

autorandr-style monitor profiles for X11, but matched by **EDID** instead of
output names (`DisplayPort-6` may become `DisplayPort-8` after a dock/MST
re-enumeration; the monitor's EDID doesn't change).

Pure Zig (0.15), stdlib only: it speaks the X11 protocol and the RandR
extension directly over `/tmp/.X11-unix/X<n>` (with MIT-MAGIC-COOKIE auth from
`~/.Xauthority`). No Xlib/xcb, no `xrandr` binary.

```sh
zig build -Doptimize=ReleaseSafe     # -> zig-out/bin/edidrandr
zig build test
zig-out/bin/edidrandr --version
```

## Usage

```sh
edidrandr                  # connected monitors + profiles (detected/current)
edidrandr save docked      # store the current layout
edidrandr change           # apply the profile matching the connected monitors
edidrandr load docked      # apply a specific profile
edidrandr daemon           # watch RandR hotplug events, run `change` on each
edidrandr --dry-run change # show what would be done
```

Start `edidrandr daemon &` from `~/.xinitrc` / your WM autostart to switch
automatically on hotplug (no udev rule needed).

Profiles live in `$XDG_CONFIG_HOME/edidrandr/<name>.json`. An executable
`$XDG_CONFIG_HOME/edidrandr/postswitch` is run with the profile name after a
switch (e.g. to restart your bar or reset the wallpaper).

## How matching works

- Fingerprint = SHA-256 of the 128 byte EDID base block (extension blocks are
  ignored because some monitors rewrite them when FreeSync/HDR is toggled).
- EDID is read from the RandR `EDID` output property; if the driver doesn't
  provide it, from `/sys/class/drm/*/edid` via the `CONNECTOR_ID` property.
  Outputs without any EDID fall back to `output:<name>`.
- A profile matches if the set of connected fingerprints is equal. Identical
  monitors (same EDID, e.g. no serial number) are told apart by output name.
- With several matching profiles, `change` keeps an already active one,
  otherwise applies the alphabetically first.

## Not supported (yet)

Scaling/transforms, panning, gamma, custom DPI (screen size is set at 96 DPI),
TCP `DISPLAY`s.

## Continuing development

Code map: `src/x11.zig` (X11 + RandR wire protocol), `src/edid.zig` (EDID
parsing and fingerprint), `src/main.zig` (profiles, matching, apply, CLI,
daemon). See `CLAUDE.md` for conventions and how to test safely against a live
X server (scratch `XDG_CONFIG_HOME`, `--dry-run` first).

Open items, roughly by usefulness:

1. **Scaling / transforms** (`xrandr --scale`, HiDPI setups). Add
   `GetCrtcTransform` (RandR minor 27) / `SetCrtcTransform` (26), store the
   3x3 fixed-point matrix plus filter in `OutputConfig`, and use the
   transformed size when computing the screen size in `apply`.
2. **Real hotplug testing of `daemon`.** Only startup and idle waiting have
   been exercised; verify dock/undock, sleep/resume and MST re-enumeration.
   Check whether 1.5 s debounce is enough for docks.
3. **Fallback profile** for unknown monitor sets (autorandr's `--default`),
   e.g. enable all connected outputs side by side at preferred mode.
4. **Profile priority** when several profiles match the same monitors
   (currently: keep the active one, else alphabetical first). Options: remember
   the last used profile per monitor set, or a `priority` field.
5. **DPI**: optional `dpi` per profile instead of the fixed 96 DPI used for
   the screen's physical size.
6. **Panning** (`GetPanning`/`SetPanning`, minors 28/29) and **gamma**
   (minors 22–24), if needed.
7. **TCP displays** (`host:N` → port 6000+N) and the Linux abstract socket
   `@/tmp/.X11-unix/XN` for sandboxed environments.
8. **Mirroring onto one CRTC**: today every enabled output gets its own CRTC;
   if a GPU runs out of CRTCs, outputs with identical mode/position could share
   one.

When adding fields to profiles, give them defaults so existing JSON files
keep loading, and don't change the fingerprint without a migration path.

## Versioning and releases

The version lives in exactly one place: `.version` in `build.zig.zon`
(semver). `build.zig` combines it with `git describe` for `--version`:

| checkout                          | `edidrandr --version`            |
|-----------------------------------|----------------------------------|
| clean tag `v0.2.0`                | `0.2.0`                          |
| 3 commits after `v0.2.0`          | `0.2.0-dev.3+gabc1234`           |
| uncommitted changes               | `...+gabc1234.dirty`             |
| no matching tag / no git          | `0.2.0-dev+gabc1234` / `0.2.0`   |

`zig build -Dversion-string=...` overrides it (e.g. for distro packages built
from a tarball). Building a clean tag that disagrees with `build.zig.zon` fails
on purpose.

To release:

1. Bump `.version` in `build.zig.zon` (`0.2.0`, or `0.2.0-rc1` for a pre-release).
2. Commit: `git commit -am "Release 0.2.0"`
3. Tag and push: `git tag v0.2.0 && git push origin master v0.2.0`

The tag triggers `.github/workflows/release.yml`, which runs the tests, builds
static `x86_64-linux-musl` and `aarch64-linux-musl` binaries (ReleaseSafe),
checks that `--version` matches the tag, and publishes a GitHub release with
the tarballs, `SHA256SUMS` and generated release notes. Tags containing `-`
are marked as pre-releases. `.github/workflows/ci.yml` checks formatting,
tests and the release targets on every push to `master` and on pull requests.
