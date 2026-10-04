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
# The output is in English, or in Russian on a Russian system.
# ARMDESK_LANG=en|ru overrides the choice.
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

# ── Messages ─────────────────────────────────────────────────────────────────
# English by default, because the repository is public; Russian on a Russian
# system. Each value is a printf format. Both tables carry the same keys with
# the same placeholders: scripts/check-build-messages.mjs.
declare -A MSG_EN=(
	[unknown_arg]='Unknown argument: %s. See --help'
	[no_target]='Pick a target: --target windows|android|linux. See --help'
	[unknown_target]='Unknown target: %s. Available: windows, android, linux'
	[error_label]='Error:'
	[workflow_key_missing]='%s has no key %s'
	[banner]='ArmDesk, local build (target: %s)'
	[cache_line]='    Cache   %s'
	[sudo_needed]='
System packages need sudo, and sudo asks for a password that this session has
no way to enter. Run this first:

    sudo -v

and then the same command right away: the password stays cached for a few minutes.'
	[no_clang]='clang is missing: sudo apt-get install -y clang'
	[no_libc_headers]='libc headers are missing: sudo apt-get install -y libc6-dev'
	[bridge_present]='The bridge is in place, skipping'
	[gh_needed]='gh is needed to download the bridge: https://cli.github.com'
	[bridge_fetch]='Rust↔Dart bridge: the artifact of the last green CI build'
	[bridge_no_run]='%s has no successful run, so there is nowhere to take the bridge from'
	[bridge_download_failed]='artifact %s of run %s was not downloaded (artifacts are kept for a limited time)'
	[bridge_from_run]='    from run %s'
	[jdk_present]='JDK 17 is in place'
	[ndk_missing]='NDK not found, run --deps first'
	[branding]='Armilen branding'
	[pyyaml_needed]='PyYAML is needed: sudo apt-get install -y python3-yaml'
	[unnamed_step]='unnamed step'
	[ps_bom_lost]="%s lost its UTF-8 BOM, and PowerShell 5.1 will read its Cyrillic as ANSI. To restore it: printf '\\\\xef\\\\xbb\\\\xbf' | cat - %s > tmp && mv tmp %s"
	[sync_sources]='Syncing the sources to drive C:'
	[rsync_needed]='rsync is needed: sudo apt-get install -y rsync'
	[windows_deps_howto]='
The next step needs your hand: the tools are installed on the Windows side and
need administrator rights, so UAC has to ask you, not me.

Open PowerShell as administrator and run this one line:

    %s

It installs Git, Python 3.12, Rustup, CMake, NASM, Visual Studio 2022
Build Tools with the C++ workload, Flutter %s, vcpkg and
LLVM %s (bindgen is tied to the libclang version).
About 15 GB and about an hour, once per machine.

After that the build is started from here, with nothing more needed from you:

    ./scripts/build-local.sh --target windows'
	[sync_only]='Sync only, not starting the build'
	[building_on_windows]='Building on the Windows side'
	[windows_build_failed]='the Windows build failed'
	[out_dir_missing]='the build finished, but %s does not exist'
	[done]='Done'
	[out_from_wsl]='    From WSL:     %s'
	[out_from_windows]='    From Windows: %s'
	[android_sdk]='Android SDK and NDK %s'
	[ndk_branch_missing]='sdkmanager has no NDK %s.x line, which %s in the workflow calls for'
	[vcpkg_android_deps]='vcpkg dependencies for Android (arm64-android, slow the first time)'
	[android_deps_done]='Android dependencies installed'
	[no_cargo_ndk]='cargo-ndk is missing, run --deps first'
	[no_vcpkg_android]='vcpkg dependencies for arm64-android are missing, run --deps first'
	[rust_core_android]='Rust core for aarch64 (ndk_arm64.sh, as on CI)'
	[no_jdk]='JDK 17 is missing, run --deps first'
	[no_apk]='Flutter produced no apk at %s'
	[done_at]='Done: %s'
	[apk_in_downloads]='    In Explorer this is Downloads; send it to the phone from there'
	[system_packages]='System packages'
	[linux_deps_done]='Linux dependencies installed'
	[vcpkg_not_built]='vcpkg is not built, run --deps first'
	[vcpkg_linux_deps]='vcpkg dependencies (x64-linux)'
	[rust_core]='Rust core'
	[core_built]='The core built: the edit compiles'
	[full_app_hint]='    Full application: ./scripts/build-local.sh --target linux --full'
	[flutter_app]='Flutter application'
)
declare -A MSG_RU=(
	[unknown_arg]='Неизвестный аргумент: %s. Смотрите --help'
	[no_target]='Укажите цель: --target windows|android|linux. Смотрите --help'
	[unknown_target]='Неизвестная цель: %s. Доступны windows, android, linux'
	[error_label]='Ошибка:'
	[workflow_key_missing]='в %s не найден ключ %s'
	[banner]='ArmDesk, локальная сборка (цель: %s)'
	[cache_line]='    Кеш     %s'
	[sudo_needed]='
Для системных пакетов нужен sudo, а он просит пароль, и в этом сеансе
ввести его некуда. Выполните сначала

    sudo -v

и сразу следом ту же команду: пароль закешируется на несколько минут.'
	[no_clang]='нет clang: sudo apt-get install -y clang'
	[no_libc_headers]='нет заголовков libc: sudo apt-get install -y libc6-dev'
	[bridge_present]='Мост на месте, пропускаем'
	[gh_needed]='нужен gh для загрузки моста: https://cli.github.com'
	[bridge_fetch]='Мост Rust↔Dart: артефакт последней зелёной сборки CI'
	[bridge_no_run]='у %s нет ни одного успешного прогона, мост брать неоткуда'
	[bridge_download_failed]='не скачался артефакт %s прогона %s (артефакты живут ограниченное время)'
	[bridge_from_run]='    из прогона %s'
	[jdk_present]='JDK 17 на месте'
	[ndk_missing]='NDK не найден, сначала --deps'
	[branding]='Брендинг Armilen'
	[pyyaml_needed]='нужен PyYAML: sudo apt-get install -y python3-yaml'
	[unnamed_step]='шаг без имени'
	[ps_bom_lost]="%s потерял UTF-8 BOM, PowerShell 5.1 прочитает кириллицу как ANSI. Вернуть: printf '\\\\xef\\\\xbb\\\\xbf' | cat - %s > tmp && mv tmp %s"
	[sync_sources]='Синхронизация исходников на диск C:'
	[rsync_needed]='нужен rsync: sudo apt-get install -y rsync'
	[windows_deps_howto]='
Дальше нужна ваша рука: инструменты ставятся на стороне Windows и требуют
прав администратора, то есть UAC должен спросить вас, а не меня.

Откройте PowerShell от имени администратора и выполните одну строку:

    %s

Ставится Git, Python 3.12, Rustup, CMake, NASM, Visual Studio 2022
Build Tools с рабочей нагрузкой C++, Flutter %s, vcpkg и
LLVM %s (bindgen привязан к версии libclang).
Порядка 15 ГБ и около часа, один раз на машину.

После этого сборка запускается отсюда и уже без вас:

    ./scripts/build-local.sh --target windows'
	[sync_only]='Только синхронизация, сборку не запускаю'
	[building_on_windows]='Сборка на стороне Windows'
	[windows_build_failed]='сборка на Windows не прошла'
	[out_dir_missing]='сборка отработала, но каталога %s нет'
	[done]='Готово'
	[out_from_wsl]='    Из WSL:     %s'
	[out_from_windows]='    Из Windows: %s'
	[android_sdk]='Android SDK и NDK %s'
	[ndk_branch_missing]='в sdkmanager нет ветки NDK %s.x, ожидалась по %s из workflow'
	[vcpkg_android_deps]='Зависимости vcpkg под Android (arm64-android, первый раз это долго)'
	[android_deps_done]='Зависимости Android установлены'
	[no_cargo_ndk]='нет cargo-ndk, сначала --deps'
	[no_vcpkg_android]='нет зависимостей vcpkg под arm64-android, сначала --deps'
	[rust_core_android]='Ядро Rust под aarch64 (ndk_arm64.sh, как на CI)'
	[no_jdk]='нет JDK 17, сначала --deps'
	[no_apk]='Flutter не отдал apk в %s'
	[done_at]='Готово: %s'
	[apk_in_downloads]='    В проводнике это Загрузки, оттуда закидывайте на телефон'
	[system_packages]='Системные пакеты'
	[linux_deps_done]='Зависимости Linux установлены'
	[vcpkg_not_built]='vcpkg не собран, сначала --deps'
	[vcpkg_linux_deps]='Зависимости vcpkg (x64-linux)'
	[rust_core]='Ядро Rust'
	[core_built]='Ядро собралось, правка компилируется'
	[full_app_hint]='    Полное приложение: ./scripts/build-local.sh --target linux --full'
	[flutter_app]='Приложение Flutter'
)

