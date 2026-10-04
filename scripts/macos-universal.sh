#!/usr/bin/env bash
# Merges two built .app bundles (x86_64 and arm64) into one universal bundle.
#
# Why: every Mac since 2020 is Apple Silicon, and the x86_64 build runs on
# them through Rosetta 2, which the system offers to install at first launch.
# For a support tool that extra dialog appears at the very moment when
# something has already broken for the person. A universal binary removes
# both it and the question "which version do I download" on the download page.
#
# How: a universal bundle shares its resources and Info.plist, only the
# machine code differs. So the arm64 bundle is taken as the base (it has a
# newer MACOSX_DEPLOYMENT_TARGET and ScreenCaptureKit enabled), walked in
# full, and every Mach-O file is replaced with the result of lipo with the
# same-named file from the x86_64 bundle.
#
# Usage:
#   scripts/macos-universal.sh <x86_64.app> <arm64.app> <output .app>

set -euo pipefail

if [ $# -ne 3 ]; then
	echo "usage: $0 <x86_64.app> <arm64.app> <output.app>" >&2
	exit 2
fi

x64_app=$1
arm_app=$2
out_app=$3

for app in "$x64_app" "$arm_app"; do
	[ -d "$app" ] || { echo "not a bundle: $app" >&2; exit 1; }
done

rm -rf "$out_app"
# -R keeps the symlinks inside frameworks (Versions/Current -> A), without
# them the bundle stops loading.
cp -R "$arm_app" "$out_app"

merged=0
arm_only=0

# -type f skips symlinks, and they need no touching: they are already copied
# as symlinks and point to the files we replace in place.
while IFS= read -r rel; do
	out_file="$out_app/$rel"
	x64_file="$x64_app/$rel"

	file -b "$out_file" | grep -q 'Mach-O' || continue

	if [ ! -f "$x64_file" ]; then
		# The binary exists only in the arm64 build. Left as is: the bundle will
		# start on Apple Silicon and not on Intel, which is better than silently
		# breaking both.
		echo "  only in arm64, left as is: $rel"
		arm_only=$((arm_only + 1))
		continue
	fi

	lipo -create "$x64_file" "$out_file" -output "$out_file.universal"
	mv -f "$out_file.universal" "$out_file"
	merged=$((merged + 1))
done < <(cd "$arm_app" && find . -type f | sed 's|^\./||')

echo "binaries merged: $merged, arm64 only: $arm_only"
[ "$merged" -gt 0 ] || { echo "no Mach-O file was merged, something is wrong with the bundle layout" >&2; exit 1; }

# lipo strips the signature, and arm64 macOS refuses to run unsigned code at
# all: without an ad-hoc signature the universal bundle would crash on the
# very machines it is built for. Signing goes from the inside out: --deep is
# deprecated for ad-hoc and does not always work on nested frameworks.
while IFS= read -r rel; do
	f="$out_app/$rel"
	file -b "$f" | grep -q 'Mach-O' && codesign --force --sign - "$f" >/dev/null 2>&1 || true
done < <(cd "$out_app" && find . -type f | sed 's|^\./||')
codesign --force --sign - "$out_app"

# A check of what it was all done for.
main_bin="$out_app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$out_app/Contents/Info.plist")"
archs=$(lipo -archs "$main_bin")
echo "architectures of $main_bin: $archs"
for want in x86_64 arm64; do
	case " $archs " in
		*" $want "*) ;;
		*) echo "the main binary has no $want slice" >&2; exit 1 ;;
	esac
done
codesign --verify --deep --strict "$out_app"
echo "universal bundle ready: $out_app"
