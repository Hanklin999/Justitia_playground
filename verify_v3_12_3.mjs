#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const repoRoot = path.resolve(process.argv[2] ?? ".");
const resultPath = path.join(repoRoot, "app", "results", "[attemptId]", "page.tsx");
const cssPath = path.join(repoRoot, "app", "globals.css");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

if (!fs.existsSync(resultPath)) fail("找不到 app/results/[attemptId]/page.tsx");
if (!fs.existsSync(cssPath)) fail("找不到 app/globals.css");

const result = fs.readFileSync(resultPath, "utf8");
const css = fs.readFileSync(cssPath, "utf8");

const assertions = [
  ["收合元件存在", result.includes("function CollapsiblePanel(")],
  ["初始狀態為關閉", result.includes("useState(false)")],
  ["內容只在展開後渲染", result.includes('{isOpen && <div className="result-collapsible-body">{children}</div>}')],
  ["按鈕提供 aria-expanded", result.includes("aria-expanded={isOpen}")],
  ["Pacing report 已收合", result.includes('className="pacing-collapsible"')],
  ["第三方外部參考已收合", result.includes('className="external-reference-collapsible"')],
  ["錯因診斷已收合", result.includes('className="error-diagnosis-collapsible"')],
  ["標記快速列存在", result.includes('className="annotation-quick-row"')],
  ["其他標記與筆記已收合", result.includes('className="annotation-collapsible"')],
  ["沒有殘留舊 details 實作", !result.includes('<details className="result-collapsible')],
  ["v3.12.3 CSS 已載入", css.includes("v3.12.3: verified controlled collapsibles")],
];

let failed = false;
for (const [label, passed] of assertions) {
  console.log(`${passed ? "PASS" : "FAIL"}: ${label}`);
  if (!passed) failed = true;
}
if (failed) process.exit(1);

console.log("");
console.log("v3.12.3 靜態驗證通過：四類內容預設關閉，按下展開後才會渲染。");
