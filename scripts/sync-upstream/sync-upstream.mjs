// Upstream sync for the ArmDesk fork.
//
// Watches rustdesk/rustdesk for new *stable* release tags (plain semver, e.g.
// 1.4.8 — nightly/pre-release tags are ignored) and, when one appears, merges
// it onto our branding commits on a throwaway branch as ArmDesk <tag>-1 and
// opens a PR against our base branch. The PR starts the four-platform build by
// itself (flutter-ci.yml).
//
// A PR opened here says "auto-release: on": once its build and tests are green,
// .github/workflows/sync-release.yml merges it and starts the release build, and
// the new version reaches the site and the clients with nobody in between
// (owner's decision, 2026-10-03). A merge that needs a human never gets here:
// conflicts abort the run and alert. The submodule branding (config.rs APP_NAME)
// is reapplied by the apply-branding CI action, so nothing branding-related is
// lost in the merge.
//
// Runs from a systemd timer (see scripts/sync-upstream/systemd/). All progress
// goes to stdout/journald; failures exit non-zero so `OnFailure=` can alert.
// Telegram alerts are best-effort if TG_BOT_TOKEN/TG_CHAT_ID are set.
//
// Config (env):
//   REPO_DIR        fork clone to operate on            (default: cwd)
//   UPSTREAM_REMOTE name of the upstream remote         (default: upstream)
//   FORK_REMOTE     name of our fork remote             (default: origin)
//   BASE_BRANCH     branch our branding lives on        (default: master)
//   TG_BOT_TOKEN, TG_CHAT_ID, HTTPS_PROXY   optional Telegram alert
// CLI: --force  process the latest stable tag even if already recorded.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { VERSION_FILES, parseBuild, parseVersion, readVersion, setVersion } from "../set-version.mjs";

const UPSTREAM_URL = "https://github.com/rustdesk/rustdesk.git";
const REPO_DIR = path.resolve(process.env.REPO_DIR || process.cwd());
const UPSTREAM_REMOTE = process.env.UPSTREAM_REMOTE || "upstream";
const FORK_REMOTE = process.env.FORK_REMOTE || "origin";
const BASE_BRANCH = process.env.BASE_BRANCH || "master";
// DRY_RUN performs the merge locally to check it applies cleanly, then rolls the
// branch back without pushing, opening a PR or touching state.
const DRY_RUN = (process.env.DRY_RUN || "false") === "true";
const STATE_FILE = path.join(REPO_DIR, ".git", "upstream-sync-state.json");
const REPLACED_FILES = ["README.md"];
const FORCE = process.argv.includes("--force");

const log = (m) => console.log(`[sync-upstream] ${m}`);

// execFileSync wrapper: git/gh in REPO_DIR. `run` throws on non-zero (fatal
// steps); `tryRun` never throws (probing / cleanup).
function run(file, args, opts = {}) {
	return execFileSync(file, args, {
		cwd: REPO_DIR,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
		...opts,
	}).trim();
}
function tryRun(file, args, opts = {}) {
	try {
		return { ok: true, out: run(file, args, opts) };
	} catch (err) {
		return { ok: false, out: (err.stdout || "").toString().trim(), err: (err.stderr || err.message || "").toString().trim() };
	}
}

const git = (...args) => run("git", args);
const tryGit = (...args) => tryRun("git", args);
const hasGh = () => tryRun("gh", ["--version"]).ok;

// gh resolves "the current repo" from git remotes when --repo isn't given,
// and picks the wrong one whenever both FORK_REMOTE and UPSTREAM_REMOTE are
// configured (as ensureUpstreamRemote() below guarantees) - it favors a
// remote literally named "upstream". Every gh call here must pass --repo
// explicitly, derived from FORK_REMOTE's own URL, or PR creation silently
// targets rustdesk/rustdesk instead of our fork.
function forkRepoSlug() {
	const url = tryGit("remote", "get-url", FORK_REMOTE).out || "";
	const m = /github\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/.exec(url);
	if (!m) throw new Error(`could not derive owner/repo from ${FORK_REMOTE} url: ${url}`);
	return m[1];
}

