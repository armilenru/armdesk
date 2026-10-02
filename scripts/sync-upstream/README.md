# Upstream sync (ArmDesk fork)

Watches `rustdesk/rustdesk` for new **stable** release tags (plain semver, e.g.
`1.4.8`; nightly/pre-release tags are ignored) and, on a new one, merges it onto
our branding on a throwaway branch, opens a PR against `master` and triggers the
Flutter build workflow on that branch.

It does **not** auto-merge to `master` or deploy: a human reviews the PR and a
green build first (this is a remote-access client). Submodule branding
(`config.rs` `APP_NAME`) is reapplied by the `apply-branding` CI action, so it
survives every merge.

## What it does per run

1. `git fetch upstream --tags`, find the highest stable tag.
2. First run records a baseline and exits (no surprise merge).
3. New tag → branch `sync/upstream-<tag>`, `git merge` the tag onto our base.
   - Clean → push branch, `gh pr create`, `gh workflow run flutter-build.yml --ref <branch>`.
   - Conflict → abort, keep base untouched, alert with the conflicting files.
4. State is kept in `.git/upstream-sync-state.json` (per clone, untracked).

## Install (systemd timer, on the always-on host)

```sh
# 1. Clone the fork where the service expects it (REPO_DIR in the unit):
sudo git clone https://github.com/profax/rustdesk.git /opt/rustdesk-fork
sudo chown -R rustdesk:rustdesk /opt/rustdesk-fork

# 2. Auth: fine-grained PAT with contents:write + workflows on profax/rustdesk.
sudo install -d -m 750 /etc/armilen
sudo tee /etc/armilen/rustdesk-sync.env >/dev/null <<'EOF'
GH_TOKEN=github_pat_xxx
EOF
# Telegram alerts use the ops bot from /etc/armilen/ops-telegram.env
# (TG_ADMIN_BOT_TOKEN, TG_ADMIN_CHAT_ID[_SECONDARY]). The armilen-site deploy
# rewrites it from its .env on every run; do not copy the token here.
sudo chmod 640 /etc/armilen/rustdesk-sync.env
sudo chown root:rustdesk /etc/armilen/rustdesk-sync.env

# 3. gh reads GH_TOKEN from the env automatically. Wire gh in as git's
#    credential helper once, as the service user, so `git push` authenticates:
sudo -u rustdesk env GH_TOKEN=… gh auth setup-git
sudo -u rustdesk env GH_TOKEN=… gh auth status

# 4. Install units:
sudo cp scripts/sync-upstream/systemd/*.service /etc/systemd/system/
sudo cp scripts/sync-upstream/systemd/*.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rustdesk-sync-upstream.timer
```

Check: `systemctl list-timers rustdesk-sync-upstream.timer`,
`journalctl -u rustdesk-sync-upstream.service`.

## Manual run / testing

```sh
# Dry-ish first run just records the baseline:
REPO_DIR=/opt/rustdesk-fork node scripts/sync-upstream/sync-upstream.mjs
# Force processing the latest stable tag even if already recorded:
REPO_DIR=/opt/rustdesk-fork node scripts/sync-upstream/sync-upstream.mjs --force
# Skip the build dispatch while testing:
TRIGGER_BUILD=false … node scripts/sync-upstream/sync-upstream.mjs --force
```

## Config (env)

| Var | Default | Meaning |
|-----|---------|---------|
| `REPO_DIR` | cwd | fork clone to operate on |
| `UPSTREAM_REMOTE` | `upstream` | upstream remote name (auto-added if missing) |
| `FORK_REMOTE` | `origin` | our fork remote |
| `BASE_BRANCH` | `master` | branch our branding lives on |
| `GH_WORKFLOW` | `flutter-build.yml` | workflow dispatched on the sync branch |
| `TRIGGER_BUILD` | `true` | set `false` to skip the build dispatch |
| `TG_ADMIN_BOT_TOKEN`,`TG_ADMIN_CHAT_ID`,`HTTPS_PROXY` | – | Telegram alerts, from `/etc/armilen/ops-telegram.env` |