# ARMDESK_LANG=ru|en decides; otherwise the locale does. WSL usually has none of
# its own (C.UTF-8), so there the language of the Windows host is asked.
ui_lang() {
	case "${ARMDESK_LANG:-}" in
	ru | en)
		printf '%s' "$ARMDESK_LANG"
		return
		;;
	esac
	case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
	ru*)
		printf ru
		return
		;;
	esac
	if command -v powershell.exe >/dev/null 2>&1 &&
		[ "$(powershell.exe -NoProfile -Command '(Get-UICulture).TwoLetterISOLanguageName' 2>/dev/null | tr -d '\r\n')" = ru ]; then
		printf ru
		return
	fi
	printf en
}
UI_LANG="$(ui_lang)"

msg() {
	local key="$1" format
	shift
	if [ "$UI_LANG" = ru ]; then format="${MSG_RU[$key]}"; else format="${MSG_EN[$key]}"; fi
	# shellcheck disable=SC2059  # the table value is the format
	printf "$format" "$@"
}

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
		echo "$(msg unknown_arg "$1")" >&2
		exit 1
		;;
	esac
done

case "$TARGET" in
windows | android | linux) ;;
"")
	echo "$(msg no_target)" >&2
	exit 1
	;;
*)
	echo "$(msg unknown_target "$TARGET")" >&2
	exit 1
	;;
