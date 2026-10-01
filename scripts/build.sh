#!/bin/sh
# build.sh builds torabot for the host platform.
#
# Usage: ./scripts/build.sh [os] [arch] [output-dir]
#
# The os and arch default to the host's, which is what the CI workflow uses.
# Each target is built natively on a runner for that platform rather than
# cross-compiled: a cross build needs a full target C toolchain including a
# cross-built libgc, and V passes -cc straight to the C compiler.
#
# Examples:
#   ./scripts/build.sh                        # host defaults
#   ./scripts/build.sh linux amd64            # explicit
#   ./scripts/build.sh windows amd64 dist

set -eu

PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
V="${V:-v}"

host_os() {
	case "$(uname -s)" in
		Linux*) echo linux ;;
		Darwin*) echo macos ;;
		CYGWIN* | MINGW* | MSYS*) echo windows ;;
		*) echo unknown ;;
	esac
}

host_arch() {
	case "$(uname -m)" in
		x86_64 | amd64) echo amd64 ;;
		aarch64 | arm64) echo arm64 ;;
		*) echo "$(uname -m)" ;;
	esac
}

OS="${1:-$(host_os)}"
ARCH="${2:-$(host_arch)}"
OUT_DIR="${3:-dist}"

case "$OS" in
	linux)
		# gcc builds a dynamically linked binary against the runner's glibc.
		# For a static build, install musl-tools and use -musl instead.
		CC_CMD="-cc ${CC:-gcc}"
		;;
	windows)
		# TCC ships with V and needs no extra toolchain. It must be named
		# explicitly: the implicit compiler path can fail to build libgc and
		# fall back to a gcc that may not be installed.
		CC_CMD="-cc tcc"
		;;
	macos)
		# Xcode's clang; V passes the target through.
		CC_CMD="-cc clang"
		;;
	*)
		echo "unsupported os: $OS (expected linux, windows or macos)" >&2
		exit 2
		;;
esac

case "$ARCH" in
	amd64 | arm64) ;;
	*)
		echo "unsupported arch: $ARCH (expected amd64 or arm64)" >&2
		exit 2
		;;
esac

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/torabot-$OS-$ARCH"

echo "==> building $OS/$ARCH: v -os $OS $CC_CMD"

# -d no_vschannel only changes the Windows build, where Schannel is the default
# net.http TLS backend and cannot complete a handshake with Discord. It is a
# no-op elsewhere, so one command line covers every target.
#
# -prod drops debug info. Note that TCC ignores it, so Windows binaries are the
# same size as debug builds.
"$V" -o "$OUT" -os "$OS" $CC_CMD -prod -d no_vschannel "$PROJECT_ROOT/main.v"

echo "==> built $OUT"
ls -lh "$OUT"