const semver = (t) => t.split(".").map(Number);
function newerStable(a, b) {
	const [a1, a2, a3] = semver(a);
	const [b1, b2, b3] = semver(b);
	return a1 - b1 || a2 - b2 || a3 - b3;
}

function readState() {
	if (!existsSync(STATE_FILE)) return {};
	try {
		return JSON.parse(readFileSync(STATE_FILE, "utf8"));
	} catch {
		return {};
	}
}
function writeState(state) {
	writeFileSync(STATE_FILE, JSON.stringify(state, null, "\t") + "\n");
}

// Best-effort Telegram alert. Uses undici ProxyAgent only if HTTPS_PROXY is set
// and undici resolves (the VPS reaches Telegram through a local Xray proxy);
// otherwise a direct fetch. Never throws.
async function notify(text) {
	// TG_ADMIN_* come from /etc/armilen/ops-telegram.env, which the site deploy
	// rewrites from its .env on every run: a private token copy went stale once.
	const token = (process.env.TG_ADMIN_BOT_TOKEN || process.env.TG_BOT_TOKEN || "").trim();
	const chatId = (process.env.TG_ADMIN_CHAT_ID || process.env.TG_CHAT_ID || "").trim();
	if (!token || !chatId) return;
	try {
		const proxy = (process.env.HTTPS_PROXY || "").trim();
		let dispatcher;
		if (proxy) {
			try {
				const { ProxyAgent } = await import("undici");
				dispatcher = new ProxyAgent(proxy);
			} catch {
				// undici not installed: fall back to a direct connection
			}
		}
		const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
			signal: AbortSignal.timeout(15_000),
			...(dispatcher ? { dispatcher } : {}),
		});
		// A rejected token answers 401 without throwing: say so in the journal
		if (!res.ok) log(`telegram notify rejected (non-fatal): HTTP ${res.status}`);
	} catch (err) {
		log(`telegram notify failed (non-fatal): ${err.message}`);
	}
}

function ensureUpstreamRemote() {
	const remotes = git("remote").split("\n");
	if (!remotes.includes(UPSTREAM_REMOTE)) {
		git("remote", "add", UPSTREAM_REMOTE, UPSTREAM_URL);
		log(`added remote ${UPSTREAM_REMOTE} -> ${UPSTREAM_URL}`);
	}
}

// Highest plain-semver tag on upstream (ignores nightly / -rc / suffixed tags).
function latestUpstreamStable() {
	const raw = git("ls-remote", "--tags", "--refs", UPSTREAM_REMOTE);
	const tags = raw
		.split("\n")
		.map((l) => l.split("/").pop())
		.filter((t) => /^\d+\.\d+\.\d+$/.test(t));
	if (!tags.length) throw new Error("no stable semver tags found upstream");
	return tags.sort(newerStable).pop();
}

// The clone runs this file from its own working tree, and the fast-forward may
// replace it: start over on the new code instead of finishing on the old one.
function restartedOnNewerBase() {
	const before = git("rev-parse", "HEAD");
	// Keep base in step with our fork if it can fast-forward; ignore divergence.
	tryGit("merge", "--ff-only", `${FORK_REMOTE}/${BASE_BRANCH}`);
	if (git("rev-parse", "HEAD") === before || process.env.SYNC_UPSTREAM_RESTARTED) return false;
	log(`${BASE_BRANCH} moved, restarting on the updated script`);
	try {
		execFileSync(process.execPath, process.argv.slice(1), {
			stdio: "inherit",
			env: { ...process.env, SYNC_UPSTREAM_RESTARTED: "1" },
		});
	} catch (err) {
		process.exitCode = err.status || 1;
	}
	return true;
}

