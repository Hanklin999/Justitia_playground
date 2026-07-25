#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const VERSION = "3.12.2";
const UPDATED_AT = "2026/07/25 16:20:58 (UTC+8)";
const bundleRoot = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(process.argv[2] ?? ".");

function fail(message) {
  throw new Error(message);
}

function normalize(text) {
  return text.replace(/\r\n/g, "\n");
}

function readText(filePath) {
  return normalize(fs.readFileSync(filePath, "utf8"));
}

function writeText(filePath, text) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text.endsWith("\n") ? text : `${text}\n`, "utf8");
}

function indentBlock(block, spaces) {
  const prefix = " ".repeat(spaces);
  return block.split("\n").map((line) => line.length ? `${prefix}${line}` : line).join("\n");
}

function replaceOnce(text, oldText, newText, label) {
  const indentCandidates = [0, 2, 4, 6, 8, 10, 12];

  for (const spaces of indentCandidates) {
    if (text.includes(indentBlock(newText, spaces))) return text;
  }

  for (const spaces of indentCandidates) {
    const oldVariant = indentBlock(oldText, spaces);
    if (text.includes(oldVariant)) {
      return text.replace(oldVariant, indentBlock(newText, spaces));
    }
  }

  fail(`${label}: expected source block not found. Confirm that you are running this from the Justitia_playground repository root.`);
}

function loadJson(relativePath) {
  return JSON.parse(readText(path.join(bundleRoot, relativePath)));
}

function applyReplacementSet(text, relativePath) {
  const replacements = loadJson(relativePath);
  for (const replacement of replacements) {
    text = replaceOnce(text, replacement.old, replacement.new, replacement.label);
  }
  return text;
}

