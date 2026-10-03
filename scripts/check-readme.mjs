#!/usr/bin/env node
// README.md and README.ru.md tell one story in two languages, and both
// describe what this fork does. Nothing else ties them together, so they
// drift: one language is edited and the other forgotten, or the code stops
// doing what the README promises. This fails the build when that happens.
//
// Run: node scripts/check-readme.mjs

import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const readmes = { "README.md": read("README.md"), "README.ru.md": read("README.ru.md") };
const [en, ru] = Object.values(readmes);
const problems = [];

// Each version opens with a link to the other one.
if (!en.includes("](README.ru.md)")) problems.push("README.md does not link to README.ru.md");
if (!ru.includes("](README.md)")) problems.push("README.ru.md does not link to README.md");

// Same shape in both: a section, a list item or a link added to one language
// only is the usual way the two fall apart.
function shape(text) {
	const links = [...text.matchAll(/\]\(([^)\s]+)\)|(?<![(\w/])(https?:\/\/[^\s)]+)/g)]
		.map((m) => (m[1] ?? m[2]).replace(/[.,;:]+$/, ""))
		.filter((link) => !/^README(\.ru)?\.md$/.test(link));
	return {
		sections: (text.match(/^## /gm) ?? []).length,
		"list items": (text.match(/^- /gm) ?? []).length,
		links: [...new Set(links)].sort().join("\n"),
	};
}
const [enShape, ruShape] = [shape(en), shape(ru)];
for (const key of Object.keys(enShape)) {
	if (enShape[key] === ruShape[key]) continue;
	problems.push(
		`README.md and README.ru.md differ in ${key}:\n` +
			`  README.md:    ${String(enShape[key]).replaceAll("\n", " ")}\n` +
			`  README.ru.md: ${String(ruShape[key]).replaceAll("\n", " ")}`,
	);
}

// A link to this repository has to be relative (../../releases): an absolute
// one goes stale the day the repository is renamed or moved.
for (const [name, text] of Object.entries(readmes)) {
	for (const [, repo] of text.matchAll(/github\.com\/([\w.-]+\/[\w.-]+)/g)) {
		if (repo === "rustdesk/rustdesk") continue;
		problems.push(`${name} links to github.com/${repo}; link to this repository relatively, e.g. ../../releases`);
	}
}

// What the README promises, and the line of code that makes it true. When the
// code line goes away, either the fork changed (rewrite both READMEs) or the
// code moved (point the claim at its new place).
const BRANDING = ".github/actions/apply-branding/action.yml";
const claims = [
	{
		says: "its own rendezvous and relay servers",
		file: BRANDING,
		code: /sed .*RENDEZVOUS_SERVERS.*armilen\.ru/,
		en: /our rendezvous and relay servers/,
		ru: /к нашим серверам/,
	},
	{
		says: "its own server key",
		file: BRANDING,
		code: /sed .*RS_PUB_KEY/,
		en: /our server key/,
		ru: /нашим ключом\s+сервера/,
	},
	{
		says: "version check on www.armilen.ru",
		file: BRANDING,
		code: /sed .*https:\/\/www\.armilen\.ru\/api\/version-check/,
		en: /checks for new versions at www\.armilen\.ru/,
		ru: /проверяет на www\.armilen\.ru/,
	},
	{
		says: "auto-update on by default",
		file: "src/core_main.rs",
		code: /fn default_allow_auto_update\(\)/,
		en: /updates itself by default/,
		ru: /по умолчанию обновляется сам/,
	},
	{
		says: "account sign-in and the address book on its own API server",
		file: "src/common.rs",
		code: /"https:\/\/desk\.armilen\.ru"/,
		en: /our own API server/,
		ru: /наш сервер API/,
	},
	{
		says: "the privacy policy link",
		file: "flutter/lib/consts.dart",
		code: /kArmilenPrivacyUrl = "\$kArmilenSiteUrl\/legal\/armdesk-privacy"/,
		en: /https:\/\/www\.armilen\.ru\/legal\/armdesk-privacy/,
		ru: /https:\/\/www\.armilen\.ru\/legal\/armdesk-privacy/,
	},
	{
		says: "the download page",
		file: "flutter/lib/consts.dart",
		code: /kArmilenDownloadUrl = "\$kArmilenSiteUrl\/support"/,
		en: /https:\/\/www\.armilen\.ru\/support/,
		ru: /https:\/\/www\.armilen\.ru\/support/,
	},
	{
		says: "the site address the links are built from",
		file: "flutter/lib/consts.dart",
		code: /kArmilenSiteUrl = "https:\/\/www\.armilen\.ru"/,
		en: /https:\/\/www\.armilen\.ru/,
		ru: /https:\/\/www\.armilen\.ru/,
	},
];
for (const claim of claims) {
	if (!claim.code.test(read(claim.file))) {
		problems.push(
			`The READMEs promise ${claim.says}, but ${claim.file} no longer has ${claim.code}.\n` +
				"  If the fork changed, rewrite that line in README.md and README.ru.md;\n" +
				"  if the code only moved, update the claim in scripts/check-readme.mjs.",
		);
	}
	for (const [name, text, pattern] of [["README.md", en, claim.en], ["README.ru.md", ru, claim.ru]]) {
		if (pattern.test(text)) continue;
		problems.push(
			`${name} no longer says ${pattern} (${claim.says}).\n` +
				"  Reword both READMEs together, then update the claim in scripts/check-readme.mjs.",
		);
	}
}

if (problems.length) {
	console.error(`README check failed:\n\n- ${problems.join("\n\n- ")}\n`);
	process.exit(1);
}
console.log(`README.md and README.ru.md agree with each other and with the code (${claims.length} claims).`);
