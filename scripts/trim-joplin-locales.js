#!/usr/bin/env node
/*
 * Cuts unused UI translations out of Joplin's locales/index.js.
 *
 * Why this is needed: Joplin compiles every translation into that file at build
 * time and both the translation data and the settings screen read from it:
 *
 *     locales['en_GB'] = require('./en_GB.json');
 *     locales['ar']    = require('./ar.json');
 *     stats['ar'] = { percentDone: 47, pluralForms: function(n) { ... } };
 *     module.exports = { locales: locales, stats: stats };
 *
 *   packages/lib/locale.ts     -> supportedLocales()  = Object.keys(locales)
 *   packages/lib/builtInMetadata.ts -> the "Language" dropdown options
 *
 * So the language list you see in the settings screen is exactly the key set of
 * the exported `locales` object.
 *
 *   usage: trim-joplin-locales.js <index.js> <keep-prefix...>
 *
 * Three things happen:
 *   1. `["xx"] = ...` entries for unwanted languages are removed (smaller file)
 *   2. JSON blobs that are no longer referenced are removed too
 *   3. regardless of how the maps were built, a filter is appended to the file
 *      that rewrites module.exports so it can only contain the kept languages
 *
 * Step 3 is the safety net: it does not depend on recognising the file layout.
 *
 * The file is only rewritten if the result still parses as JavaScript.
 */
'use strict';

const fs = require('fs');
const vm = require('vm');

// Language ids Joplin ships. Used to tell a translation entry apart from an
// unrelated ["key"] = value assignment.
const KNOWN_LANGUAGES = new Set([
    'ar', 'bg_BG', 'bs_BA', 'ca', 'cs_CZ', 'da_DK', 'de_DE', 'el_GR',
    'en_GB', 'en_US', 'eo', 'es_ES', 'et_EE', 'eu', 'fa', 'fi_FI', 'fr_FR',
    'gl_ES', 'hr_HR', 'hu_HU', 'id_ID', 'it_IT', 'ja_JP', 'ko', 'nb', 'nb_NO',
    'nl_BE', 'nl_NL', 'pl_PL', 'pt_BR', 'pt_PT', 'ro', 'ro_MD', 'ro_RO',
    'ru_RU', 'sk_SK', 'sl_SI', 'sr_RS', 'sv', 'th_TH', 'tr_TR', 'uk_UA', 'vi',
    'zh_CN', 'zh_TW',
]);

const [file, ...keepPrefixes] = process.argv.slice(2);
if (!file) {
    console.error('usage: trim-joplin-locales.js <index.js> <keep-prefix...>');
    process.exit(2);
}

const keep = keepPrefixes.length ? keepPrefixes : ['en', 'zh'];
const keepLanguage = (id) => keep.some((p) => id.toLowerCase().startsWith(p.toLowerCase()));

let src = fs.readFileSync(file, 'utf8');
const sizeBefore = Buffer.byteLength(src, 'utf8');

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Walk a JS expression starting at `start` and return the index of the `,` or
// `;` that terminates the statement containing it. Skips strings, templates and
// comments so separators inside them are ignored.
function scanStatementEnd(s, start, limit) {
    let depth = 0;
    let state = 'code';
    for (let i = start; i < Math.min(s.length, limit); i++) {
        const c = s[i];
        const n = s[i + 1];
        if (state === 'code') {
            if (c === '/' && n === '/') { state = 'line'; i++; continue; }
            if (c === '/' && n === '*') { state = 'block'; i++; continue; }
            if (c === "'") { state = 'single'; continue; }
            if (c === '"') { state = 'double'; continue; }
            if (c === '`') { state = 'template'; continue; }
            if (c === '(' || c === '[' || c === '{') { depth++; continue; }
            if (c === ')' || c === ']' || c === '}') { depth--; continue; }
            if (depth <= 0 && (c === ',' || c === ';')) return i;
            continue;
        }
        if (state === 'line') { if (c === '\n') state = 'code'; continue; }
        if (state === 'block') { if (c === '*' && n === '/') { state = 'code'; i++; } continue; }
        if (state === 'single' || state === 'double') {
            if (c === '\\') { i++; continue; }
            if ((state === 'single' && c === "'") || (state === 'double' && c === '"')) state = 'code';
            continue;
        }
        if (state === 'template') {
            if (c === '\\') { i++; continue; }
            if (c === '`') state = 'code';
        }
    }
    return -1;
}