function copyBundleFile(relativePath) {
  const source = path.join(bundleRoot, relativePath);
  const destination = path.join(repoRoot, relativePath);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function patchResultPage() {
  const filePath = path.join(repoRoot, "app", "results", "[attemptId]", "page.tsx");
  let text = readText(filePath);

  if (!text.includes("type ExternalExplanationLink")) {
    console.log("補上 v3.12.1 第三方外部參考前置程式…");
    text = applyReplacementSet(text, "patches/v3121_replacements.json");
  }

  text = applyReplacementSet(text, "patches/v3122_replacements.json");

  const requiredMarkers = [
    'className="result-collapsible pacing-collapsible"',
    'className="result-collapsible external-reference-collapsible"',
    'className="result-collapsible error-diagnosis-collapsible"',
    'className="annotation-quick-row"',
  ];
  for (const marker of requiredMarkers) {
    if (!text.includes(marker)) fail(`Result page verification failed: missing ${marker}`);
  }

  writeText(filePath, text);
}

function patchHomePage() {
  const filePath = path.join(repoRoot, "app", "page.tsx");
  let text = readText(filePath);

  const original = `      <div className="eyebrow">ROC 105–114</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫</p>`;

  const v3121 = `      <div className="eyebrow">105-114 司律一試備考工具</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫 | 攻克國考有如神助</p>
      <p className="release-meta">v.3.12.1，last updated 2026/07/25 12:34:33 (UTC+8)</p>`;

  const v3122 = `      <div className="eyebrow">105-114 司律一試備考工具</div>
      <h1>Justitia&apos;s playground</h1>
      <p className="lead">司律陪考資料庫 | 攻克國考有如神助</p>
      <p className="release-meta">v.3.12.2，last updated ${UPDATED_AT}</p>`;

  if (text.includes(v3122)) {
    writeText(filePath, text);
    return;
  }

  if (text.includes(original)) {
    text = text.replace(original, v3122);
  } else if (text.includes(v3121)) {
    text = text.replace(v3121, v3122);
  } else if (text.includes('className="release-meta"')) {
    text = text.replace(
      /<p className="release-meta">v\.3\.12\.\d+，last updated .*?<\/p>/,
      `<p className="release-meta">v.3.12.2，last updated ${UPDATED_AT}</p>`,
    );
  } else {
    console.warn("首頁標題結構與預期不同，未自動改動首頁文案；其他 v3.12.2 修改仍會繼續。");
  }

  writeText(filePath, text);
}

function patchCss() {
  const filePath = path.join(repoRoot, "app", "globals.css");
  let text = readText(filePath).trimEnd();

  const css3121 = readText(path.join(bundleRoot, "assets", "v3121.css")).trim();
  const css3122 = readText(path.join(bundleRoot, "assets", "v3122.css")).trim();

  if (!text.includes("v3.12.1: third-party external explanations")) {
    text += `\n\n${css3121}`;
  }
  if (!text.includes("v3.12.2: collapsed result-page diagnostics and annotations")) {
    text += `\n\n${css3122}`;
  }

  writeText(filePath, text);
}

function patchPackageVersions() {
  for (const relativePath of ["package.json", "package-lock.json"]) {
    const filePath = path.join(repoRoot, relativePath);
    if (!fs.existsSync(filePath)) continue;

    const json = JSON.parse(fs.readFileSync(filePath, "utf8"));
    json.version = VERSION;
    if (json.packages && json.packages[""]) {
      json.packages[""].version = VERSION;
    }
    writeText(filePath, JSON.stringify(json, null, 2));
  }
}

function patchReadme() {
  const filePath = path.join(repoRoot, "README.md");
  if (!fs.existsSync(filePath)) return;

  let text = readText(filePath);
  text = text.replace(/^# Justitia's playground v3\.12\.\d+/m, "# Justitia's playground v3.12.2");

  const section = `## v3.12.2 重點

- 測驗結果頁的「Pacing report／答題節奏診斷」預設收合，使用者點擊後才展開完整分析。
- 每題「第三方外部參考」與「這題為什麼沒拿滿分？」預設收合。
- 標記區只常駐顯示模考是否標記，以及加入／移除檢討標記按鈕。
- 模考筆記、檢討筆記與補充資訊改到「標記與筆記詳情」內，點擊後展開。
- 使用原生 details／summary，支援鍵盤操作與行動版點擊；本版無新增 Supabase schema。

`;

  if (!text.includes("## v3.12.2 重點")) {
    const anchor = text.includes("## v3.12.1 重點") ? "## v3.12.1 重點" : "## v3.12.0 重點";
    if (text.includes(anchor)) text = text.replace(anchor, section + anchor);
    else text += `\n${section}`;
  }

  writeText(filePath, text);
}

function verifyRepository() {
  const required = [
    path.join(repoRoot, "app", "page.tsx"),
    path.join(repoRoot, "app", "results", "[attemptId]", "page.tsx"),
    path.join(repoRoot, "app", "globals.css"),
    path.join(repoRoot, "package.json"),
  ];

  const missing = required.filter((filePath) => !fs.existsSync(filePath));
  if (missing.length) {
    fail(`Run this script from the Justitia_playground repository root. Missing: ${missing.join(", ")}`);
  }
}

function main() {
  verifyRepository();
  patchResultPage();
  patchHomePage();
  patchCss();
  patchPackageVersions();
  patchReadme();

  for (const relativePath of [
    "supabase/migrations/0012_v3_12_1_external_explanations.sql",
    "supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql",
    "supabase/sql_editor_v3/29_verify_v3_12_1.sql",
    "supabase/V3_12_1_UPGRADE.md",
    "docs/EXTERNAL_REFERENCE_POLICY.md",
    "RELEASE_NOTES_v3.12.2.md",
  ]) {
    copyBundleFile(relativePath);
  }

  console.log("");
  console.log(`Applied Justitia's playground v${VERSION}`);
  console.log(`Homepage timestamp: ${UPDATED_AT}`);
  console.log("v3.12.2 has no new Supabase schema.");
  console.log("If SQL 28 and 29 were not run for v3.12.1, run them before testing external explanation links.");
  console.log("Next: npm.cmd run check:syntax; npm.cmd run typecheck; npm.cmd run build");
}

try {
  main();
} catch (error) {
  console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
