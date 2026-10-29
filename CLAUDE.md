# CLAUDE.md

autorandr-style X11 monitor profiles matched by EDID fingerprint instead of
output name. See README.md for user-facing behaviour.

## Hard constraints

- **Zig stdlib only.** No Xlib/xcb/libXrandr, no C imports, no shelling out to
  `xrandr`. New X functionality means implementing the wire request in
  `src/x11.zig`.
- Target is **Zig 0.15.2** (post-"writergate" std): `std.ArrayList` is
  unmanaged (`.empty`, `append(gpa, x)`), output goes through `*std.Io.Writer`
  (`File.stdout().writer(&buf)` then `.interface`, remember `flush()`), JSON
  via `std.json.Stringify.valueAlloc` / `parseFromSliceLeaky`, `{t}` formats
  enums/errors. Check `/opt/zig-bin-0.15.2/lib/std` when unsure about an API.

## Commands

```sh
zig build                 # -> zig-out/bin/zigautorandr
zig build test            # unit tests (no X server needed)
zig build run -- status   # args after --
```

CI runs `zig fmt --check build.zig build.zig.zon src`; run `zig fmt` before
committing.

## Versioning

- `.version` in `build.zig.zon` is the only place the version is written.
  `build.zig` reads it **at build time** with `std.zon.parse` instead of
  `@import("build.zig.zon")`: Zig 0.15 doesn't rebuild the cached build runner
  when only the manifest changes, so an import would keep reporting a stale
  version after a bump.
- `resolveVersion` appends `git describe` info (`-dev.N+gHASH[.dirty]`); the
  program gets it via the `build_options` module (`--version`).
- Never change `.fingerprint`.
- Releases are tag-driven (`vX.Y.Z` → `.github/workflows/release.yml`); see
  README "Versioning and releases". Don't create tags or push without being
  asked.

## Layout

- `src/x11.zig` – X11 connection (unix socket, Xauthority cookie, setup
  parsing), request builder, reply/error/event dispatch, and RandR >= 1.3
  requests. Native byte order is announced in setup, so `get()`/`Request.put`
  use native endian. Requests without a reply report errors only at the next
  `sync()` (`pending_error`); `last_error` holds details for
  `error.XRequestFailed`.
- `src/edid.zig` – validation, fingerprint (SHA-256 of the 128 byte base block,
  first 16 bytes as hex), human readable description.
- `src/main.zig` – profile JSON schema (`OutputConfig`/`Profile`), `gatherState`
  (current X state, EDID via RandR property with sysfs fallback through
  `CONNECTOR_ID`), `matchProfile`, `pickMode`, `isApplied`, `apply` (grab
  server → disable changed/non-fitting CRTCs → SetScreenSize → SetCrtcConfig →
  primary → sync), CLI commands and the `daemon` loop.

Allocation: a per-run arena (`ctx.arena`); the daemon resets an arena per
iteration. Only `Connection.events` and the daemon's `last_key` use `gpa`.

## Profile format compatibility

Profiles in `~/.config/zigautorandr/*.json` are user data. New `OutputConfig`
fields must have defaults so old profiles keep parsing
(`ignore_unknown_fields` is on). Don't change the fingerprint algorithm
without a migration – it would silently stop every saved profile from matching.

## Testing against a real X server

Commands run against the live `$DISPLAY` and **`load`/`change`/`daemon`
reconfigure the user's real monitors**.

- Always point `XDG_CONFIG_HOME` at a scratch directory so the user's profiles
  are untouched.
- Use `--dry-run` first; it prints the exact plan (CRTC disables, screen size,
  per-output modes) without sending any changing request.
- Only apply live when needed, keep changes small (e.g. move one output a few
  pixels), and restore the original profile right after; verify with
  `xrandr --listmonitors`.
- Hotplug (daemon reacting to real plug/unplug) can't be exercised from a
  session; say so instead of claiming it's tested.