// The service user has no git identity, and without one git refuses a merge
// before it starts: no conflict, no unmerged files, just exit 128. Commits made
// here continue the base branch, so they carry its last author.
function adoptBaseIdentity() {
	const [name, email] = git("log", "-1", "--format=%an%n%ae").split("\n");
	for (const who of ["AUTHOR", "COMMITTER"]) {
		process.env[`GIT_${who}_NAME`] ||= name;
		process.env[`GIT_${who}_EMAIL`] ||= email;
	}
}

// Only the version files, never `commit -a`: with the submodule checked out,
// -a would stage its old commit back over the pointer the merge just moved.
function commitVersion(message) {
	git("add", "--", ...VERSION_FILES);
	if (tryGit("diff", "--cached", "--quiet").ok) return;
	git("commit", "-m", message);
}

// When the only conflicts are in files we replaced wholesale, our copy stands:
// upstream's edits to its own README have nothing to apply to.
function keptOurs() {
	const unmerged = tryGit("diff", "--name-only", "--diff-filter=U").out.split("\n").filter(Boolean);
	if (!unmerged.length || unmerged.some((file) => !REPLACED_FILES.includes(file))) return false;
	git("checkout", "--ours", "--", ...unmerged);
	git("add", "--", ...unmerged);
	return true;
}

// Our "-N" build number sits on the very lines upstream rewrites in every
// release, so a plain merge conflicts each time. Upstream's own previous
// version goes back first: the lines then equal the merge base and take the
// new version cleanly. Afterwards the tag is stamped as <tag>-1.
function mergeAsArmDesk(latest) {
	const ours = readVersion(REPO_DIR);
	const base = git("merge-base", "HEAD", latest);
	const atBase = (file) => git("show", `${base}:${file}`);
	setVersion(REPO_DIR, parseVersion(atBase("Cargo.toml")), parseBuild(atBase("flutter/pubspec.yaml")));
	commitVersion(`sync: upstream's version lines back before merging ${latest}`);

	let merge = tryGit("merge", "--no-edit", latest);
	if (!merge.ok && keptOurs()) merge = tryGit("commit", "--no-edit");
	if (!merge.ok) return { merge };

	const version = `${latest}-1`;
	setVersion(REPO_DIR, version, Math.max(ours.build, readVersion(REPO_DIR).build) + 1);
	commitVersion(`chore: version ${version}`);
	return { version };
}

async function reportConflict(latest, branch, baseSha, merge, state) {
	const files = tryGit("diff", "--name-only", "--diff-filter=U").out;
	tryGit("merge", "--abort");
	git("checkout", BASE_BRANCH);
	tryGit("branch", "-D", branch);
	// The tag and the base it failed on: the same pair is not retried and not
	// reported again, a new commit on the base branch is.
	writeState({ ...state, conflictTag: latest, conflictBase: baseSha, conflictAt: new Date().toISOString() });
	const detail = files ? `Файлы:\n${files}` : `git:\n${merge.err || merge.out}`;
	const msg = `⚠️ ArmDesk: upstream ${latest} не слился сам, нужно ручное слияние.\n${detail}`;
	log(msg);
	await notify(msg);
	process.exitCode = 1;
}

function openPr(latest, branch, version) {
	if (!hasGh()) {
		log("gh CLI not found: open a PR manually for the sync branch");
		return "";
	}
	const pr = tryRun("gh", [
		"pr", "create",
		"--repo", forkRepoSlug(),
		"--base", BASE_BRANCH,
		"--head", branch,
		"--title", `Sync upstream RustDesk ${latest} (ArmDesk ${version})`,
		"--body",
		`Automated merge of upstream tag \`${latest}\` onto the ArmDesk branding, versioned ${version}.\n\n` +
			`- Branding of submodule code (config.rs APP_NAME) is reapplied by the apply-branding CI action.\n` +
			`- Merged and released by sync-release.yml once this PR's build and tests are green. ` +
			`Delete the line below to stop that.\n\n` +
			`auto-release: on`,
	]);
	log(pr.ok ? `PR opened: ${pr.out}` : `gh pr create: ${pr.err || pr.out} (may already exist)`);
	return pr.ok ? pr.out : "";
}

