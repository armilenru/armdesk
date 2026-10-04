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
#>
[CmdletBinding()]
param(
	[switch]$Deps,
	[string]$SourceDir = "C:\dev\armilen-remote",
	[string]$FlutterVersion = "3.24.5",
	[string]$RustVersion = "1.75",
	[string]$VcpkgCommitId = "120deac3062162151622ca4860575a33844ba10b",
	[string]$LlvmVersion = "18.1.8"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$CacheDir = Join-Path $env:LOCALAPPDATA "armilen-remote-build"
$VcpkgRoot = Join-Path $CacheDir "vcpkg"
$FlutterRoot = Join-Path $CacheDir "flutter"
$LlvmRoot = Join-Path $CacheDir "llvm-$LlvmVersion"
$VcpkgTriplet = "x64-windows-static"

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Green }
function Die { param([string]$Text) Write-Host "`nОшибка: $Text" -ForegroundColor Red; exit 1 }

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
		Write-Step "LLVM $LlvmVersion на месте"
		return
	}
	Write-Step "LLVM $LlvmVersion (портативная, без прав администратора)"
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
		Die "LLVM $LlvmVersion не распаковалась в $LlvmRoot"
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

	Write-Host @"

Ошибка: выключен режим разработчика Windows.

Flutter создаёт симлинки на плагины, и без этого режима обычному пользователю
это запрещено. Включается один раз, в PowerShell от администратора:

    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1

либо мышью: параметры → система → для разработчиков → режим разработчика.
"@ -ForegroundColor Red
	exit 1
}

function Install-Deps {
	Write-Step "Инструменты через winget"

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
			Write-Host "    winget вернул $LASTEXITCODE, проверьте пакет вручную" -ForegroundColor Yellow
		}
	}

	Install-Llvm

	# Build Tools are installed separately: without the VCTools workload Flutter
	# has neither MSBuild nor a compiler, and `flutter build windows` fails at
	# configuration
	Write-Step "Visual Studio 2022 Build Tools, рабочая нагрузка C++ (несколько ГБ, долго)"
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

	Write-Step "Готово. Дальше сборка запускается из WSL"
}

function Invoke-Build {
	if (-not (Test-Path $SourceDir)) { Die "нет каталога с исходниками: $SourceDir. Сначала синхронизация из WSL" }
	Initialize-Paths

	# LLVM is installed from an archive into the user's cache and needs no
	# rights, so the build fetches it itself instead of sending the user off to a
	# separate -Deps run
	Install-Llvm
	Initialize-Paths
	Assert-DeveloperMode

	foreach ($tool in @("git", "python", "cargo", "flutter")) {
		if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
			Die "$tool не найден в PATH. Запустите с -Deps от администратора"
		}
	}

	$env:VCPKG_ROOT = $VcpkgRoot
	Set-Location $SourceDir

	Write-Step "Зависимости vcpkg ($VcpkgTriplet)"
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
	if ($LASTEXITCODE -ne 0) { Die "vcpkg не собрал зависимости" }

	# The same line as in the build-for-windows-flutter job. --skip-portable-pack
	# leaves an unpacked directory instead of a self-extracting executable: that
	# is what checking an edit needs, and packing is extra minutes
	# Paths to Dart packages are tied to the machine: package_config.json keeps
	# them absolute. The sync from WSL does not bring them (rsync excludes them),
	# so they are created here. This also removes what earlier runs may have left.
	Write-Step "Зависимости Dart (pub get)"
	foreach ($stale in @("flutter\.dart_tool", "flutter\windows\flutter\ephemeral")) {
		Remove-Item -Recurse -Force (Join-Path $SourceDir $stale) -ErrorAction SilentlyContinue
	}
	Push-Location (Join-Path $SourceDir "flutter")
	flutter pub get
	$pubOk = $LASTEXITCODE -eq 0
	Pop-Location
	if (-not $pubOk) { Die "flutter pub get не отработал" }

	Write-Step "Сборка (build.py --portable --flutter --hwcodec --vram)"
	python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
	if ($LASTEXITCODE -ne 0) { Die "build.py завершился с ошибкой" }

	$out = Join-Path $SourceDir "flutter\build\windows\x64\runner\Release"
	if (-not (Test-Path $out)) { Die "сборка прошла, но каталога $out нет" }

	Write-Step "Готово"
	Write-Host "  Каталог:  $out"
	Write-Host "  Запустить: $out\rustdesk.exe"
}

if ($Deps) { Install-Deps } else { Invoke-Build }