// Remove src[from..to) and keep the surrounding list syntax valid.
function cut(s, from, to) {
    if (to < s.length && s[to] === ',') to++;
    else {
        // last element of the list: drop the separator that precedes it
        let j = from - 1;
        while (j >= 0 && /\s/.test(s[j])) j--;
        if (s[j] === ',') from = j;
    }
    return s.slice(0, from) + s.slice(to);
}

// ------------------------------------------------------------ pass 1: drop --
const foundLanguages = new Set();
const removedLanguages = [];
const droppedValues = [];

{
    const re = /\[\s*(["'])([A-Za-z_][A-Za-z0-9_]*)["']\s*\]\s*=\s*/g;
    const hits = [];
    let m;
    while ((m = re.exec(src)) !== null) {
        const lang = m[2];
        if (!KNOWN_LANGUAGES.has(lang)) continue;
        foundLanguages.add(lang);
        if (keepLanguage(lang)) continue;
        hits.push({ start: m.index, lang, valueStart: re.lastIndex });
    }
    // back to front so earlier indices stay valid
    for (let i = hits.length - 1; i >= 0; i--) {
        const { start, lang, valueStart } = hits[i];
        const end = scanStatementEnd(src, valueStart, src.length);
        if (end < 0) continue;
        const value = src.slice(valueStart, end).trim();
        src = cut(src, start, end);
        removedLanguages.push(lang);
        if (/^[A-Za-z_$][\w$]*$/.test(value)) droppedValues.push(value);
    }
}

// -------------------------------------------------- pass 2: orphaned blobs --
const removedBlobs = [];
for (const name of [...new Set(droppedValues)]) {
    const uses = (src.match(new RegExp(`\\b${escapeRe(name)}\\b`, 'g')) || []).length;
    if (uses > 1) continue; // still referenced somewhere else
    const def = new RegExp(`\\b(?:var|let|const)\\s+${escapeRe(name)}\\s*=\\s*`);
    const dm = def.exec(src);
    if (!dm) continue;
    const valueStart = dm.index + dm[0].length;
    const end = scanStatementEnd(src, valueStart, src.length);
    if (end < 0) continue;
    src = cut(src, dm.index, end);
    removedBlobs.push(name);
}

// ------------------------------------------------ pass 3: export filtering --
// Safety net. Whatever the file looks like, force the exported maps down to the
// kept languages, because Object.keys(module.exports.locales) IS the language
// list shown in the settings screen.
const keptLanguages = [...foundLanguages].filter(keepLanguage).sort();
if (keptLanguages.length) {
    const keepEntries = keptLanguages.map((l) => `${JSON.stringify(l)}: 1`).join(', ');
    src += `
;/* trimmed by Joplin-win-x64 build */
(function () {
    var KEEP = { ${keepEntries} };
    function filterMap(m) {
        var out = {};
        if (!m) return out;
        for (var k in m) {
            if (Object.prototype.hasOwnProperty.call(m, k) && KEEP[k] === 1) out[k] = m[k];
        }
        return out;
    }
    try {
        var ex = module.exports;
        if (ex && ex.locales) {
            module.exports = { locales: filterMap(ex.locales), stats: filterMap(ex.stats) };
        }
    } catch (e) { /* keep the original exports */ }
})();
`;
}

// ------------------------------------------------------------------ verify --
if (!foundLanguages.size) {
    console.log(`trim-joplin-locales: ${file}: no translation entries (skipped)`);
    process.exit(0);
}

try {
    new vm.Script(src, { filename: file });
} catch (error) {
    console.error(`trim-joplin-locales: refusing to write ${file} - the result does not parse: ${error.message}`);
    process.exit(1);
}

fs.writeFileSync(file, src);
const savedKib = Math.round((sizeBefore - Buffer.byteLength(src, 'utf8')) / 1024);
console.log(`trim-joplin-locales: ${file}`);
console.log(`  found ${foundLanguages.size} language(s), removed ${removedLanguages.length} entry/entries and ${removedBlobs.length} data blob(s), ${savedKib} KiB smaller`);
console.log(`  languages left: ${keptLanguages.join(', ')}`);
