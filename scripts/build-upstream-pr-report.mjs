#!/usr/bin/env node
/**
 * Build an upstream self-hosted release PR body and review metadata.
 */
import { readFileSync, writeFileSync } from "node:fs";

const VERSION_RE = /^\d+\.\d+\.\d+$/;
const RISK_RE = /\b(breaking|deprecated|removed|migration|manual action)\b/gi;
const SENSITIVE_PATH_RE =
  /(^|\/)(docker-compose\.yml|\.env(?:\.|$)|nginx|sentry|snuba|relay|taskbroker|migrations|install)(\/|$)|^install\.sh$/i;
const MAX_BODY_CHARS = 50_000;

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error("usage: --current <version> --target <version> --releases-json <file> --changed-files <file> --body-file <file> --metadata-file <file>");
    }
    args[key.slice(2)] = value;
  }

  for (const key of [
    "current",
    "target",
    "releases-json",
    "changed-files",
    "body-file",
    "metadata-file",
  ]) {
    if (!args[key]) {
      throw new Error(`missing required argument: --${key}`);
    }
  }

  return args;
}

function versionKey(version) {
  if (!VERSION_RE.test(version)) {
    throw new Error(`not stable SemVer: ${version}`);
  }

  return version.split(".").map(Number);
}

function compareVersions(left, right) {
  const leftKey = versionKey(left);
  const rightKey = versionKey(right);
  for (let index = 0; index < 3; index += 1) {
    if (leftKey[index] !== rightKey[index]) {
      return leftKey[index] - rightKey[index];
    }
  }
  return 0;
}

function stableReleases(releases, current, target) {
  versionKey(current);
  versionKey(target);

  const selected = releases
    .filter(
      (release) =>
        !release.draft &&
        !release.prerelease &&
        typeof release.tag_name === "string" &&
        VERSION_RE.test(release.tag_name) &&
        compareVersions(release.tag_name, current) > 0 &&
        compareVersions(release.tag_name, target) <= 0,
    )
    .sort((left, right) => compareVersions(left.tag_name, right.tag_name));

  if (selected.length === 0 || selected.at(-1).tag_name !== target) {
    throw new Error(`target ${target} was not found as a stable release`);
  }

  return selected;
}

function truncate(text, limit) {
  if (text.length <= limit) {
    return text;
  }

  return `${text.slice(0, limit).trimEnd()}\n\n… release notes truncated; see full changelog link below.`;
}

function buildReport(current, target, releases, changedFiles) {
  const between = stableReleases(releases, current, target);
  const signals = [];
  const notes = [];
  let remaining = MAX_BODY_CHARS - 8_000;

  for (const release of between) {
    const tag = release.tag_name;
    const url =
      release.html_url ??
      `https://github.com/getsentry/self-hosted/releases/tag/${tag}`;
    const body = release.body || "_No release notes provided._";
    const matches = [...new Set(body.match(RISK_RE)?.map((match) => match.toLowerCase()) ?? [])].sort();
    if (matches.length > 0) {
      signals.push(`${tag}: ${matches.join(", ")}`);
    }

    const allowed = Math.max(0, Math.min(12_000, remaining));
    const note = truncate(body, allowed);
    remaining -= note.length;
    notes.push(
      `<details>\n<summary>${tag}</summary>\n\n${note}\n\nFull changelog: ${url}\n\n</details>`,
    );
  }

  const sensitiveFiles = changedFiles.filter((file) =>
    SENSITIVE_PATH_RE.test(file),
  );
  const riskDetected = signals.length > 0 || sensitiveFiles.length > 0;
  const manualReview = [
    "## Manual compatibility review",
    "",
    "- [ ] Review all upstream release notes below.",
    "- [ ] Review upstream configuration/default changes before merging.",
    "- [ ] Confirm database migrations and any required manual steps.",
    "- [ ] Confirm the chart’s version-gated templates remain correct.",
  ];

  if (signals.length > 0) {
    manualReview.push("", "### Explicit upgrade-risk signals", "");
    manualReview.push(...signals.map((signal) => `- \`${signal}\``));
  }
  if (sensitiveFiles.length > 0) {
    manualReview.push("", "### Sensitive upstream files changed", "");
    manualReview.push(...sensitiveFiles.map((file) => `- \`${file}\``));
  }

  const report = [
    `## Sentry self-hosted ${target}`,
    "",
    `Updates the chart app version from \`${current}\` to \`${target}\`.`,
    "",
    ...manualReview,
    "",
    "## Upstream release notes",
    "",
    ...notes,
    "",
    "> This PR was created automatically. It never auto-merges.",
  ].join("\n");

  return {
    report: report.slice(0, MAX_BODY_CHARS),
    metadata: {
      draft: riskDetected,
      release_count: between.length,
      risk_signals: signals,
      sensitive_files: sensitiveFiles,
    },
  };
}

try {
  const args = parseArgs(process.argv.slice(2));
  const releases = JSON.parse(readFileSync(args["releases-json"], "utf8"));
  if (!Array.isArray(releases)) {
    throw new Error("release metadata must be a JSON array");
  }
  const changedFiles = readFileSync(args["changed-files"], "utf8")
    .split(/\r?\n/)
    .map((file) => file.trim())
    .filter(Boolean);
  const { report, metadata } = buildReport(
    args.current,
    args.target,
    releases,
    changedFiles,
  );

  writeFileSync(args["body-file"], report);
  writeFileSync(args["metadata-file"], `${JSON.stringify(metadata, null, 2)}\n`);
} catch (error) {
  console.error(`build-upstream-pr-report: ${error.message}`);
  process.exitCode = 1;
}
