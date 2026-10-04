<#
.SYNOPSIS
    Builds ArmDesk for Windows on Windows itself.

.DESCRIPTION
    Not run by hand but from WSL, through scripts/build-local.sh --target windows.
    It is a separate file because a Windows client cannot be built from Linux at
    all: Flutter builds the Windows desktop through MSBuild and MSVC, and that
    pair has no cross-compilation. Working in WSL and building on the host is the
    only way that works, not a compromise.

    The sources arrive here with the branding already applied (the WSL side
    applies it with the same composite action as CI), so this file only builds.
    Repeating the branding logic in PowerShell would create a second source of
    truth and drift from CI at the first edit.

.PARAMETER Deps
    One-time installation of the tools through winget. Needs administrator rights.

.PARAMETER SourceDir
    Directory with the sources on the Windows disk. Defaults to C:\dev\armilen-remote.

.PARAMETER Lang
    Language of the output, ru or en. The WSL side passes its own choice so that
    both halves of one build speak the same language. Without it the language of
    Windows decides.
#>
[CmdletBinding()]
param(
	[switch]$Deps,
	[string]$SourceDir = "C:\dev\armilen-remote",
	[string]$FlutterVersion = "3.24.5",
	[string]$RustVersion = "1.75",
	[string]$VcpkgCommitId = "120deac3062162151622ca4860575a33844ba10b",
	[string]$LlvmVersion = "18.1.8",
	[string]$Lang = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$CacheDir = Join-Path $env:LOCALAPPDATA "armilen-remote-build"
$VcpkgRoot = Join-Path $CacheDir "vcpkg"
$FlutterRoot = Join-Path $CacheDir "flutter"
$LlvmRoot = Join-Path $CacheDir "llvm-$LlvmVersion"
$VcpkgTriplet = "x64-windows-static"

# English by default, because the repository is public; Russian on a Russian
# system. Each value is a -f format. Both tables carry the same keys with the
# same placeholders: scripts/check-build-messages.mjs.
if ($Lang -notin @("ru", "en")) {
	$Lang = if ((Get-UICulture).TwoLetterISOLanguageName -eq "ru") { "ru" } else { "en" }
}
$Messages = @{
	en = @{
		error_label = 'Error:'
		llvm_present = 'LLVM {0} is in place'
		llvm_portable = 'LLVM {0} (portable, no administrator rights needed)'
		llvm_unpack_failed = 'LLVM {0} was not unpacked into {1}'
		developer_mode_off = @'

Error: Windows developer mode is off.

Flutter creates symlinks to plugins, and without this mode an ordinary user is
not allowed to. It is turned on once, in PowerShell as administrator:

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1

or with the mouse: Settings → System → For developers → Developer Mode.
'@
		winget_tools = 'Tools through winget'
		winget_code = '    winget returned {0}, check the package by hand'
		build_tools = 'Visual Studio 2022 Build Tools, the C++ workload (several GB, slow)'
		deps_done = 'Done. From here the build is started from WSL'
		no_source_dir = 'the source directory {0} does not exist. Sync from WSL first'
		tool_missing = '{0} is not in PATH. Run with -Deps as administrator'
		vcpkg_deps = 'vcpkg dependencies ({0})'
		vcpkg_failed = 'vcpkg failed to build the dependencies'
		dart_deps = 'Dart dependencies (pub get)'
		pub_get_failed = 'flutter pub get failed'
		building = 'Build (build.py --portable --flutter --hwcodec --vram)'
		build_py_failed = 'build.py failed'
		out_dir_missing = 'the build finished, but {0} does not exist'
		done = 'Done'
		out_dir = '  Directory: {0}'
		out_run = '  Run:       {0}'
	}
	ru = @{
		error_label = 'Ошибка:'
		llvm_present = 'LLVM {0} на месте'
		llvm_portable = 'LLVM {0} (портативная, без прав администратора)'
		llvm_unpack_failed = 'LLVM {0} не распаковалась в {1}'
		developer_mode_off = @'

Ошибка: выключен режим разработчика Windows.

Flutter создаёт симлинки на плагины, и без этого режима обычному пользователю
это запрещено. Включается один раз, в PowerShell от администратора:

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1

либо мышью: параметры → система → для разработчиков → режим разработчика.
'@
		winget_tools = 'Инструменты через winget'
		winget_code = '    winget вернул {0}, проверьте пакет вручную'
		build_tools = 'Visual Studio 2022 Build Tools, рабочая нагрузка C++ (несколько ГБ, долго)'
		deps_done = 'Готово. Дальше сборка запускается из WSL'
		no_source_dir = 'нет каталога с исходниками: {0}. Сначала синхронизация из WSL'
		tool_missing = '{0} не найден в PATH. Запустите с -Deps от администратора'
		vcpkg_deps = 'Зависимости vcpkg ({0})'
		vcpkg_failed = 'vcpkg не собрал зависимости'
		dart_deps = 'Зависимости Dart (pub get)'
		pub_get_failed = 'flutter pub get не отработал'
		building = 'Сборка (build.py --portable --flutter --hwcodec --vram)'
		build_py_failed = 'build.py завершился с ошибкой'
		out_dir_missing = 'сборка прошла, но каталога {0} нет'
		done = 'Готово'
		out_dir = '  Каталог:  {0}'
		out_run = '  Запустить: {0}'
	}
}

function Msg {
	param([string]$Key)
	if (-not $Messages[$Lang].ContainsKey($Key)) { throw "no message '$Key'" }
	$Messages[$Lang][$Key] -f $args
}

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Green }
function Die { param([string]$Text) Write-Host "`n$(Msg error_label) $Text" -ForegroundColor Red; exit 1 }

