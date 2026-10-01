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
		archive="v_linux.zip"
		bin_name="v"
		;;
	Darwin*)
		archive="v_macos.zip"
		bin_name="v"
		;;
	CYGWIN* | MINGW* | MSYS*)
		archive="v_windows.zip"
		bin_name="v.exe"
		;;
	*)
		echo "unsupported host: $(uname -s)" >&2
		exit 2
		;;
esac

dest="${V_DEST:-$HOME/v}"
mkdir -p "$dest"

if [ ! -x "$dest/$bin_name" ] && [ ! -f "$dest/$bin_name" ]; then
	url="https://github.com/vlang/v/releases/download/${V_VERSION}/${archive}"
	echo "==> downloading $url"
	curl -fsSL "$url" -o /tmp/v-lang.zip
	unzip -q -o /tmp/v-lang.zip -d /tmp/v-lang-extract
	# The archive contains a v/ directory.
	cp "/tmp/v-lang-extract/v/$bin_name" "$dest/$bin_name"
	chmod +x "$dest/$bin_name"
	rm -rf /tmp/v-lang.zip /tmp/v-lang-extract
fi

echo "$dest" >> "$GITHUB_PATH"
"$dest/$bin_name" version