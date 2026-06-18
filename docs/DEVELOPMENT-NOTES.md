# OctoPrint Snap — Development Notes

A running summary of the work done on the `itrue-octoprint` snap, the problems
encountered, and the decisions made to resolve them. Newest context builds on
older sections, so reading top-to-bottom mirrors how the snap evolved.

## Overview

`itrue-octoprint` packages [OctoPrint](https://octoprint.org/) as a strictly
confined snap. Key files:

- `snap/snapcraft.yaml` — snap definition (base, metadata, apps, parts).
- `octoprint/start-octoprint.sh` — launcher for the OctoPrint daemon.
- `snap/hooks/configure` — validates/seeds `host`/`port` snap config.

---

## 1. Build failure: Tornado / "up-to-date SSL module"

**Symptom:** `pip install octoprint` failed during the build with
`ImportError: Tornado requires an up-to-date SSL module`, with paths showing
`python3.14`.

**Root cause:** `base: core26` ships Python 3.14, which OctoPrint does not
support. OctoPrint's `setup.py` declares `python_requires=">=3.7, <3.14"`, so
3.14 is explicitly excluded; the Tornado message was a misleading symptom.

**Fix:** Changed the base to `core24` (Python 3.12), which OctoPrint supports.

---

## 2. Auto-set snap version from the OctoPrint package

Wanted the snap version to track the installed OctoPrint version.

**Fix:** Used `adopt-info: octoprint` plus an `override-build` step that reads
the installed version via `importlib.metadata` and calls
`craftctl set version="$ver"`. (Reading metadata avoids importing OctoPrint,
which has side effects.)

---

## 3. Launcher script + making the snap runnable

`octoprint/start-octoprint.sh` was fleshed out to start the server, and the
part was updated to install it into `$SNAP/bin`.

Key launcher decisions:
- Writable data (`--basedir`) lives in `$SNAP_COMMON/octoprint`, since `$SNAP`
  is read-only.
- `--host` / `--port` come from snap config with sane defaults.
- `exec` is used so the process receives signals directly from systemd.

An `apps:` entry was added (`daemon: simple`) with plugs:
`network`, `network-bind`, `raw-usb`, `hardware-observe`, `serial-port`,
`camera`.

---

## 4. Configurable host/port via a configure hook

Added `snap/hooks/configure` (auto-packaged from `snap/hooks/`) which:
- Seeds defaults (`host=0.0.0.0`, `port=5000`) on first run.
- Validates that `port` is a real TCP port (1–65535), rejecting bad input.
- Restarts the service when already running so changes take effect.

The launcher reads the values with `snapctl get host` / `snapctl get port`.

Usage: `snap set itrue-octoprint port=8080`.

---

## 5. Running as root

OctoPrint refuses to run as root by default. We initially explored dropping to
the `snap_daemon` system user, but per the user's decision we instead pass
`--iknowwhatimdoing` to `octoprint serve` so it runs as root (the snap default).
A side benefit is that serial/USB device permissions (e.g. `/dev/ttyUSB*`,
`root:dialout`) just work without group juggling.

---

## 6. Upstream metadata

Added standard snap metadata pulled directly from OctoPrint's `setup.py`:

| Field | Value |
|-------|-------|
| `title` | OctoPrint |
| `license` | `AGPL-3.0-only` |
| `website` | https://octoprint.org |
| `contact` | https://community.octoprint.org |
| `issues` | https://github.com/OctoPrint/OctoPrint/issues |
| `source-code` | https://github.com/OctoPrint/OctoPrint |
| `donation` | https://support.octoprint.org |

The license field uses the SPDX identifier; the classifier
"GNU Affero General Public License v3" (without "or later") maps to
`AGPL-3.0-only`.

---

## 7. yamllint cleanup

`yamllint` (default config) flagged the file. Fixes:
- Added the `---` document-start marker.
- Wrapped the over-length lines in `override-build` (version detection moved to
  a heredoc; the `install` command split across continuation lines).

The file lints clean against yamllint defaults.

---

## 8. socat serial-over-telnet bridge (later removed)

A second app + `socat` part + `socat/start-serial-forward.sh` were added to
expose a network/telnet printer as a local virtual serial port. This went
through several iterations:

- Initially `daemon` disabled by default (`install-mode: disable`).
- "Restart when the client closes the port" was first implemented with
  `restart-condition: always` + `restart-delay`, which caused OctoPrint
  autodetection to fail ("Port ... is busy or does not exist") because socat
  was repeatedly down during the restart-delay window.
- Diagnosis used snapd's `udev-support.c` (PTY slave majors 136–143 are always
  allowed, ruling out the device cgroup) and the socat man page.
