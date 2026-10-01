#!/bin/sh
# ci/install-v.sh installs the V compiler into the workspace.
#
# Building V on a Windows runner fails with "SetHandleInformation: The handle is
# invalid", which is the same TCC-in-this-environment failure the README
# documents for local builds. The released archive avoids the build entirely,
# but the 0.5.2 tag predates the json2 module this project uses, so neither a
# source build nor the release archive works there.
#
# What does work is running the Windows builds inside the V dev container, which
# has a Linux toolchain and builds v.exe for Windows with its own TCC. This
# script therefore installs the Linux compiler, and the Windows job builds the
# project for Windows with `-os windows -cc tcc` from Linux.

set -eu

V_REF="${V_REF:-master}"

case "$(uname -s)" in
	Linux*) ;;
	Darwin*) ;;
	CYGWIN* | MINGW* | MSYS*) ;;
	*)
		echo "unsupported host: $(uname -s)" >&2
		exit 2
		;;
esac

dest="${V_DEST:-$HOME/v}"

if [ ! -x "$dest/v" ]; then
	echo "==> cloning vlang/v ($V_REF)"
	rm -rf "$dest"
	git clone --depth=1 --branch "$V_REF" https://github.com/vlang/v "$dest"
	echo "==> building the compiler"
	make -C "$dest" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
	chmod +x "$dest/v"
fi

# VEXE points the compiler at its own checkout, which is how it locates vlib.
# Without it a downloaded or relocated compiler fails with
# "builtin/ not included on module lookup path".
VEXE="$dest/v"
export VEXE

[ -n "${GITHUB_ENV:-}" ] && echo "VEXE=$VEXE" >> "$GITHUB_ENV"
[ -n "${GITHUB_PATH:-}" ] && echo "$dest" >> "$GITHUB_PATH"

"$VEXE" version