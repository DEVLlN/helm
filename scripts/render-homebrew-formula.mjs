#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = fileURLToPath(new URL("..", import.meta.url));
const packageJSON = JSON.parse(readFileSync(join(rootDir, "package.json"), "utf8"));
const repositoryURL = packageJSON.repository?.url ?? "";
const repoMatch = repositoryURL.match(/github\.com[:/](.+?)\/(.+?)(?:\.git)?$/i);
const repoOwner = repoMatch?.[1] ?? "DEVLlN";
const repoName = repoMatch?.[2] ?? "helm";

function usage() {
  console.log(`Usage: node scripts/render-homebrew-formula.mjs [--version X.Y.Z] [--sha256 SHA256] [--url SOURCE_URL]

Render the Homebrew formula for the homebrew-helm tap.

Defaults:
  version  ${packageJSON.version}
  repo     ${repoOwner}/${repoName}

Example:
  node scripts/render-homebrew-formula.mjs --version ${packageJSON.version} --sha256 <release-tarball-sha256>

Install path after publishing:
  brew tap devlin/helm
  brew install devlin/helm/helm
`);
}

let version = packageJSON.version;
let sha256 = "REPLACE_WITH_RELEASE_TARBALL_SHA256";
let sourceURL = "";

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  switch (arg) {
    case "--version":
      version = args[++i] ?? "";
      break;
    case "--sha256":
      sha256 = args[++i] ?? "";
      break;
    case "--url":
      sourceURL = args[++i] ?? "";
      break;
    case "--help":
    case "-h":
      usage();
      process.exit(0);
      break;
    default:
      console.error(`Unsupported argument: ${arg}`);
      usage();
      process.exit(2);
  }
}

if (!version || !sha256) {
  console.error("version and sha256 must both be non-empty.");
  process.exit(2);
}

function githubTagTarballURL(owner, repo, packageVersion) {
  return `https://codeload.github.com/${owner}/${repo}/tar.gz/refs/tags/v${packageVersion}`;
}

const tarballURL = sourceURL || githubTagTarballURL(repoOwner, repoName, version);

function renderHomebrewLicense(rawLicense) {
  if (typeof rawLicense !== "string" || rawLicense.trim() === "" || rawLicense === "UNLICENSED") {
    return ":cannot_represent";
  }

  return JSON.stringify(rawLicense);
}

const formula = `class Helm < Formula
  desc "Helm bridge installer and runtime helpers"
  homepage "https://github.com/${repoOwner}/${repoName}"
  url "${tarballURL}"
  sha256 "${sha256}"
  version "${version}"
  license ${renderHomebrewLicense(packageJSON.license)}
  depends_on "node"

  def install
    libexec.install Dir["*"]
    chmod 0755, libexec/"bin/helm.js"
    bin.install_symlink libexec/"bin/helm.js" => "helm"
  end

  test do
    assert_match "Helm CLI", shell_output("#{bin}/helm --help")
    assert_match "platforms", shell_output("#{bin}/helm platforms")
  end
end
`;

process.stdout.write(formula);
