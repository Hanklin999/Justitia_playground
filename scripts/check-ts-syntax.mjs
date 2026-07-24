import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const ts = require("typescript");

const root = path.resolve(import.meta.dirname, "..");
const ignored = new Set(["node_modules", ".next"]);

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (ignored.has(entry.name)) return [];
    const fullPath = path.join(directory, entry.name);
    return entry.isDirectory() ? walk(fullPath) : [fullPath];
  });
}

const files = walk(root).filter((file) => /\.(ts|tsx)$/.test(file) && !file.endsWith(".d.ts"));
let failures = 0;

for (const file of files) {
  const source = fs.readFileSync(file, "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
      jsx: ts.JsxEmit.ReactJSX,
    },
    fileName: file,
    reportDiagnostics: true,
  });
  const errors = (output.diagnostics ?? []).filter(
    (diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error,
  );
  if (errors.length === 0) continue;
  failures += 1;
  console.error(`\n${path.relative(root, file)}`);
  for (const diagnostic of errors) {
    console.error(ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"));
  }
}

if (failures > 0) {
  console.error(`\nFAIL: ${failures} TypeScript/TSX files contain syntax errors.`);
  process.exit(1);
}

console.log(`PASS: ${files.length} TypeScript/TSX files transpiled without syntax errors.`);
