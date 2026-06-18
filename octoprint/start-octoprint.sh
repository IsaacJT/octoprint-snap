#!/bin/sh -e
# SPDX-License-Identifier: GPL-2.0-only

# OctoPrint keeps all of its writable state (config.yaml, uploads, logs,
# timelapses, plugins, etc.) under a single "basedir". The snap is read-only,
# so this must live in a writable location. $SNAP_COMMON is shared across
# revisions and survives refreshes, which is what we want for server data.
OCTOPRINT_BASEDIR="${OCTOPRINT_BASEDIR:-$SNAP_COMMON/octoprint}"
mkdir -p "$OCTOPRINT_BASEDIR"

# --- Writable Python environment for user-installed plugins -----------------
# Everything under $SNAP is a read-only squashfs, so OctoPrint's bundled
# packages cannot be extended at runtime and the Plugin Manager's `pip install`
# would fail with a permission error. To let users install plugins, we run
# OctoPrint from a writable virtualenv kept in $SNAP_COMMON that layers on top
# of the bundled packages: pip installs land in the venv (writable), while
# OctoPrint and its dependencies are still imported from $SNAP.
VENV="$SNAP_COMMON/venv"
PYBIN="$SNAP/bin/python3"
PYV="$("$PYBIN" -c 'import sys; print("python%d.%d" % sys.version_info[:2])')"
SNAP_SITE="$SNAP/lib/$PYV/site-packages"

# Create the venv when missing or rebuild it when the bundled Python version
# changed (plugins compiled for the old version would be incompatible). When
# only the snap revision changed, the venv's interpreter symlink dangles; in
# that case upgrade it in place with `--upgrade` so the user's installed
# plugins are preserved across refreshes rather than wiped.
#
# The venv is created with --without-pip: the bundled interpreter does not ship
# ensurepip's wheels, so a normal venv creation fails. We don't need it anyway
# because pip (and setuptools/wheel) are imported from the snap's bundled
# site-packages via the .pth file written below. pip still installs *into* this
# venv because it targets the running interpreter's prefix.
if [ ! -d "$VENV" ] \
    || [ "$(cat "$VENV/.python-version" 2>/dev/null)" != "$PYV" ]; then
    rm -rf "$VENV"
    "$PYBIN" -m venv --without-pip "$VENV"
    printf '%s\n' "$PYV" > "$VENV/.python-version"
elif [ ! -x "$VENV/bin/python" ]; then
    "$PYBIN" -m venv --upgrade --without-pip "$VENV"
fi

# Expose the snap's bundled packages (OctoPrint itself and its dependencies) to
# the venv. We use site.addsitedir() rather than a bare path line so that the
# .pth files shipped in the snap's site-packages are also executed -- in
# particular setuptools' `distutils-precedence.pth`, which installs the
# `distutils` compatibility shim that Python 3.12+ no longer provides itself.
# A plain path entry would put the packages on sys.path but leave `distutils`
# unimportable. Packages the user installs into the venv still take precedence.
printf 'import site; site.addsitedir(%s)\n' "\"$SNAP_SITE\"" \
    > "$VENV/lib/$PYV/site-packages/snap-octoprint.pth"

# Keep pip's download cache in writable space (default is under $HOME, which is
# not writable for the daemon).
export XDG_CACHE_HOME="$SNAP_COMMON/.cache"

# Network interface/port the server binds to. These are managed via snap
# configuration (`snap set itrue-octoprint host=... port=...`) and seeded with
# defaults by the configure hook. Fall back to defaults defensively in case the
# values are somehow unset.
OCTOPRINT_HOST="$(snapctl get host)"
OCTOPRINT_PORT="$(snapctl get port)"
OCTOPRINT_HOST="${OCTOPRINT_HOST:-0.0.0.0}"
OCTOPRINT_PORT="${OCTOPRINT_PORT:-5000}"

# Run OctoPrint's bundled entry-point script with the venv's interpreter (the
# shebang is ignored). This makes sys.executable point at the writable venv, so
# the Plugin Manager installs plugins there instead of into the read-only snap.
exec "$VENV/bin/python" "$SNAP/bin/octoprint" serve \
    --basedir "$OCTOPRINT_BASEDIR" \
    --host "$OCTOPRINT_HOST" \
    --port "$OCTOPRINT_PORT" \
    --iknowwhatimdoing \
    "$@"
