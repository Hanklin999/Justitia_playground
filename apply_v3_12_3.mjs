#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const VERSION = "3.12.3";
const UPDATED_AT = "2026/07/25 16:46:05 (UTC+8)";
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

function replaceWithCandidates(text, candidates, newText, label) {
  const indentCandidates = [0, 2, 4, 6, 8, 10, 12];

  for (const spaces of indentCandidates) {
    if (text.includes(indentBlock(newText, spaces))) return text;
  }

  for (const candidate of candidates) {
    for (const spaces of indentCandidates) {
      const oldVariant = indentBlock(candidate, spaces);
      if (text.includes(oldVariant)) {
        return text.replace(oldVariant, indentBlock(newText, spaces));
      }
    }
  }

  fail(`${label}: 找不到預期區塊。請確認腳本是在 Justitia_playground 專案根目錄執行，且 page.tsx 尚未被其他版本大幅改寫。`);
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
    fail(`請在 Justitia_playground 專案根目錄執行。缺少：${missing.join(", ")}`);
  }
}

function patchResultPage() {
  const filePath = path.join(repoRoot, "app", "results", "[attemptId]", "page.tsx");
  let text = readText(filePath);

  if (!text.includes('import type { ReactNode } from "react";')) {
    const hookImport = 'import { useEffect, useMemo, useState } from "react";';
    if (!text.includes(hookImport)) fail("找不到 React hooks import，無法安全加入 ReactNode 型別。");
    text = text.replace(hookImport, `${hookImport}\nimport type { ReactNode } from "react";`);
  }

  if (!text.includes("function CollapsiblePanel(")) {
    const component = readText(path.join(bundleRoot, "assets", "CollapsiblePanel.tsx.txt")).trim();
    const exportMarker = "export default function ResultPage()";
    const exportIndex = text.indexOf(exportMarker);
    if (exportIndex < 0) fail("找不到 ResultPage 元件起點。");
    text = `${text.slice(0, exportIndex).trimEnd()}\n\n${component}\n\n${text.slice(exportIndex)}`;
  }

  if (!text.includes("const primaryReasonLabel =")) {
    const oldBlock = `const primaryReason = primaryReasons[question.question_id] ?? null;
const secondary = secondaryReasons[question.question_id] ?? [];`;
    const newBlock = `const primaryReason = primaryReasons[question.question_id] ?? null;
const primaryReasonLabel = primaryErrorOptions.find((option) => option.value === primaryReason)?.label;
const secondary = secondaryReasons[question.question_id] ?? [];`;
    text = replaceWithCandidates(text, [oldBlock], newBlock, "加入主要錯因顯示文字");
  }

  const replacements = JSON.parse(readText(path.join(bundleRoot, "patches", "v3123_replacements.json")));
  for (const replacement of replacements) {
    text = replaceWithCandidates(text, replacement.candidates, replacement.new, replacement.label);
  }

  const requiredMarkers = [
    "function CollapsiblePanel(",
    "const [isOpen, setIsOpen] = useState(false);",
    "{isOpen && <div className=\"result-collapsible-body\">{children}</div>}",
    'className="pacing-collapsible"',
    'className="external-reference-collapsible"',
    'className="error-diagnosis-collapsible"',
    'className="annotation-quick-row"',
    'className="annotation-collapsible"',
  ];
  for (const marker of requiredMarkers) {
    if (!text.includes(marker)) fail(`結果頁驗證失敗，缺少：${marker}`);
  }

  if (text.includes('<details className="result-collapsible')) {
    fail("結果頁仍含有 v3.12.2 的 details 收合區塊，未完整升級。");
  }

  writeText(filePath, text);
}

function patchCss() {
  const filePath = path.join(repoRoot, "app", "globals.css");
  let text = readText(filePath).trimEnd();
  const css = readText(path.join(bundleRoot, "assets", "v3123.css")).trim();

  if (!text.includes("v3.12.3: verified controlled collapsibles")) {
    text += `\n\n${css}`;
  }

  writeText(filePath, text);
}

function patchHomePage() {
  const filePath = path.join(repoRoot, "app", "page.tsx");
  let text = readText(filePath);
  const releaseLine = `<p className="release-meta">v.3.12.3，last updated ${UPDATED_AT}</p>`;

  if (/<p className="release-meta">v\.3\.12\.\d+，last updated .*?<\/p>/.test(text)) {
    text = text.replace(/<p className="release-meta">v\.3\.12\.\d+，last updated .*?<\/p>/, releaseLine);
  } else {
    const lead = '<p className="lead">司律陪考資料庫 | 攻克國考有如神助</p>';
    if (text.includes(lead)) text = text.replace(lead, `${lead}\n      ${releaseLine}`);
    else console.warn("首頁未找到 release-meta 或指定副標題，未自動新增版本小字。");
  }

  writeText(filePath, text);
}

function patchPackageVersions() {
  for (const relativePath of ["package.json", "package-lock.json"]) {
    const filePath = path.join(repoRoot, relativePath);
    if (!fs.existsSync(filePath)) continue;
    const json = JSON.parse(fs.readFileSync(filePath, "utf8"));
    json.version = VERSION;
    if (json.packages && json.packages[""]) json.packages[""].version = VERSION;
    writeText(filePath, JSON.stringify(json, null, 2));
  }
}

function patchReadme() {
  const filePath = path.join(repoRoot, "README.md");
  if (!fs.existsSync(filePath)) return;

  let text = readText(filePath);
  text = text.replace(/^# Justitia's playground v3\.12\.\d+/m, "# Justitia's playground v3.12.3");

  const section = `## v3.12.3 重點

- 改用 React 狀態控制的收合元件，所有內容預設不渲染，使用者按下「展開」後才顯示。
- 收合範圍：Pacing report／答題節奏診斷、第三方外部參考、這題為什麼沒拿滿分、其他標記與筆記。
- 每題外層只常駐顯示「模考有沒有標記」與「加入／移除檢討標記」。
- 支援手機點擊、鍵盤操作與 aria-expanded；本版不需新增 Supabase schema。

`;

  if (!text.includes("## v3.12.3 重點")) {
    const anchor = text.match(/## v3\.12\.\d+ 重點/)?.[0] ?? "## v3.12.0 重點";
    if (text.includes(anchor)) text = text.replace(anchor, section + anchor);
    else text += `\n${section}`;
  }

  writeText(filePath, text);
}

function copyFile(relativePath) {
  const source = path.join(bundleRoot, relativePath);
  const destination = path.join(repoRoot, relativePath);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

function main() {
  verifyRepository();
  patchResultPage();
  patchCss();
  patchHomePage();
  patchPackageVersions();
  patchReadme();
  copyFile("RELEASE_NOTES_v3.12.3.md");
  copyFile("verify_v3_12_3.mjs");

  console.log("");
  console.log(`Applied Justitia's playground v${VERSION}`);
  console.log(`Homepage timestamp: ${UPDATED_AT}`);
  console.log("收合已改為 React state 控制：初始 isOpen=false，未展開時內容不會渲染。");
  console.log("v3.12.3 不需要新增 Supabase schema。");
  console.log("Next: node .\\verify_v3_12_3.mjs");
  console.log("Then: npm.cmd run check:syntax; npm.cmd run typecheck; npm.cmd run build");
}

try {
  main();
} catch (error) {
  console.error(`ERROR: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
