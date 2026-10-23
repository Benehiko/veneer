#!/bin/sh
set -eu

prefix=${1:-$HOME/.local}
case $prefix in
*[\"\`\$\\]*)
	echo "install.sh: the prefix must not hold quotes, backquotes, \$ or backslashes: $prefix" >&2
	exit 1
	;;
esac

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd)

cp -R "$here/bin" "$here/share" "$prefix/"

exec_path=$prefix/bin/veneer
case $exec_path in
*' '*) exec_line="Exec=\"$exec_path\"" ;;
*) exec_line="Exec=$exec_path" ;;
esac
entry=$prefix/share/applications/veneer.desktop
while IFS= read -r line; do
	case $line in
	Exec=*) printf '%s\n' "$exec_line" ;;
	*) printf '%s\n' "$line" ;;
	esac
done <"$here/share/applications/veneer.desktop" >"$entry"

icons=$prefix/share/icons/hicolor
if [ -f "$icons/icon-theme.cache" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
	gtk-update-icon-cache -f -t -q "$icons"
fi

echo "installed veneer in $prefix"
case ":$PATH:" in
*":$prefix/bin:"*) ;;
*) echo "$prefix/bin is not on PATH: the menu entry works, but to run veneer from a terminal, add it" ;;
esac
