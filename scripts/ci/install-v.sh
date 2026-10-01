#!/bin/sh
# ci/install-v.sh installs the V compiler into the workspace.
#
# Prefers a released binary over building from source: `makev.bat` on a Windows
# runner fails with "SetHandleInformation: The handle is invalid" when TCC is
# invoked in that environment, and building V is not what this project is
# testing. The released compiler is built elsewhere and just downloaded here.

set -eu

V_VERSION="${V_VERSION:-0.5.2}"

case "$(uname -s)" in
	Linux*)
		bin_name="v"
		;;
	Darwin*)
		bin_name="v"
		;;
	CYGWIN* | MINGW* | MSYS*)
		bin_name="v.exe"
		;;
	*)
		echo "unsupported host: $(uname -s)" >&2
		exit 2
		;;
esac

# The release archives are named per architecture, and only the Linux archive
# covers both. x86_64 is 64-bit on both Linux and macOS, so uname maps directly.
case "$(uname -m)" in
	x86_64 | amd64) triple="x86_64" ;;
	aarch64 | arm64) triple="arm64" ;;
	*)
		echo "unsupported arch: $(uname -m)" >&2
		exit 2
		;;
esac

case "$(uname -s)" in
	Linux*)
		# One archive serves both architectures.
		archive="v_linux.zip"
		;;
	Darwin*)
		archive="v_macos_${triple}.zip"
		;;
	*)
		archive="v_windows.zip"
		;;
esac

dest="${V_DEST:-$HOME/v}"
mkdir -p "$dest"

if [ ! -f "$dest/$bin_name" ]; then
	url="https://github.com/vlang/v/releases/download/${V_VERSION}/${archive}"
	echo "==> downloading $url"
	curl -fsSL "$url" -o /tmp/v-lang.zip
	rm -rf /tmp/v-lang-extract
	unzip -q -o /tmp/v-lang.zip -d /tmp/v-lang-extract
	# The archive holds a v/ directory with the compiler.
	cp "/tmp/v-lang-extract/v/$bin_name" "$dest/$bin_name"
	chmod +x "$dest/$bin_name"
	rm -rf /tmp/v-lang.zip /tmp/v-lang-extract
fi

# A downloaded compiler has no vlib next to it, so VEXE must point at the
# extracted binary or every build fails with
# "builtin/ not included on module lookup path".
export VEXE="$dest/$bin_name"
echo "VEXE=$VEXE" >> "$GITHUB_ENV"
echo "$dest" >> "$GITHUB_PATH"

"$VEXE" version