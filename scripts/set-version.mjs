// Every file that carries the client version, rewritten in one go.
//
//   node scripts/set-version.mjs 1.5.0-2        build number in pubspec goes up by one
//   node scripts/set-version.mjs 1.5.0-2 71     ... or is set explicitly
//
// ArmDesk versions are "<RustDesk version>-<our build>". Upstream's res/bump.sh
// does the same job with one word-boundary sed over whole directories; that
// misses Cargo.lock (CI builds with --locked) and the pubspec build number, and
// rewrites any unrelated "1.5.0" it meets, so each line is matched here by its
// own pattern and a pattern that stops matching is an error, not a silent skip.
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function parseVersion(cargoToml) {
	const m = /^version = "([^"]+)"$/m.exec(cargoToml);
	if (!m) throw new Error("no version line in Cargo.toml");
	return m[1];
}

// The number after "+" becomes the Android versionCode: an APK installs over an
// older one only if it grew.
export function parseBuild(pubspec) {
	const m = /^version: \S+\+(\d+)$/m.exec(pubspec);
	if (!m) throw new Error("no version line in flutter/pubspec.yaml");
	return Number(m[1]);
}

export function readVersion(dir) {
	const read = (f) => readFileSync(path.join(dir, f), "utf8");
	return { version: parseVersion(read("Cargo.toml")), build: parseBuild(read("flutter/pubspec.yaml")) };
}

function targets(cur, next, build) {
	const q = esc(cur);
	const cargo = [new RegExp(`^version = "${q}"$`, "m"), `version = "${next}"`];
	const lock = (name) => [new RegExp(`(name = "${name}"\\nversion = ")${q}"`), `$1${next}"`];
	const appimage = [new RegExp(`^(\\s+version: )${q}$`, "m"), `$1${next}`];
	const workflow = [new RegExp(`^(\\s+VERSION: ")${q}"`, "m"), `$1${next}"`];
	// pubspec takes no "-N": iOS turns 1.1.9-1 into 1.1.91
	const pubspec = [/^version: \S+$/m, `version: ${next.split("-")[0]}+${build}`];
	return [
		["Cargo.toml", ...cargo],
		["libs/portable/Cargo.toml", ...cargo],
		["Cargo.lock", ...lock("rustdesk")],
		["Cargo.lock", ...lock("rustdesk-portable-packer")],
		["appimage/AppImageBuilder-x86_64.yml", ...appimage],
		["appimage/AppImageBuilder-aarch64.yml", ...appimage],
		[".github/workflows/flutter-build.yml", ...workflow],
		[".github/workflows/playground.yml", ...workflow],
		["flutter/pubspec.yaml", ...pubspec],
	];
}

export const VERSION_FILES = [...new Set(targets("", "", 0).map(([file]) => file))];

export function setVersion(dir, next, build) {
	const cur = readVersion(dir).version;
	for (const [file, pattern, replacement] of targets(cur, next, build)) {
		const full = path.join(dir, file);
		const text = readFileSync(full, "utf8");
		if (!pattern.test(text)) throw new Error(`${file}: version ${cur} not found where expected`);
		writeFileSync(full, text.replace(pattern, replacement));
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const [next, build] = process.argv.slice(2);
	if (!/^\d+\.\d+\.\d+(-\d+)?$/.test(next || "")) {
		console.error("usage: node scripts/set-version.mjs <version> [pubspec build number]");
		process.exit(2);
	}
	const dir = process.cwd();
	const cur = readVersion(dir);
	const nextBuild = build ? Number(build) : cur.build + 1;
	setVersion(dir, next, nextBuild);
	console.log(`${cur.version}+${cur.build} -> ${next}+${nextBuild}`);
}
