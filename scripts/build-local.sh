#!/usr/bin/env bash
#
# Local ArmDesk build: check an edit before pushing, without waiting an hour
# for GitHub Actions and without publishing anything anywhere.
#
# The gain is not that this machine is faster than a runner (it is slower) but
# that it does not start from scratch. A runner installs Rust, builds ffmpeg
# through vcpkg and downloads Flutter anew every time: that is the hour. Here
# everything sits in a cache and survives the run, so the second and later
# builds take minutes.
#
#   ./scripts/build-local.sh --target windows --deps   # once, installs the tools
#   ./scripts/build-local.sh --target windows          # build
#   ./scripts/build-local.sh --target android
#   ./scripts/build-local.sh --target linux [--full]
#
# About Windows. A Windows client cannot be built from WSL: Flutter builds the
# Windows desktop through MSBuild and MSVC, and that pair has no
# cross-compilation. So the windows target works differently from the others:
# the sources, with the branding already applied, are synced to drive C:, and
# scripts/build-windows-local.ps1 starts the build on the host through WSL
# interop. The result stays on the Windows side, where it has to be run anyway.
#
# The versions of Rust, Flutter, the NDK and the vcpkg commit are read from
# .github/workflows/flutter-build.yml. Hardcoding them here would give a local
# build on versions other than CI's: such a check is worse than none.
#
# Branding edits the working tree, submodules included, exactly as on CI. That
# is expected, these edits are not to be committed, and they are undone with
# `git checkout -- libs/hbb_common src/lang`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW=".github/workflows/flutter-build.yml"
CACHE_DIR="${ARMILEN_BUILD_CACHE:-$HOME/.cache/armilen-remote-build}"
WIN_SRC_DIR="${ARMILEN_WIN_SRC:-/mnt/c/dev/armilen-remote}"
WIN_SRC_DIR_NATIVE='C:\dev\armilen-remote'

TARGET=""
DEPS=0
FULL=0
SYNC_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		TARGET="${2:-}"
		shift 2
		;;
	--deps)
		DEPS=1
		shift
		;;
	--full)
		FULL=1
		shift
		;;
	--sync-only)
		SYNC_ONLY=1
		shift
		;;
	-h | --help)
		awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0
		;;
	*)
		echo "Неизвестный аргумент: $1. Смотрите --help" >&2
		exit 1
		;;
	esac
done

case "$TARGET" in
windows | android | linux) ;;
"")
	echo "Укажите цель: --target windows|android|linux. Смотрите --help" >&2
	exit 1
	;;
*)
	echo "Неизвестная цель: $TARGET. Доступны windows, android, linux" >&2
	exit 1
	;;
esac

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() {
	printf '\n\033[1;31mОшибка:\033[0m %s\n' "$*" >&2
	exit 1
}

