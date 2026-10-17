#!/usr/bin/env node
// Inicializador da CLI. Dentro do repositório roda direto de src/ (type stripping do Node);
// instalado pelo npm, usa o build em dist/ (o Node não executa .ts dentro de node_modules).
import { existsSync } from "node:fs";
import { sep } from "node:path";
import { fileURLToPath } from "node:url";

const srcCli = new URL("../src/cli.ts", import.meta.url);
const insideNodeModules = fileURLToPath(import.meta.url).includes(`${sep}node_modules${sep}`);
const entry = existsSync(srcCli) && !insideNodeModules ? srcCli : new URL("../dist/cli.js", import.meta.url);

const { main } = await import(entry.href);
process.exitCode = main(process.argv.slice(2));