# The tools go into the PATH of the current session: winget changes the
# machine variable, but a process that is already running does not reread it.
function Add-ToPath {
	param([string]$Dir)
	if ((Test-Path $Dir) -and ($env:PATH -notlike "*$Dir*")) { $env:PATH = "$Dir;$env:PATH" }
}

function Initialize-Paths {
	Add-ToPath (Join-Path $FlutterRoot "bin")
	Add-ToPath (Join-Path $env:USERPROFILE ".cargo\bin")
	Add-ToPath $VcpkgRoot
	foreach ($p in @(
			"$env:LOCALAPPDATA\Programs\Python\Python312",
			"$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
			"$env:ProgramFiles\Git\cmd",
			# winget installs NASM into the user area, not into Program Files: both
			# are listed, Add-ToPath silently skips the one that does not exist
			"$env:ProgramFiles\NASM",
			"$env:LOCALAPPDATA\bin\NASM"
		)) { Add-ToPath $p }

	# The pinned LLVM goes ahead of the system one, and LIBCLANG_PATH removes the
	# guessing: bindgen looks for libclang itself and takes the first one it finds
	if (Test-Path (Join-Path $LlvmRoot "bin")) {
		Add-ToPath (Join-Path $LlvmRoot "bin")
		$env:LIBCLANG_PATH = Join-Path $LlvmRoot "bin"
	}
}

# bindgen reads the headers with libclang, not with the MSVC compiler, and the
# result depends on its version. Checked on this project: with libclang 22.1.8
# from winget exactly two structures out of 41, `aom_codec_enc_cfg` and
# `aom_codec_dec_cfg`, come out as opaque stubs `{ _address: u8 }`, and the
# build breaks in Rust on "no field named threads". Both are forward-declared
# through a pointer in aom_codec.h and defined later, in aom_decoder.h: the
# preprocessor sees the body, but the parser of that version does not attach
# it to the forward declaration. With libclang 18.1.8 the same headers are
# parsed correctly and the build passes.
#
# CI pins LLVM_VERSION 15.0.6, but it has no portable build for Windows, only
# an NSIS installer, which needs administrator rights and refuses to install
# next to an LLVM that is already there. 18.1.8 is unpacked from an archive
# into the user's cache, so the whole windows target builds without UAC.
function Install-Llvm {
	if (Test-Path (Join-Path $LlvmRoot "bin\libclang.dll")) {
		Write-Step (Msg llvm_present $LlvmVersion)
		return
	}
	Write-Step (Msg llvm_portable $LlvmVersion)
	$archive = Join-Path $CacheDir "llvm-$LlvmVersion.tar.xz"
	$url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/clang+llvm-$LlvmVersion-x86_64-pc-windows-msvc.tar.xz"
	New-Item -ItemType Directory -Force -Path $CacheDir, $LlvmRoot | Out-Null
	if (-not (Test-Path $archive)) {
		Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
	}
	# tar on Windows 10+ is bsdtar, it unpacks .tar.xz by itself
	tar -xf $archive -C $LlvmRoot --strip-components=1
	Remove-Item $archive -ErrorAction SilentlyContinue
	if (-not (Test-Path (Join-Path $LlvmRoot "bin\libclang.dll"))) {
		Die (Msg llvm_unpack_failed $LlvmVersion $LlvmRoot)
	}
}