# A value from the workflow's env block: one source of truth for CI and the local build.
workflow_env() {
	local key="$1" file="${2:-$WORKFLOW}" value
	value="$(grep -m1 -E "^  ${key}: " "$file" | sed -E 's/^[^:]+: *"?([^"#]*[^"# ])"? *(#.*)?$/\1/')"
	[ -n "$value" ] || die "в $file не найден ключ $key"
	printf '%s' "$value"
}

RUST_VERSION="$(workflow_env RUST_VERSION)"
FLUTTER_VERSION="$(workflow_env FLUTTER_VERSION)"
ANDROID_FLUTTER_VERSION="$(workflow_env ANDROID_FLUTTER_VERSION)"
VCPKG_COMMIT_ID="$(workflow_env VCPKG_COMMIT_ID)"
NDK_VERSION="$(workflow_env NDK_VERSION)"
# CI pins LLVM 15.0.6, but it has no portable build for Windows: only an NSIS
# installer that needs an administrator. We take the nearest version that has
# an archive and with which bindgen parses the aom headers correctly
# (checked), see Install-Llvm
WIN_LLVM_VERSION="18.1.8"
CARGO_NDK_VERSION="$(workflow_env CARGO_NDK_VERSION)"

export VCPKG_ROOT="$CACHE_DIR/vcpkg"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export ANDROID_SDK_ROOT="$CACHE_DIR/android-sdk"

# Android has its own Flutter version. One clone for both targets would mean
# switching the branch between builds and downloading the engine again each time.
if [ "$TARGET" = "android" ]; then
	FLUTTER_ROOT="$CACHE_DIR/flutter-$ANDROID_FLUTTER_VERSION"
else
	FLUTTER_ROOT="$CACHE_DIR/flutter-$FLUTTER_VERSION"
fi
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH"

log "ArmDesk, локальная сборка (цель: $TARGET)"
echo "    Rust    $RUST_VERSION"
echo "    Кеш     $CACHE_DIR"

# ── Shared helpers ───────────────────────────────────────────────────────────

require_sudo() {
	sudo -n true 2>/dev/null && return 0
	cat >&2 <<-EOF

		Для системных пакетов нужен sudo, а он просит пароль, и в этом сеансе
		ввести его некуда. Выполните сначала

		    sudo -v

		и сразу следом ту же команду: пароль закешируется на несколько минут.
	EOF
	exit 1
}

install_rust() {
	log "Rust $RUST_VERSION"
	if ! command -v rustup >/dev/null 2>&1; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
			sh -s -- -y --default-toolchain "$RUST_VERSION" --no-modify-path
	fi
	rustup toolchain install "$RUST_VERSION" --component rustfmt
}

install_flutter() {
	local version="$1" root="$2"
	log "Flutter $version"
	if [ ! -d "$root" ]; then
		mkdir -p "$CACHE_DIR"
		git clone https://github.com/flutter/flutter.git --depth 1 -b "$version" "$root"
	fi
	git config --global --add safe.directory "$root" || true
}

install_vcpkg() {
	log "vcpkg ${VCPKG_COMMIT_ID:0:12}"
	mkdir -p "$CACHE_DIR"
	if [ ! -d "$VCPKG_ROOT/.git" ]; then
		git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
	fi
	git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT_ID"
	git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT_ID"
	[ -x "$VCPKG_ROOT/vcpkg" ] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
}

# Even cross builds need the host C toolchain: hwcodec's build.rs runs bindgen
# with the host libclang. Without the libc headers it fails on
# /usr/include/stdint.h with "'bits/libc-header-start.h' file not found", and
# the message gives no hint that a package is missing.
require_host_cc() {
	command -v clang >/dev/null 2>&1 || die "нет clang: sudo apt-get install -y clang"
	[ -f /usr/include/stdint.h ] || die "нет заголовков libc: sudo apt-get install -y libc6-dev"
}

# The Rust↔Dart bridge is not in the repository: `src/bridge_generated.rs` is
# in .gitignore, while `lib.rs` declares `mod bridge_generated`. Without it no
# target builds, not even `cargo build --lib`.
#
# The bridge is not generated here but downloaded ready-made, which is exactly
# what CI's own build jobs do in the "Restore bridge files" step: one separate
# job generates it, the rest take the artifact. Generating it locally would
# repeat a chain of cargo-expand, pub get, ffigen, cbindgen and freezed, where
# a failure of any link leaves a half-written bridge_generated.rs with an
# unclosed DUMMY CODE FOR BINDGEN block. Such a file looks newer than its
# input, passes any check by modification time and breaks the build with a
# reference to an undeclared Dart_Handle. The downloaded artifact is also
# byte-for-byte what the release is built from, including
# generated_bridge.freezed.dart, which local generation does not create at all.
BRIDGE_WORKFLOW="flutter-ci.yml"
BRIDGE_ARTIFACT="bridge-artifact"

restore_bridge() {
	if [ -f "src/bridge_generated.rs" ] && [ -f "flutter/lib/generated_bridge.freezed.dart" ]; then
		log "Мост на месте, пропускаем"
		return
	fi
	command -v gh >/dev/null 2>&1 || die "нужен gh для загрузки моста: https://cli.github.com"

	log "Мост Rust↔Dart: артефакт последней зелёной сборки CI"
	local run_id
	run_id="$(gh run list --workflow="$BRIDGE_WORKFLOW" --status success --limit 1 --json databaseId -q '.[0].databaseId')"
	[ -n "$run_id" ] || die "у $BRIDGE_WORKFLOW нет ни одного успешного прогона, мост брать неоткуда"

	local dest="$CACHE_DIR/bridge/$run_id"
	if [ ! -d "$dest" ]; then
		mkdir -p "$dest"
		gh run download "$run_id" -n "$BRIDGE_ARTIFACT" -D "$dest" ||
			die "не скачался артефакт $BRIDGE_ARTIFACT прогона $run_id (артефакты живут ограниченное время)"
	fi
	cp -a "$dest/." "$REPO_ROOT/"
	echo "    из прогона $run_id"
}

# The Android project's Gradle runs on Java 17: the CI job sets
# JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 explicitly. On the system
# Java 21 the build fails on Gradle being incompatible with the JVM version.
# Our own JDK goes into the cache, not into the system, so that the android
# target stays free of sudo.
JDK_DIR="$CACHE_DIR/jdk-17"

install_jdk17() {
	if [ -x "$JDK_DIR/bin/java" ]; then
		log "JDK 17 на месте"
		return
	fi
	log "JDK 17 (Temurin)"
	mkdir -p "$JDK_DIR"
	curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" |
		tar -xz -C "$JDK_DIR" --strip-components=1
	"$JDK_DIR/bin/java" -version
}

android_ndk_dir() {
	local dir
	dir="$(find "$ANDROID_SDK_ROOT/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)"
	[ -n "$dir" ] || die "NDK не найден, сначала --deps"
	printf '%s' "$dir"
}

# Branding lives in a composite action because some of its edits change files
# of the submodules. The same steps are run here, not a copy written
# alongside: a build with branding different from CI's would check nothing.
apply_branding() {
	log "Брендинг Armilen"
	python3 -c 'import yaml' 2>/dev/null || die "нужен PyYAML: sudo apt-get install -y python3-yaml"

	# The steps are passed as "name\0body\0": the bodies are multi-line and
	# cannot be split by newline
	while IFS= read -r -d '' name && IFS= read -r -d '' script; do
		echo "  · $name"
		bash -c "$script"
	done < <(python3 -c '
import sys, yaml

with open(".github/actions/apply-branding/action.yml") as f:
    action = yaml.safe_load(f)

for step in action["runs"]["steps"]:
    if not step.get("run"):
        continue
    sys.stdout.write(step.get("name", "шаг без имени") + "\0" + step["run"] + "\0")
')
}

# ── Windows ──────────────────────────────────────────────────────────────────

# Windows PowerShell 5.1 reads a .ps1 without a BOM as ANSI: Cyrillic in the
# script turns into garbage, the parser trips over a stray quote, and the
# error is about syntax, not about encoding. Checked explicitly because an
# editor can drop the BOM silently.
assert_ps_bom() {
	local ps="scripts/build-windows-local.ps1"
	[ "$(head -c 3 "$ps" | xxd -p)" = "efbbbf" ] ||
		die "$ps потерял UTF-8 BOM, PowerShell 5.1 прочитает кириллицу как ANSI. Вернуть: printf '\\\\xef\\\\xbb\\\\xbf' | cat - $ps > tmp && mv tmp $ps"
}

sync_to_windows() {
	assert_ps_bom
	log "Синхронизация исходников на диск C:"
	command -v rsync >/dev/null 2>&1 || die "нужен rsync: sudo apt-get install -y rsync"
	mkdir -p "$WIN_SRC_DIR"
	# target/ and flutter/build/ stay on the Windows side: they are its
	# artifacts, and dragging them through 9p would kill incrementality every time.
	#
	# Everything else in the list is the state of a particular machine, and it
	# must not cross the border between WSL and Windows. Flutter writes absolute
	# paths there: into package_config.json as paths to packages, into
	# ephemeral/.plugin_symlinks as symlinks to them. After `pub get` in WSL that
	# is /home/profax/.pub-cache/..., and on drive C: the build either looks for
	# sources by Linux paths or runs into broken symlinks in CMake. All of it is
	# recreated by `pub get` on the host, so there is one principle here: only
	# sources travel.
	rsync -a --delete \
		--exclude 'target/' \
		--exclude 'flutter/build/' \
		--exclude '.dart_tool/' \
		--exclude 'ephemeral/' \
		--exclude '.flutter-plugins' \
		--exclude '.flutter-plugins-dependencies' \
		--exclude '.git/' \
		"$REPO_ROOT/" "$WIN_SRC_DIR/"
	echo "    $WIN_SRC_DIR"
}

windows_deps() {
	# The bridge is put on the WSL side before the sync: the files are platform
	# independent, and they go to the host together with the sources
	apply_branding
	restore_bridge
	sync_to_windows
	cat <<-EOF

		Дальше нужна ваша рука: инструменты ставятся на стороне Windows и требуют
		прав администратора, то есть UAC должен спросить вас, а не меня.

		Откройте PowerShell от имени администратора и выполните одну строку:

		    powershell -ExecutionPolicy Bypass -File "${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1" -Deps

		Ставится Git, Python 3.12, Rustup, LLVM, CMake, NASM, Visual Studio 2022
		Build Tools с рабочей нагрузкой C++, Flutter ${FLUTTER_VERSION}, vcpkg и
		LLVM ${WIN_LLVM_VERSION} (bindgen привязан к версии libclang).
		Порядка 15 ГБ и около часа, один раз на машину.

		После этого сборка запускается отсюда и уже без вас:

		    ./scripts/build-local.sh --target windows
	EOF
}

build_windows() {
	apply_branding
	restore_bridge
	sync_to_windows
	[ "$SYNC_ONLY" -eq 0 ] || {
		log "Только синхронизация, сборку не запускаю"
		return
	}

	log "Сборка на стороне Windows"
	powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File "${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1" \
		-FlutterVersion "$FLUTTER_VERSION" \
		-RustVersion "$RUST_VERSION" \
		-VcpkgCommitId "$VCPKG_COMMIT_ID" \
		-LlvmVersion "$WIN_LLVM_VERSION" ||
		die "сборка на Windows не прошла"

	local out="$WIN_SRC_DIR/flutter/build/windows/x64/runner/Release"
	[ -d "$out" ] || die "сборка отработала, но каталога $out нет"
	log "Готово"
	echo "    Из WSL:     $out"
	echo "    Из Windows: ${WIN_SRC_DIR_NATIVE}\\flutter\\build\\windows\\x64\\runner\\Release\\rustdesk.exe"
}

# ── Android ──────────────────────────────────────────────────────────────────
# The only target that needs neither sudo nor Windows: the SDK, the NDK, Rust
# and Flutter are installed into the home directory.

android_deps() {
	require_host_cc
	install_jdk17
	install_rust
	rustup target add aarch64-linux-android
	install_flutter "$ANDROID_FLUTTER_VERSION" "$FLUTTER_ROOT"

	log "Android SDK и NDK $NDK_VERSION"
	local tools_dir="$ANDROID_SDK_ROOT/cmdline-tools"
	if [ ! -d "$tools_dir/latest" ]; then
		mkdir -p "$tools_dir"
		local zip="$CACHE_DIR/cmdline-tools.zip"
		curl -fsSL -o "$zip" https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
		unzip -q -o "$zip" -d "$tools_dir"
		mv "$tools_dir/cmdline-tools" "$tools_dir/latest"
		rm -f "$zip"
	fi

	local sdkmanager="$tools_dir/latest/bin/sdkmanager"
	# The workflow has a version like r28c, while sdkmanager knows only numeric
	# ones. Take the highest in the same major so as not to hardcode the mapping
	# r28c → 28.x.y: it would drift at the next CI update
	local ndk_major="${NDK_VERSION#r}"
	ndk_major="${ndk_major%%[a-z]*}"
	local ndk_pkg
	ndk_pkg="$("$sdkmanager" --list 2>/dev/null | grep -oE "ndk;${ndk_major}\.[0-9.]+" | sort -V | tail -1)" || true
	[ -n "$ndk_pkg" ] || die "в sdkmanager нет ветки NDK ${ndk_major}.x, ожидалась по $NDK_VERSION из workflow"

	yes | "$sdkmanager" --licenses >/dev/null 2>&1 || true
	"$sdkmanager" --install "platform-tools" "platforms;android-35" "build-tools;35.0.0" "$ndk_pkg"

	log "cargo-ndk $CARGO_NDK_VERSION"
	cargo install cargo-ndk --version "$CARGO_NDK_VERSION" --locked

	# hwcodec links with ffmpeg from vcpkg under Android too: without it its
	# build.rs fails on `VCPKG_ROOT` with a terse `NotPresent`. The triplet is
	# built by the same script as on CI, not by our own copy of the vcpkg command
	install_vcpkg
	log "Зависимости vcpkg под Android (arm64-android, первый раз это долго)"
	ANDROID_NDK_HOME="$(android_ndk_dir)" ANDROID_NDK_ROOT="$(android_ndk_dir)" \
		./flutter/build_android_deps.sh arm64-v8a

	log "Зависимости Android установлены"
}

build_android() {
	apply_branding
	restore_bridge
	require_host_cc
	command -v cargo-ndk >/dev/null 2>&1 || die "нет cargo-ndk, сначала --deps"
	[ -d "$VCPKG_ROOT/installed/arm64-android" ] || die "нет зависимостей vcpkg под arm64-android, сначала --deps"

	local ndk
	ndk="$(android_ndk_dir)"
	export ANDROID_NDK_HOME="$ndk"
	export ANDROID_NDK_ROOT="$ndk"

	# bindgen inside hwcodec calls libclang with the Android target but takes the
	# host set of includes. On ubuntu-22.04 with clang 14 it got away with that,
	# with clang 18 it reads /usr/include/stdint.h and does not find the
	# multiarch header bits/libc-header-start.h. An explicit sysroot from the NDK
	# removes the ambiguity and does not get in the way of older clang
	export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	log "Ядро Rust под aarch64 (ndk_arm64.sh, как на CI)"
	./flutter/ndk_arm64.sh

	local jni="flutter/android/app/src/main/jniLibs/arm64-v8a"
	mkdir -p "$jni"
	cp "./target/aarch64-linux-android/release/liblibrustdesk.so" "$jni/librustdesk.so"
	cp "$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$jni/"

	# There is no release key here and there must not be one, so the apk is
	# signed with the debug key. The same approach as on CI
	sed -i "s/signingConfigs.release/signingConfigs.debug/g" ./flutter/android/app/build.gradle
	# The same Gradle memory increase as on CI: the default 1 GB is not enough
	sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" ./flutter/android/gradle.properties

	log "APK (Java 17)"
	[ -x "$JDK_DIR/bin/java" ] || die "нет JDK 17, сначала --deps"
	(cd flutter && JAVA_HOME="$JDK_DIR" PATH="$JDK_DIR/bin:$PATH" \
		flutter build apk --release --target-platform android-arm64 --split-per-abi)
	git checkout -- ./flutter/android/app/build.gradle ./flutter/android/gradle.properties

	local apk="flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
	[ -f "$apk" ] || die "Flutter не отдал apk в $apk"

	# A file cannot be sent to the phone from WSL, so a copy is put into the
	# Windows Downloads folder, where Explorer can see it
	local user drop
	user="$(powershell.exe -NoProfile -Command 'Write-Output $env:USERNAME' 2>/dev/null | tr -d '\r\n')"
	drop="/mnt/c/Users/$user/Downloads"
	if [ -n "$user" ] && [ -d "$drop" ]; then
		cp "$apk" "$drop/armilen-remote-arm64.apk"
		log "Готово: $drop/armilen-remote-arm64.apk"
		echo "    В проводнике это Загрузки, оттуда закидывайте на телефон"
	else
		log "Готово: $REPO_ROOT/$apk"
	fi
}

# ── Linux ────────────────────────────────────────────────────────────────────

linux_deps() {
	require_sudo
	log "Системные пакеты"
	sudo apt-get update -y
	sudo apt-get install -y \
		build-essential clang cmake curl gcc git g++ \
		libayatana-appindicator3-dev libasound2-dev libclang-dev \
		libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev \
		libpam0g-dev libpulse-dev libva-dev \
		libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
		libxdo-dev libxfixes-dev nasm ninja-build pkg-config \
		python3 python3-yaml rpm rsync unzip wget xz-utils libssl-dev zip
	# libopus comes from vcpkg, the system one conflicts at link time
	sudo apt-get remove -y libopus-dev || true

	install_rust
	rustup target add x86_64-unknown-linux-gnu --toolchain "$RUST_VERSION"
	install_flutter "$FLUTTER_VERSION" "$FLUTTER_ROOT"
	flutter config --enable-linux-desktop
	flutter precache --linux

	install_vcpkg

	log "Зависимости Linux установлены"
}

build_linux() {
	apply_branding
	restore_bridge

	[ -x "$VCPKG_ROOT/vcpkg" ] || die "vcpkg не собран, сначала --deps"
	log "Зависимости vcpkg (x64-linux)"
	"$VCPKG_ROOT/vcpkg" install --triplet x64-linux --x-install-root="$VCPKG_ROOT/installed"

	log "Ядро Rust"
	cargo +"$RUST_VERSION" build --lib --features hwcodec,flutter,unix-file-copy-paste --release

	if [ "$FULL" -eq 0 ]; then
		log "Ядро собралось, правка компилируется"
		echo "    Полное приложение: ./scripts/build-local.sh --target linux --full"
		return
	fi

	log "Приложение Flutter"
	(cd flutter && flutter build linux --release)
	log "Готово: $REPO_ROOT/flutter/build/linux/x64/release/bundle"
}

# ── Dispatcher ───────────────────────────────────────────────────────────────

if [ "$DEPS" -eq 1 ]; then
	case "$TARGET" in
	windows) windows_deps ;;
	android) android_deps ;;
	linux) linux_deps ;;
	esac
	exit 0
fi

case "$TARGET" in
windows) build_windows ;;
android) build_android ;;
linux) build_linux ;;
esac
