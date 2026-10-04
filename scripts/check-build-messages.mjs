#!/usr/bin/env node
// The local build scripts print in English and in Russian, from two tables
// each. Nothing else ties the tables together, so they drift: a message is
// added or reworded in one language and forgotten in the other, and the reader
// of that language gets a crash on a missing key or a value that never shows.
// This fails the build when that happens.
//
// Run: node scripts/check-build-messages.mjs

import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const problems = [];

// Splits a table body into { key: raw value } by the lines that open an entry.
function entries(body, opener) {
	const parts = body.split(opener);
	const table = {};
	for (let i = 1; i < parts.length; i += 2) table[parts[i]] = parts[i + 1];
	return table;
}

const scripts = [
	{
		path: "scripts/build-local.sh",
		table: (text, lang) =>
			text.match(new RegExp(`^declare -A MSG_${lang.toUpperCase()}=\\(\\n([\\s\\S]*?)^\\)$`, "m"))?.[1],
		opener: /^\t\[(\w+)\]=/m,
		placeholders: (value) => String((value.match(/%s/g) ?? []).length),
		used: /\bmsg (\w+)/g,
	},
	{
		path: "scripts/build-windows-local.ps1",
		table: (text, lang) => text.match(new RegExp(`^\\t${lang} = @\\{\\n([\\s\\S]*?)^\\t\\}$`, "m"))?.[1],
		opener: /^\t\t(\w+) = /m,
		placeholders: (value) => [...new Set(value.match(/\{\d+\}/g) ?? [])].sort().join(" "),
		used: /\bMsg (\w+)/g,
	},
];

let total = 0;
for (const script of scripts) {
	const text = read(script.path);
	const bodies = { en: script.table(text, "en"), ru: script.table(text, "ru") };
	if (!bodies.en || !bodies.ru) {
		problems.push(`${script.path}: a message table was not found`);
		continue;
	}
	const en = entries(bodies.en, script.opener);
	const ru = entries(bodies.ru, script.opener);

	for (const key of Object.keys(en)) {
		if (!(key in ru)) problems.push(`${script.path}: "${key}" has no Russian text`);
		else if (script.placeholders(en[key]) !== script.placeholders(ru[key]))
			problems.push(`${script.path}: "${key}" takes different values in the two languages`);
	}
	for (const key of Object.keys(ru)) {
		if (!(key in en)) problems.push(`${script.path}: "${key}" has no English text`);
	}

	// A key the code asks for and no table has stops the script at that line;
	// a key no code asks for is a text nobody keeps true.
	const code = text.replace(bodies.en, "").replace(bodies.ru, "");
	const used = new Set([...code.matchAll(script.used)].map((m) => m[1]));
	for (const key of used) {
		if (!(key in en)) problems.push(`${script.path}: the code prints "${key}", which is in no table`);
	}
	for (const key of Object.keys(en)) {
		if (!used.has(key)) problems.push(`${script.path}: "${key}" is never printed`);
	}

	// Russian text outside its table is a message that skipped the tables and
	// has no English twin.
	code.split("\n").forEach((line) => {
		if (/[Ѐ-ӿ]/.test(line)) problems.push(`${script.path}: Russian text outside the table: ${line.trim()}`);
	});

	total += Object.keys(en).length;
}

if (problems.length) {
	console.error(`Build messages: ${problems.length} problem(s)\n`);
	for (const problem of problems) console.error(`  - ${problem}`);
	process.exit(1);
}
console.log(`Build messages: ${total} messages, the same in both languages.`);