esac

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() {
	printf '\n\033[1;31m%s\033[0m %s\n' "$(msg error_label)" "$*" >&2
	exit 1
}

# A value from the workflow's env block: one source of truth for CI and the local build.
workflow_env() {
	local key="$1" file="${2:-$WORKFLOW}" value
	value="$(grep -m1 -E "^  ${key}: " "$file" | sed -E 's/^[^:]+: *"?([^"#]*[^"# ])"? *(#.*)?$/\1/')"
	[ -n "$value" ] || die "$(msg workflow_key_missing "$file" "$key")"
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

log "$(msg banner "$TARGET")"
echo "    Rust    $RUST_VERSION"
echo "$(msg cache_line "$CACHE_DIR")"

# ── Shared helpers ───────────────────────────────────────────────────────────

require_sudo() {
	sudo -n true 2>/dev/null && return 0
	echo "$(msg sudo_needed)" >&2
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
	command -v clang >/dev/null 2>&1 || die "$(msg no_clang)"
	[ -f /usr/include/stdint.h ] || die "$(msg no_libc_headers)"
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
		log "$(msg bridge_present)"
		return
	fi
	command -v gh >/dev/null 2>&1 || die "$(msg gh_needed)"

	log "$(msg bridge_fetch)"
	local run_id
	run_id="$(gh run list --workflow="$BRIDGE_WORKFLOW" --status success --limit 1 --json databaseId -q '.[0].databaseId')"
	[ -n "$run_id" ] || die "$(msg bridge_no_run "$BRIDGE_WORKFLOW")"

	local dest="$CACHE_DIR/bridge/$run_id"
	if [ ! -d "$dest" ]; then
		mkdir -p "$dest"
		gh run download "$run_id" -n "$BRIDGE_ARTIFACT" -D "$dest" ||
			die "$(msg bridge_download_failed "$BRIDGE_ARTIFACT" "$run_id")"
	fi
	cp -a "$dest/." "$REPO_ROOT/"
	echo "$(msg bridge_from_run "$run_id")"
}

# The Android project's Gradle runs on Java 17: the CI job sets
# JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 explicitly. On the system
# Java 21 the build fails on Gradle being incompatible with the JVM version.
# Our own JDK goes into the cache, not into the system, so that the android
# target stays free of sudo.
JDK_DIR="$CACHE_DIR/jdk-17"

install_jdk17() {
	if [ -x "$JDK_DIR/bin/java" ]; then
		log "$(msg jdk_present)"
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
	[ -n "$dir" ] || die "$(msg ndk_missing)"
	printf '%s' "$dir"
}

# Branding lives in a composite action because some of its edits change files
# of the submodules. The same steps are run here, not a copy written
# alongside: a build with branding different from CI's would check nothing.
apply_branding() {
	log "$(msg branding)"
	python3 -c 'import yaml' 2>/dev/null || die "$(msg pyyaml_needed)"

	# The steps are passed as "name\0body\0": the bodies are multi-line and
	# cannot be split by newline
	while IFS= read -r -d '' name && IFS= read -r -d '' script; do
		echo "  · $name"
		bash -c "$script"
	done < <(UNNAMED_STEP="$(msg unnamed_step)" python3 -c '
import os, sys, yaml

with open(".github/actions/apply-branding/action.yml") as f:
    action = yaml.safe_load(f)

for step in action["runs"]["steps"]:
    if not step.get("run"):
        continue
    sys.stdout.write(step.get("name", os.environ["UNNAMED_STEP"]) + "\0" + step["run"] + "\0")
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
		die "$(msg ps_bom_lost "$ps" "$ps" "$ps")"
}

sync_to_windows() {
	assert_ps_bom
	log "$(msg sync_sources)"
	command -v rsync >/dev/null 2>&1 || die "$(msg rsync_needed)"
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
	echo "$(msg windows_deps_howto \
		"powershell -ExecutionPolicy Bypass -File \"${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1\" -Deps" \
		"$FLUTTER_VERSION" "$WIN_LLVM_VERSION")"
}

build_windows() {
	apply_branding
	restore_bridge
	sync_to_windows
	[ "$SYNC_ONLY" -eq 0 ] || {
		log "$(msg sync_only)"
		return
	}

	log "$(msg building_on_windows)"
	powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File "${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1" \
		-FlutterVersion "$FLUTTER_VERSION" \
		-RustVersion "$RUST_VERSION" \
		-VcpkgCommitId "$VCPKG_COMMIT_ID" \
		-LlvmVersion "$WIN_LLVM_VERSION" \
		-Lang "$UI_LANG" ||
		die "$(msg windows_build_failed)"

	local out="$WIN_SRC_DIR/flutter/build/windows/x64/runner/Release"
	[ -d "$out" ] || die "$(msg out_dir_missing "$out")"
	log "$(msg done)"
	echo "$(msg out_from_wsl "$out")"
	echo "$(msg out_from_windows "${WIN_SRC_DIR_NATIVE}\\flutter\\build\\windows\\x64\\runner\\Release\\rustdesk.exe")"
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

	log "$(msg android_sdk "$NDK_VERSION")"
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
	[ -n "$ndk_pkg" ] || die "$(msg ndk_branch_missing "$ndk_major" "$NDK_VERSION")"

	yes | "$sdkmanager" --licenses >/dev/null 2>&1 || true
	"$sdkmanager" --install "platform-tools" "platforms;android-35" "build-tools;35.0.0" "$ndk_pkg"

	log "cargo-ndk $CARGO_NDK_VERSION"
	cargo install cargo-ndk --version "$CARGO_NDK_VERSION" --locked

	# hwcodec links with ffmpeg from vcpkg under Android too: without it its
	# build.rs fails on `VCPKG_ROOT` with a terse `NotPresent`. The triplet is
	# built by the same script as on CI, not by our own copy of the vcpkg command
	install_vcpkg
	log "$(msg vcpkg_android_deps)"
	ANDROID_NDK_HOME="$(android_ndk_dir)" ANDROID_NDK_ROOT="$(android_ndk_dir)" \
		./flutter/build_android_deps.sh arm64-v8a

	log "$(msg android_deps_done)"
}

build_android() {
	apply_branding
	restore_bridge
	require_host_cc
	command -v cargo-ndk >/dev/null 2>&1 || die "$(msg no_cargo_ndk)"
	[ -d "$VCPKG_ROOT/installed/arm64-android" ] || die "$(msg no_vcpkg_android)"

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

	log "$(msg rust_core_android)"
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
	[ -x "$JDK_DIR/bin/java" ] || die "$(msg no_jdk)"
	(cd flutter && JAVA_HOME="$JDK_DIR" PATH="$JDK_DIR/bin:$PATH" \
		flutter build apk --release --target-platform android-arm64 --split-per-abi)
	git checkout -- ./flutter/android/app/build.gradle ./flutter/android/gradle.properties

	local apk="flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
	[ -f "$apk" ] || die "$(msg no_apk "$apk")"

	# A file cannot be sent to the phone from WSL, so a copy is put into the
	# Windows Downloads folder, where Explorer can see it
	local user drop
	user="$(powershell.exe -NoProfile -Command 'Write-Output $env:USERNAME' 2>/dev/null | tr -d '\r\n')"
	drop="/mnt/c/Users/$user/Downloads"
	if [ -n "$user" ] && [ -d "$drop" ]; then
		cp "$apk" "$drop/armilen-remote-arm64.apk"
		log "$(msg done_at "$drop/armilen-remote-arm64.apk")"
		echo "$(msg apk_in_downloads)"
	else
		log "$(msg done_at "$REPO_ROOT/$apk")"
	fi
}

# ── Linux ────────────────────────────────────────────────────────────────────

linux_deps() {
	require_sudo
	log "$(msg system_packages)"
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

	log "$(msg linux_deps_done)"
}

build_linux() {
	apply_branding
	restore_bridge

	[ -x "$VCPKG_ROOT/vcpkg" ] || die "$(msg vcpkg_not_built)"
	log "$(msg vcpkg_linux_deps)"
	"$VCPKG_ROOT/vcpkg" install --triplet x64-linux --x-install-root="$VCPKG_ROOT/installed"

	log "$(msg rust_core)"
	cargo +"$RUST_VERSION" build --lib --features hwcodec,flutter,unix-file-copy-paste --release

	if [ "$FULL" -eq 0 ]; then
		log "$(msg core_built)"
		echo "$(msg full_app_hint)"
		return
	fi

	log "$(msg flutter_app)"
	(cd flutter && flutter build linux --release)
	log "$(msg done_at "$REPO_ROOT/flutter/build/linux/x64/release/bundle")"
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