# Flutter creates symlinks to plugins, and Windows allows an ordinary user to
# do that only in developer mode. Without it `flutter pub get` fails in the
# middle of the build, and the message is lost among hundreds of MSBuild
# lines. Check in advance and say exactly what has to be done.
function Assert-DeveloperMode {
	$key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
	$on = (Get-ItemProperty -Path $key -Name AllowDevelopmentWithoutDevLicense `
			-ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
	if ($on) { return }

	Write-Host (Msg developer_mode_off) -ForegroundColor Red
	exit 1
}

function Install-Deps {
	Write-Step (Msg winget_tools)

	$id = @{ Silent = "--silent"; Accept = "--accept-package-agreements", "--accept-source-agreements" }
	# LLVM is deliberately not here: bindgen is tied to the libclang version, and
	# a fresh one from winget breaks header parsing. The pinned one is installed,
	# see Install-Llvm
	foreach ($pkg in @(
			"Git.Git",
			"Python.Python.3.12",
			"Rustlang.Rustup",
			"Kitware.CMake",
			"NASM.NASM"
		)) {
		Write-Host "  · $pkg"
		winget install --id $pkg --exact --disable-interactivity $id.Silent @($id.Accept) 2>&1 | Out-Null
		if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
			# -1978335189 = already installed, not an error
			Write-Host (Msg winget_code $LASTEXITCODE) -ForegroundColor Yellow
		}
	}

	Install-Llvm

	# Build Tools are installed separately: without the VCTools workload Flutter
	# has neither MSBuild nor a compiler, and `flutter build windows` fails at
	# configuration
	Write-Step (Msg build_tools)
	winget install --id Microsoft.VisualStudio.2022.BuildTools --exact `
		--disable-interactivity --silent `
		--accept-package-agreements --accept-source-agreements `
		--override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended" 2>&1 | Out-Null

	Initialize-Paths

	Write-Step "Rust $RustVersion (MSVC)"
	rustup toolchain install "$RustVersion-x86_64-pc-windows-msvc" --component rustfmt
	rustup default "$RustVersion-x86_64-pc-windows-msvc"

	Write-Step "Flutter $FlutterVersion"
	if (-not (Test-Path $FlutterRoot)) {
		New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
		git clone https://github.com/flutter/flutter.git --depth 1 -b $FlutterVersion $FlutterRoot
	}
	Initialize-Paths
	flutter config --enable-windows-desktop
	flutter precache --windows

	Write-Step "vcpkg $($VcpkgCommitId.Substring(0,12))"
	if (-not (Test-Path (Join-Path $VcpkgRoot ".git"))) {
		git clone https://github.com/microsoft/vcpkg $VcpkgRoot
	}
	git -C $VcpkgRoot fetch --depth 1 origin $VcpkgCommitId
	git -C $VcpkgRoot checkout -q $VcpkgCommitId
	if (-not (Test-Path (Join-Path $VcpkgRoot "vcpkg.exe"))) {
		& (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
	}

	Write-Step (Msg deps_done)
}

function Invoke-Build {
	if (-not (Test-Path $SourceDir)) { Die (Msg no_source_dir $SourceDir) }
	Initialize-Paths

	# LLVM is installed from an archive into the user's cache and needs no
	# rights, so the build fetches it itself instead of sending the user off to a
	# separate -Deps run
	Install-Llvm
	Initialize-Paths
	Assert-DeveloperMode

	foreach ($tool in @("git", "python", "cargo", "flutter")) {
		if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
			Die (Msg tool_missing $tool)
		}
	}

	$env:VCPKG_ROOT = $VcpkgRoot
	Set-Location $SourceDir

	Write-Step (Msg vcpkg_deps $VcpkgTriplet)
	# ffmpeg is declared in vcpkg.json as host: true, so it is installed into the
	# host triplet. On Windows that is x64-windows by default, while hwcodec looks
	# for the headers in x64-windows-static and fails on libavutil/pixfmt.h. CI
	# makes the host triplet equal to the target one with this same variable, and
	# so do we.
	$env:VCPKG_DEFAULT_HOST_TRIPLET = $VcpkgTriplet
	# The argument is quoted as a whole: the PowerShell parser does not accept
	# `--flag="$var\path"` with a quote in the middle of a token
	$installRoot = Join-Path $VcpkgRoot "installed"
	& (Join-Path $VcpkgRoot "vcpkg.exe") install --triplet $VcpkgTriplet "--x-install-root=$installRoot"
	if ($LASTEXITCODE -ne 0) { Die (Msg vcpkg_failed) }

	# The same line as in the build-for-windows-flutter job. --skip-portable-pack
	# leaves an unpacked directory instead of a self-extracting executable: that
	# is what checking an edit needs, and packing is extra minutes
	# Paths to Dart packages are tied to the machine: package_config.json keeps
	# them absolute. The sync from WSL does not bring them (rsync excludes them),
	# so they are created here. This also removes what earlier runs may have left.
	Write-Step (Msg dart_deps)
	foreach ($stale in @("flutter\.dart_tool", "flutter\windows\flutter\ephemeral")) {
		Remove-Item -Recurse -Force (Join-Path $SourceDir $stale) -ErrorAction SilentlyContinue
	}
	Push-Location (Join-Path $SourceDir "flutter")
	flutter pub get
	$pubOk = $LASTEXITCODE -eq 0
	Pop-Location
	if (-not $pubOk) { Die (Msg pub_get_failed) }

	Write-Step (Msg building)
	python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
	if ($LASTEXITCODE -ne 0) { Die (Msg build_py_failed) }

	$out = Join-Path $SourceDir "flutter\build\windows\x64\runner\Release"
	if (-not (Test-Path $out)) { Die (Msg out_dir_missing $out) }

	Write-Step (Msg done)
	Write-Host (Msg out_dir $out)
	Write-Host (Msg out_run "$out\rustdesk.exe")
}

if ($Deps) { Install-Deps } else { Invoke-Build }