- The correct fix was socat's `ignoreeof` (keep the same pty alive across
  client connect/disconnect) plus `TCP:...,forever,interval=2`. Also fixed a
  typo (`intervall` → `interval`) and confirmed the option is `wait-slave`
  (not `waitslave`).

**This entire feature was subsequently removed in favor of using an OctoPrint
plugin instead** (e.g. `OctoPrint-Remote_connection`, "Serial over IP").

---

## 9. Plugins can't be installed: read-only pip directory

**Symptom:** Installing OctoPrint plugins via the Plugin Manager failed because
OctoPrint's Python environment lives in the read-only `$SNAP` squashfs.

**Chosen approach (kept):** Run OctoPrint from a **writable virtualenv** in
`$SNAP_COMMON/venv` that layers the bundled packages on top of itself, so
`pip install` lands in writable space. Implemented in
`octoprint/start-octoprint.sh`:

1. Create the venv in `$SNAP_COMMON/venv`.
2. Layer the snap's bundled `site-packages` into it (see distutils note below).
3. Run `"$VENV/bin/python" "$SNAP/bin/octoprint" serve …` so `sys.executable`
   is the venv → the Plugin Manager installs into the venv.
4. Redirect pip's cache to `$SNAP_COMMON/.cache`.

Lifecycle handling:
- **Python version change** → rebuild the venv (ABI-incompatible plugins).
- **Snap revision change only** → `python -m venv --upgrade` repairs the
  dangling interpreter symlink *in place*, preserving installed plugins.

### 9a. `ensurepip is not available`

The bundled interpreter doesn't ship ensurepip's wheels, so normal venv
creation failed. **Fix:** create the venv with `--without-pip`; pip is imported
from the snap's bundled `site-packages` (added `pip` to `python-packages` to
guarantee it's present). pip still installs *into* the venv because it targets
the running interpreter's prefix.

### 9b. `ModuleNotFoundError: No module named 'distutils'`

Python 3.12 removed `distutils`; setuptools re-injects it via a
`distutils-precedence.pth` that must be *executed*. A bare path line in our
`.pth` only appended to `sys.path` without executing the snap's `.pth` files.
**Fix:** the layering `.pth` now uses
`import site; site.addsitedir("<snap site-packages>")`, which both adds the
directory and runs the `.pth` files in it (activating setuptools' distutils
shim). User-installed venv packages still take precedence.

---

## Known caveats / follow-ups

- **Plugins needing C compilation won't install** — there's no compiler in the
  runtime; pure-Python/wheel plugins are fine.
- **Interface auto-connection:** most device plugs (`raw-usb`, `serial-port`,
  `camera`) need manual `snap connect` after install.
- **Not yet built/validated:** changes have not been run through `snapcraft`
  end-to-end. Suggested smoke test after building:
  - Daemon starts with no `ensurepip`/`distutils` errors; `$SNAP_COMMON/venv`
    exists.
  - A pure-Python plugin installs into `$SNAP_COMMON/venv/...` and loads after a
    restart.
  - A `snap refresh`/revision bump preserves installed plugins (the `--upgrade`
    path).
- `grade: devel` — revisit before stable publication.
