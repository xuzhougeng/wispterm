import { cp, mkdir, readdir, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const docsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.join(docsRoot, "dist-cloudflare");
const skip = new Set([
  ".wrangler",
  "dist-cloudflare",
  "node_modules",
  "package.json",
  "scripts",
  "src",
  "test",
  "wrangler.toml",
  "wrangler.toml.example",
]);

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

for (const entry of await readdir(docsRoot, { withFileTypes: true })) {
  if (skip.has(entry.name)) continue;
  await cp(path.join(docsRoot, entry.name), path.join(outDir, entry.name), {
    recursive: true,
  });
}