async function main() {
	if (!existsSync(path.join(REPO_DIR, ".git"))) {
		throw new Error(`${REPO_DIR} is not a git repository (set REPO_DIR)`);
	}
	ensureUpstreamRemote();
	log(`fetching ${UPSTREAM_REMOTE} tags…`);
	// --no-recurse-submodules: we only need the top-level tags/refs; recursing
	// makes git try (and fail) to fetch libs/hbb_common from a ref the fork's
	// submodule remote doesn't serve, and its non-zero exit would abort us.
	git("fetch", UPSTREAM_REMOTE, "--tags", "--prune", "--force", "--no-recurse-submodules");
	tryGit("fetch", FORK_REMOTE, "--prune", "--no-recurse-submodules");

	const latest = latestUpstreamStable();
	const state = readState();
	log(`latest upstream stable: ${latest} | last recorded: ${state.lastTag ?? "(none)"}`);

	// First ever run: record a baseline, don't surprise-merge history.
	if (!state.lastTag && !FORCE) {
		writeState({ lastTag: latest, baselineAt: new Date().toISOString() });
		log(`baseline recorded at ${latest}; future newer tags will trigger a sync`);
		return;
	}
	if (state.lastTag === latest && !FORCE) {
		log("already up to date, nothing to do");
		return;
	}

	// A dirty top-level tree would make the merge ambiguous: bail early and
	// loudly. --ignore-submodules=dirty: an uncommitted edit *inside* a
	// submodule (e.g. a local APP_NAME tweak) is irrelevant here — CI reapplies
	// branding — but a changed submodule *pointer* still shows and still blocks.
	if (git("status", "--porcelain", "--ignore-submodules=dirty")) {
		throw new Error("working tree is dirty; refusing to sync");
	}

	git("checkout", BASE_BRANCH);
	if (restartedOnNewerBase()) return;
	const baseSha = git("rev-parse", "HEAD");

	if (tryGit("merge-base", "--is-ancestor", latest, "HEAD").ok) {
		writeState({ lastTag: latest, syncedAt: new Date().toISOString() });
		log(`${latest} is already in ${BASE_BRANCH} (merged by hand), recorded`);
		return;
	}
	if (state.conflictTag === latest && state.conflictBase === baseSha && !FORCE) {
		log(`${latest} already failed to merge onto ${baseSha.slice(0, 9)}, waiting for a manual merge`);
		return;
	}

	const branch = `sync/upstream-${latest}`;
	log(`preparing ${branch} from ${BASE_BRANCH}`);
	if (tryGit("rev-parse", "--verify", branch).ok) git("branch", "-D", branch);
	git("checkout", "-b", branch);
	adoptBaseIdentity();

	const { version, merge } = mergeAsArmDesk(latest);
	if (merge) {
		await reportConflict(latest, branch, baseSha, merge, state);
		return;
	}

	if (DRY_RUN) {
		log(`DRY_RUN: ${latest} merges cleanly onto ${BASE_BRANCH} as ${version}; rolling back ${branch}`);
		git("checkout", BASE_BRANCH);
		tryGit("branch", "-D", branch);
		return;
	}

	log("clean merge; pushing sync branch");
	// --force-with-lease is safe: the branch is disposable and namespaced per tag.
	git("push", "--force-with-lease", FORK_REMOTE, branch);
	const prUrl = openPr(latest, branch, version);

	git("checkout", BASE_BRANCH);
	writeState({ lastTag: latest, syncedAt: new Date().toISOString(), branch });
	const done = `✅ ArmDesk: upstream ${latest} слит в ветку ${branch} как ${version}, сборка PR идёт. Пройдёт на всех платформах, выпуск начнётся сам.\n${prUrl}`;
	log(done);
	await notify(done);
}

main().catch(async (err) => {
	log(`FATAL: ${err.message}`);
	await notify(`❌ ArmDesk upstream-sync упал: ${err.message}`);
	process.exit(1);
});
