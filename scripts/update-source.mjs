#!/usr/bin/env node
// Gera a fonte AltStore/SideStore que vai para o GitHub Pages a partir de community-source/apps.json:
// troca o OWNER/mangocut de exemplo pelo repositório real, adiciona a versão recém-publicada (tamanho real
// do .ipa) e mantém as versões que já estavam publicadas.
//
// node scripts/update-source.mjs --repo dono/mangocut --version 1.2.0 --build 42 --tag v1.2.0 \
//   --ipa MangoCUT.ipa --out _site [--previous apps-publicado.json] [--notes "Novidades"]
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";

const MAX_VERSIONS = 10;
const root = path.resolve(import.meta.dirname, "..");

const { values } = parseArgs({
  options: {
    repo: { type: "string" },
    version: { type: "string" },
    build: { type: "string", default: "1" },
    tag: { type: "string" },
    ipa: { type: "string" },
    out: { type: "string" },
    previous: { type: "string" },
    notes: { type: "string" },
  },
});

for (const key of ["repo", "version", "ipa", "out"]) {
  if (!values[key]) {
    console.error(`update-source: falta --${key}`);
    process.exit(1);
  }
}
const [owner, name] = values.repo.split("/");
if (!owner || !name) {
  console.error(`update-source: --repo deve ser dono/nome, recebido "${values.repo}"`);
  process.exit(1);
}

const pagesURL = `https://${owner.toLowerCase()}.github.io/${name}`;
const repoURL = `https://github.com/${values.repo}`;
const tag = values.tag ?? `v${values.version}`;

const template = readFileSync(path.join(root, "community-source/apps.json"), "utf-8")
  .replaceAll("https://OWNER.github.io/mangocut", pagesURL)
  .replaceAll("https://github.com/OWNER/mangocut", repoURL);
const source = JSON.parse(template);
const app = source.apps[0];

const release = {
  version: values.version,
  buildVersion: values.build,
  date: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
  localizedDescription: values.notes ?? `MangoCUT ${values.version}. Notas completas em ${repoURL}/releases/tag/${tag}`,
  downloadURL: `${repoURL}/releases/download/${tag}/MangoCUT.ipa`,
  size: statSync(values.ipa).size,
  minOSVersion: "16.0",
};

let published = [];
if (values.previous && existsSync(values.previous)) {
  try {
    const previous = JSON.parse(readFileSync(values.previous, "utf-8"));
    const previousApp = previous.apps?.find((a) => a.bundleIdentifier === app.bundleIdentifier);
    published = (previousApp?.versions ?? []).filter((v) => v.size > 0 && v.version !== release.version);
  } catch (err) {
    console.warn(`update-source: ignorando ${values.previous} (${err.message})`);
  }
}

app.versions = [release, ...published].slice(0, MAX_VERSIONS);
// Campos da versão atual no nível do app, para clientes AltStore/SideStore mais antigos.
app.version = release.version;
app.versionDate = release.date;
app.versionDescription = release.localizedDescription;
app.downloadURL = release.downloadURL;
app.size = release.size;

mkdirSync(values.out, { recursive: true });
writeFileSync(path.join(values.out, "apps.json"), JSON.stringify(source, null, 2) + "\n");
copyFileSync(path.join(root, "community-source/icon.png"), path.join(values.out, "icon.png"));

console.log(`Fonte gerada: ${path.join(values.out, "apps.json")}`);
console.log(`  ${app.versions.length} versão(ões), atual ${release.version} (${release.size} bytes)`);
console.log(`  URL da fonte: ${source.sourceURL}`);
