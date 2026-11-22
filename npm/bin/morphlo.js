#!/usr/bin/env node
// npx morphlo            → download the latest Morphlo release from GitHub and install it
// npx morphlo uninstall  → quit and move Morphlo to the Trash
// Uses only Node built-ins and macOS's own tools (curl-free: https + ditto). No telemetry.
"use strict";
const https = require("https");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const REPO = "Mocinjay/morphlo";
// MORPHLO_ZIP_URL overrides the source (testing). Default: the latest GitHub release.
const ZIP_URL = process.env.MORPHLO_ZIP_URL || `https://github.com/${REPO}/releases/latest/download/Morphlo.zip`;
const APP = "Morphlo.app";

function die(msg) { console.error(`\n✖ ${msg}`); process.exit(1); }
if (process.platform !== "darwin") die("Morphlo is a macOS app.");

function download(url, dest, redirects = 0) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { "User-Agent": "morphlo-installer" } }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects < 10) {
        res.resume();
        return resolve(download(new URL(res.headers.location, url).toString(), dest, redirects + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error(`download failed (HTTP ${res.statusCode})`)); }
      const total = Number(res.headers["content-length"] || 0);
      let got = 0, shown = -1;
      const out = fs.createWriteStream(dest);
      res.on("data", (c) => {
        got += c.length;
        const pct = total ? Math.floor((got / total) * 100) : -1;
        if (pct !== shown && pct % 5 === 0) { shown = pct; process.stdout.write(`\r  Downloading… ${pct}%`); }
      });
      res.pipe(out);
      out.on("finish", () => { process.stdout.write("\n"); out.close(resolve); });
      out.on("error", reject);
    }).on("error", reject);
  });
}

function targetDir() {
  if (process.env.MORPHLO_INSTALL_DIR) { fs.mkdirSync(process.env.MORPHLO_INSTALL_DIR, { recursive: true }); return process.env.MORPHLO_INSTALL_DIR; } // testing
  try { fs.accessSync("/Applications", fs.constants.W_OK); return "/Applications"; }
  catch { const d = path.join(os.homedir(), "Applications"); fs.mkdirSync(d, { recursive: true }); return d; }
}

function quitRunning() {
  spawnSync("osascript", ["-e", 'tell application id "io.github.mocinjay.morphlo" to quit'], { stdio: "ignore" });
}

async function install() {
  console.log("Morphlo — installing the latest release");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "morphlo-"));
  const zip = path.join(tmp, "Morphlo.zip");
  if (ZIP_URL.startsWith("file://")) fs.copyFileSync(new URL(ZIP_URL), zip);
  else await download(ZIP_URL, zip);
  execFileSync("/usr/bin/ditto", ["-x", "-k", zip, tmp]);
  const src = path.join(tmp, APP);
  if (!fs.existsSync(src)) die("the download didn't contain Morphlo.app");
  // Refuse anything that isn't a valid, notarized Apple-signed build.
  const check = spawnSync("/usr/sbin/spctl", ["--assess", "--type", "execute", src], { encoding: "utf8" });
  if (check.status !== 0) die(`Gatekeeper rejected the download:\n${check.stderr}`);

  const dir = targetDir();
  const dest = path.join(dir, APP);
  if (!process.env.MORPHLO_INSTALL_DIR) quitRunning();
  if (fs.existsSync(dest)) execFileSync("/usr/bin/osascript", ["-e", `tell application "Finder" to delete (POSIX file "${dest}" as alias)`], { stdio: "ignore" });
  execFileSync("/usr/bin/ditto", [src, dest]);
  fs.rmSync(tmp, { recursive: true, force: true });
  if (!process.env.MORPHLO_INSTALL_DIR) spawnSync("/usr/bin/open", [dest]);
  console.log(process.env.MORPHLO_INSTALL_DIR ? `✔ Installed to ${dest}` : `✔ Installed to ${dest} and opened it. Look for the butterfly in your menu bar.`);
}

function uninstall() {
  quitRunning();
  let removed = false;
  for (const dir of ["/Applications", path.join(os.homedir(), "Applications")]) {
    const p = path.join(dir, APP);
    if (fs.existsSync(p)) {
      execFileSync("/usr/bin/osascript", ["-e", `tell application "Finder" to delete (POSIX file "${p}" as alias)`], { stdio: "ignore" });
      console.log(`✔ Moved ${p} to the Trash`);
      removed = true;
    }
  }
  if (!removed) console.log("Morphlo isn't installed.");
}

const cmd = (process.argv[2] || "install").toLowerCase();
if (cmd === "install" || cmd === "update") install().catch((e) => die(e.message));
else if (cmd === "uninstall" || cmd === "remove") uninstall();
else console.log("usage: npx morphlo [install|update|uninstall]");
