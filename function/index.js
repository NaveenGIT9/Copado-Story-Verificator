#!/usr/bin/env node
"use strict";

// Story Verification (phase B): runs three real git checks and reports a structured result.
// Generated into scripts/create-copado-records.apex by scripts/build-create-records.js - rerun it after editing.
// Git access only through "copado-git-get" and "git"; progress/result only through the "copado" CLI.

const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const env = process.env;
const ELL = "…";
const DASH = "—";
const MAX_JSON = 90000;
const MAX_ANALYSE = 500;
const CALL_TIMEOUT_MS = 240000; // no single git call may hang the whole run
const LIST_TIMEOUT_MS = 60000; // listing branches takes seconds; a call that hangs is retried once
const CLONE_TIMEOUT_MS = 120000;
const STANDARD_CLONE_TIMEOUT_MS = 900000; // the standard clone checks out every file, which can take many minutes on a big repository
const startedAt = Date.now();
const AUTO_PREFIXES = [
    "Updated sourceApiVersion from",
    "Clear custom_rulesets in code-analyzer.yml",
    "Add custom PMD rules to custom-rules-list.txt"
];
const TITLES = {
    "unregistered-commits": "Unregistered commits",
    "metadata-coverage": "Metadata coverage",
    "org-branch-merge": "Org/environment branch merge"
};
const ORDER = ["unregistered-commits", "metadata-coverage", "org-branch-merge"];
const secrets = [];

// ---- helpers ----

function str(v) {
    return v === undefined || v === null ? "" : String(v);
}

function clip(s, n) {
    const max = n || 500;
    const t = str(s);
    return t.length > max ? t.slice(0, max - 1) + ELL : t;
}

function uniq(a) {
    return Array.from(new Set(a));
}

function capList(arr, n) {
    return arr.slice(0, n).join(", ") + (arr.length > n ? " (+" + (arr.length - n) + " more)" : "");
}

function collectSecrets() {
    try {
        const g = JSON.parse(env.git_json || "{}");
        Object.keys(g).forEach((k) => {
            if (k.toLowerCase() !== "url" && typeof g[k] === "string" && g[k].length >= 4) {
                secrets.push(g[k]);
            }
        });
    } catch (e) {
        // git_json is optional for logging purposes
    }
}

function redact(text) {
    let out = str(text);
    secrets.forEach((s) => {
        out = out.split(s).join("***");
    });
    return out
        .replace(/(https?:\/\/)[^@\s\/]+@/gi, "$1***@")
        .replace(/((?:token|password|secret|key)\s*[=:]\s*)\S+/gi, "$1***");
}

function errMsg(e) {
    const text = (e && e.stderr ? str(e.stderr).trim() : "") || (e && e.message) || str(e);
    return clip(redact(text).replace(/\s+/g, " "), 400);
}

function run(cmd, args, timeoutMs) {
    return cp.execFileSync(cmd, args, {
        encoding: "utf8",
        maxBuffer: 256 * 1024 * 1024,
        timeout: timeoutMs || CALL_TIMEOUT_MS,
        env: Object.assign({}, process.env, { GIT_TERMINAL_PROMPT: "0" }),
        stdio: ["ignore", "pipe", "pipe"]
    });
}

// Returns null when the command fails (git exits non-zero for "no" answers), else the stdout.
function tryRun(cmd, args) {
    try {
        return run(cmd, args);
    } catch (e) {
        return null;
    }
}

// Branch names end up inside a "copado-git-get -g" command string, so accept plain names only.
function isSafe(b) {
    return /^[A-Za-z0-9._\/-]+$/.test(b) && b.charAt(0) !== "-" && b.indexOf("..") === -1;
}

function gitG(command, timeoutMs) {
    return run("copado-git-get", ["-g", command], timeoutMs);
}

function copadoCli(args) {
    try {
        cp.execFileSync("copado", args, { stdio: "inherit" });
    } catch (e) {
        console.log("copado CLI failed: " + clip(redact(e.message), 200));
    }
}

function progress(text) {
    const line = text + " (" + Math.round((Date.now() - startedAt) / 1000) + " s)";
    console.log(line);
    copadoCli(["-p", line]);
}

function emit(json) {
    copadoCli(["--progress", "Verification finished", "--result-data", json]);
    console.log("RESULT:" + json);
}

// JSON text (or an already parsed array) -> array; anything else -> [].
function parseList(raw) {
    let v = raw;
    for (let i = 0; i < 2 && typeof v === "string"; i++) {
        if (v.trim() === "") {
            return [];
        }
        try {
            v = JSON.parse(v);
        } catch (e) {
            return [];
        }
    }
    return Array.isArray(v) ? v : [];
}

// Copied from plugin-promoter runner.mjs (parseApiName): git file path -> Copado metadata API name.
function parseApiName(filePath) {
    const parts = filePath.replace(/\\/g, "/").split("/");
    const defaultIdx = parts.indexOf("default");
    if (defaultIdx === -1) return null;
    const typeFolder = parts[defaultIdx + 1];
    if (["aura", "lwc"].includes(typeFolder)) return parts[defaultIdx + 2] || null;
    if (typeFolder === "objects" && parts.length >= defaultIdx + 5) {
        const objectName = parts[defaultIdx + 2];
        const memberName = parts[parts.length - 1].replace(/-meta\.xml$/, "").replace(/\.[^.]+$/, "");
        return memberName ? objectName + "." + memberName : null;
    }
    return parts[parts.length - 1].replace(/-meta\.xml$/, "").replace(/\.[^.]+$/, "") || null;
}

function makeIsCovered(names, hasLabels) {
    const list = Array.from(names);
    return (c) => {
        const cl = c.toLowerCase();
        if (names.has(cl) || list.some((m) => m.startsWith(cl + "."))) return true;
        return cl === "customlabels" && hasLabels;
    };
}

function mk(id, status, summary, lines) {
    return { id: id, title: TITLES[id], status: status, summary: summary, lines: lines };
}

function skippedChecks(reason) {
    return ORDER.map((id) => mk(id, "skipped", reason, []));
}

function readConfig() {
    const storyName = str(env.storyName);
    const metadataNames = new Map();
    parseList(env.registeredMetadataJson).forEach((s) => {
        const name = str(s).trim();
        if (name && !metadataNames.has(name.toLowerCase())) metadataNames.set(name.toLowerCase(), name);
    });
    const depth = parseInt(env.gitDepth, 10);
    const envBranches = new Map();
    parseList(env.envBranchesJson).forEach((b) => {
        const n = str(b).trim();
        if (n && !envBranches.has(n.toLowerCase())) envBranches.set(n.toLowerCase(), n);
    });
    const findings = parseList(env.findings).map((f) =>
        f !== null && typeof f === "object"
            ? { severity: f.severity === "issue" ? "issue" : "info", message: str(f.message) }
            : { severity: "info", message: str(f) }
    );
    return {
        runId: str(env.runId),
        storyName: storyName,
        feature: str(env.featureBranch).trim() || (storyName ? "feature/" + storyName : ""),
        base: str(env.baseBranch).trim(),
        depth: depth > 0 ? depth : 200,
        envBranches: envBranches,
        registered: parseList(env.registeredCommitsJson).map((s) => str(s).trim().toLowerCase()).filter(Boolean),
        nonComplete: parseList(env.nonCompleteCommitsJson)
            .map((o) => ({ sha: str(o && o.sha).trim().toLowerCase(), status: str(o && o.status) || "Unknown" }))
            .filter((o) => o.sha),
        metadata: new Set(metadataNames.keys()), // lowercase, for matching
        metadataNames: metadataNames, // lowercase -> exact spelling, for display
        hasLabels: str(env.hasCustomLabelMetadata).toLowerCase() === "true",
        findings: findings
    };
}

// ---- git preparation ----

function hasRef(ref) {
    return tryRun("git", ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]) !== null;
}

// Every copado-git-get call costs seconds (a failing one far more), so the remote branches are listed once and only the
// existing ones are fetched, in one command. A failed listing is retried once and then the run stops with the real reason:
// trying branch after branch would turn a connection hiccup into minutes of failing calls.
function listRemoteBranches() {
    let reason = "the repository returned no branches";
    for (let attempt = 1; attempt <= 2; attempt++) {
        try {
            const names = new Set();
            gitG("git ls-remote --heads origin", LIST_TIMEOUT_MS)
                .split("\n")
                .forEach((l) => {
                    const m = /\srefs\/heads\/(\S+)\s*$/.exec(l);
                    if (m) names.add(m[1]);
                });
            if (names.size > 0) return { names: names, error: "" };
        } catch (e) {
            reason = errMsg(e);
            console.log("ls-remote attempt " + attempt + " failed: " + reason);
        }
    }
    return { names: null, error: reason };
}

// Where the feature branch's fetched history starts (minus a day). The base and environment branches are fetched back to that
// date instead of a fixed number of commits, so the branch point is inside their history however many commits a busy
// base branch has gained since the feature branch was cut.
function featureSinceIso() {
    const out = tryRun("git", ["log", "--format=%ct", "HEAD"]);
    if (out === null) return null;
    const times = out.split("\n").map((l) => parseInt(l, 10)).filter((n) => n > 0);
    if (times.length === 0) return null;
    return new Date((Math.min.apply(null, times) - 86400) * 1000).toISOString();
}

function fetchBranches(list, depth, sinceIso) {
    const safe = list.filter(isSafe);
    // By date first; if the server refuses (for example a stale branch with nothing in that period), by commit count.
    const options = sinceIso ? ["--shallow-since=" + sinceIso, "--depth " + depth] : ["--depth " + depth];
    for (let i = 0; i < safe.length; i += 20) {
        const specs = safe
            .slice(i, i + 20)
            .map((b) => "+refs/heads/" + b + ":refs/remotes/origin/" + b)
            .join(" ");
        for (let k = 0; k < options.length; k++) {
            try {
                gitG("git fetch origin " + specs + " " + options[k]);
                break;
            } catch (e) {
                console.log("fetch with " + options[k].split("=")[0] + " failed: " + errMsg(e));
            }
        }
    }
}

// Returns { base, envOk, missing } or { error }.
function fetchBranchesForChecks(cfg) {
    const listing = listRemoteBranches();
    if (!listing.names) return { error: "Could not list the repository branches: " + listing.error };
    const remote = listing.names;
    const candidates = uniq([cfg.base, "main", "master"].filter(Boolean));
    const base = candidates.find((c) => remote.has(c)) || null;
    if (!base) return { error: "No base branch was found on the remote (tried: " + candidates.join(", ") + ")." };
    const envOk = new Map();
    const missing = [];
    cfg.envBranches.forEach((orig, lower) => {
        if (remote.has(orig)) envOk.set(lower, orig);
        else missing.push(orig);
    });
    fetchBranches(uniq([base].concat(Array.from(envOk.values()))), cfg.depth, featureSinceIso());
    if (!hasRef("origin/" + base)) return { error: "Could not fetch the base branch " + base + "." };
    Array.from(envOk.entries()).forEach((entry) => {
        if (!hasRef("origin/" + entry[1])) {
            envOk.delete(entry[0]);
            missing.push(entry[1]);
        }
    });
    return { base: base, envOk: envOk, missing: missing };
}

function ensureMergeBase(base, cfg) {
    for (let i = 0; i <= 5; i++) {
        if (tryRun("git", ["merge-base", "origin/" + base, "HEAD"]) !== null) return true;
        const shallow = (tryRun("git", ["rev-parse", "--is-shallow-repository"]) || "").trim();
        if (i === 5 || shallow !== "true") break;
        const specs = [base, cfg.feature]
            .filter(isSafe)
            .map((b) => "+refs/heads/" + b + ":refs/remotes/origin/" + b)
            .join(" ");
        try {
            gitG("git fetch --deepen=200 origin " + specs);
        } catch (e) {
            console.log("deepen failed: " + errMsg(e));
            break;
        }
    }
    return false;
}

// ---- the three checks ----

function isAncestor(a, b) {
    return tryRun("git", ["merge-base", "--is-ancestor", a, b]) !== null;
}

function checkOrgMerge(ctx) {
    const id = "org-branch-merge";
    const cfg = ctx.cfg;
    const notes = ctx.missing.length ? ["Not on the remote, so not compared: " + ctx.missing.join(", ")] : [];
    if (cfg.envBranches.size === 0) {
        return mk(id, "skipped", "No environment branches configured", notes);
    }
    const raw = run("git", ["log", "--first-parent", "--format=%H%x00%P%x00%s", "origin/" + ctx.base + "..HEAD"]);
    const rows = raw
        .split("\n")
        .filter((l) => l.indexOf("\0") >= 0)
        .map((l) => {
            const p = l.split("\0");
            return { sha: p[0].trim(), parents: str(p[1]).trim().split(/\s+/).filter(Boolean), subject: str(p[2]) };
        })
        .filter((r) => r.sha.length >= 40);
    const re = /^Merge (?:remote-tracking )?branch '(?:origin\/)?([^']+)'/i;
    const found = [];
    // Method A: the merge commit subject names an environment branch.
    rows.forEach((r) => {
        const m = re.exec(r.subject);
        if (m && cfg.envBranches.has(m[1].toLowerCase())) found.push({ sha: r.sha.slice(0, 10), branch: m[1] });
    });
    // Method B (only when A found nothing): the second parent is reachable from an environment branch but not from base.
    for (let i = 0; i < rows.length && found.length === 0; i++) {
        const r = rows[i];
        if (r.parents.length < 2) continue;
        const m = re.exec(r.subject);
        if (m && m[1].toLowerCase() === cfg.feature.toLowerCase()) continue;
        const entries = Array.from(ctx.envOk.entries());
        for (let j = 0; j < entries.length; j++) {
            if (isAncestor(r.parents[1], "origin/" + entries[j][1]) && !isAncestor(r.parents[1], "origin/" + ctx.base)) {
                found.push({ sha: r.sha.slice(0, 10), branch: entries[j][1] });
                break;
            }
        }
    }
    if (found.length > 0) {
        // One merge: everything is in the summary (no repeated detail line). Several: the summary counts them, the lines list each.
        const names = uniq(found.map((f) => f.branch));
        const summary = found.length === 1
            ? found[0].branch + " merged into the feature branch (commit " + found[0].sha + ")"
            : found.length + " environment branch merges: " + names.join(", ");
        const lines = (found.length === 1 ? [] : found.map((f) => f.branch + " " + DASH + " commit " + f.sha)).concat(notes);
        return mk(id, "fail", summary, lines);
    }
    // A pass must mean something was compared: when none of the pipeline's environment branches exist on the remote
    // (other than the base branch, which is always allowed to be merged), say so instead of reporting a clean pass.
    const comparable = Array.from(ctx.envOk.values()).filter((b) => b.toLowerCase() !== ctx.base.toLowerCase());
    if (comparable.length === 0) {
        return mk(id, "warn", "Not compared: no pipeline environment branch exists on the remote", notes);
    }
    return mk(id, "pass", "No environment branch merged", notes);
}

function checkUnregistered(ctx) {
    const id = "unregistered-commits";
    const cfg = ctx.cfg;
    const raw = run("git", ["log", "--format=%H%x00%an%x00%ae%x00%ce%x00%s", "origin/" + ctx.base + "..HEAD"]);
    const extra = raw
        .split("\n")
        .map((l) => l.split("\0"))
        .filter((p) => p[0].trim().length >= 40)
        .map((p) => ({ sha: p[0].trim(), name: str(p[1]), email: str(p[2]).toLowerCase(), committer: str(p[3]).toLowerCase(), subject: str(p[4]) }));
    if (extra.length === 0) {
        return mk(id, "fail", "No commits beyond " + ctx.base + " " + DASH + " nothing to promote", []);
    }
    const regSet = new Set(cfg.registered);
    const isReg = (sha) => {
        const s = sha.toLowerCase();
        return regSet.has(s) || cfg.registered.some((r) => r.length >= 7 && (r.startsWith(s) || s.startsWith(r)));
    };
    const regEmails = new Set(extra.filter((c) => isReg(c.sha) && c.email).map((c) => c.email));
    const unreg = extra.filter((c) => !isReg(c.sha));
    const analysed = unreg.slice(0, MAX_ANALYSE);
    const details = analysed.map((c) => {
        const out = tryRun("git", ["diff-tree", "--no-commit-id", "-r", "--name-only", "--no-renames", "-z", c.sha]);
        const comps = uniq((out === null ? [] : out.split("\0").filter(Boolean)).map(parseApiName).filter(Boolean));
        const sl = c.sha.toLowerCase();
        const nc = cfg.nonComplete.find((n) => n.sha.length >= 7 && (sl.startsWith(n.sha) || n.sha.startsWith(sl)));
        return {
            sha10: c.sha.slice(0, 10),
            author: c.name || c.email || "unknown",
            email: c.email,
            subject: c.subject,
            auto: AUTO_PREFIXES.some((p) => c.subject.startsWith(p)),
            status: nc ? nc.status : null,
            uncovered: comps.filter((x) => !ctx.isCovered(x))
        };
    });
    const lines = details.slice(0, 50).map((d) => {
        let line = d.sha10 + " " + d.author + " \"" + d.subject + "\"";
        if (d.uncovered.length > 0) line += " " + DASH + " uncovered: " + capList(d.uncovered, 30);
        if (d.auto) line += " (Copado auto-commit, exempt)";
        if (d.status) line += " [Copado status: " + d.status + "]";
        return line;
    });
    if (details.length > 50) lines.push("+" + (details.length - 50) + " more");
    if (unreg.length > analysed.length) {
        lines.push("Only the first " + analysed.length + " of " + unreg.length + " commits were analysed.");
        return mk(id, "fail", unreg.length + " commits outside Copado " + DASH + " too many to analyse", lines);
    }
    const effective = details.filter((d) => !d.auto);
    const hard = details.filter((d) => d.status && d.status.toLowerCase() !== "failed");
    const uncoveredCommits = effective.filter((d) => d.uncovered.length > 0);
    const authors = uniq(effective.filter((d) => d.email && !regEmails.has(d.email)).map((d) => d.author));
    if (effective.length === 0) {
        const note = unreg.length === 0 ? "all registered" : unreg.length + " Copado auto-commit(s) exempt, rest registered";
        return mk(id, "pass", extra.length + " commit(s), " + note, lines);
    }
    if (hard.length > 0) {
        return mk(id, "fail", "Commit " + hard[0].sha10 + " has Copado status \"" + hard[0].status + "\"", lines);
    }
    if (uncoveredCommits.length > 0) {
        return mk(id, "fail", uncoveredCommits.length + " commit(s) outside Copado change unregistered components", lines);
    }
    if (authors.length > 0) {
        return mk(id, "fail", "Commit by " + authors.join(", ") + " is not a registered committer " + DASH + " verify manually", lines);
    }
    return mk(
        id,
        "warn",
        effective.length + " commit(s) outside Copado; components registered, same author",
        lines
    );
}

function checkMetadata(ctx) {
    const id = "metadata-coverage";
    let raw = tryRun("git", ["diff", "--name-only", "--no-renames", "-z", "origin/" + ctx.base + "...HEAD"]);
    if (raw === null) raw = tryRun("git", ["diff", "--name-only", "--no-renames", "-z", "origin/" + ctx.base + "..HEAD"]);
    if (raw === null) throw new Error("git diff against origin/" + ctx.base + " failed");
    const comps = uniq(raw.split("\0").filter(Boolean).map(parseApiName).filter(Boolean));
    const uncovered = comps.filter((c) => !ctx.isCovered(c));
    const lines = [];
    if (uncovered.length > 0) {
        // Up to three names fit in the summary; a longer list goes in the details.
        if (uncovered.length > 3) lines.push("Not registered: " + capList(uncovered, 100));
        lines.push("Their changes won't deploy to target - add them to the story in Copado.");
    }
    const changed = new Set(comps.map((c) => c.toLowerCase()));
    const changedList = Array.from(changed);
    const unchanged = Array.from(ctx.cfg.metadata).filter(
        (r) => !changed.has(r) && !changedList.some((cl) => r.startsWith(cl + "."))
    );
    if (unchanged.length > 0) lines.push("Registered but unchanged in git: " + capList(unchanged.map((r) => ctx.cfg.metadataNames.get(r) || r), 50));
    if (uncovered.length > 0) {
        return mk(id, "fail", uncovered.length + " of " + comps.length + " changed components not registered" + (uncovered.length <= 3 ? ": " + uncovered.join(", ") : ""), lines);
    }
    return mk(id, "pass", comps.length === 0 ? "No changed components found in git" : "All " + comps.length + " changed components registered", lines);
}

function guarded(id, ctx, fn) {
    try {
        return fn(ctx);
    } catch (e) {
        const msg = errMsg(e);
        ctx.problems.push(TITLES[id] + " could not run: " + msg);
        return mk(id, "skipped", "Check could not run: " + msg, []);
    }
}

// ---- result ----

function buildResult(cfg, status, notes, checks, cap) {
    const cut = checks.map((ch) => {
        const lines = ch.lines.slice(0, cap).map((l) => clip(l));
        if (ch.lines.length > cap) lines.push("(+" + (ch.lines.length - cap) + " more lines omitted)");
        return { id: ch.id, title: ch.title, status: ch.status, summary: clip(ch.summary), lines: lines };
    });
    const findingLines = cfg.findings.map((f) => (f.severity === "issue" ? "ISSUE: " : "INFO: ") + clip(f.message));
    const noteLines = notes.map((n) => "NOTE: " + clip(n));
    const text = status === "Failed" ? noteLines.concat(findingLines) : findingLines.concat(noteLines);
    cut.forEach((ch) => {
        text.push(ch.title + ": " + ch.status.toUpperCase() + " " + DASH + " " + ch.summary);
        ch.lines.forEach((l) => text.push("  " + l));
    });
    return { runId: cfg.runId, status: status, details: text.join("\n"), checks: cut, salesforceFindings: cfg.findings };
}

function finish(cfg, status, notes, checks) {
    const ordered = ORDER.map((id) => checks.find((c) => c.id === id)).filter(Boolean);
    let cap = 200;
    let json = JSON.stringify(buildResult(cfg, status, notes, ordered, cap));
    while (json.length > MAX_JSON && cap > 5) {
        cap = Math.floor(cap / 2);
        json = JSON.stringify(buildResult(cfg, status, notes, ordered, cap));
    }
    emit(json);
}

// Repository download. The checks read only commit history and changed file names, never file contents, so a "light" clone
// (no working tree, no file contents) is tried first: about a second even for a repository with tens of thousands of files,
// where a normal clone checks out every file and can take a minute or more. If the light clone is not possible, the standard
// "copado-git-get --depth" clone is used exactly as before.
function prepareRepository(cfg) {
    const home = process.cwd();
    let url = "";
    try {
        url = str(JSON.parse(env.git_json || "{}").url);
    } catch (e) {
        url = "";
    }
    // The url is placed inside a command string, so only plain URL characters are accepted.
    if (url && /^[A-Za-z0-9._~:\/?#@%+=,&-]+$/.test(url)) {
        try {
            const dir = fs.mkdtempSync(path.join(os.tmpdir(), "svg-"));
            const clone = "git clone --quiet --no-checkout --filter=blob:none --single-branch --depth " + cfg.depth +
                " --branch " + cfg.feature + ' "' + url + '" "' + dir + '"';
            gitG(clone, CLONE_TIMEOUT_MS);
            process.chdir(dir);
            console.log("Light clone ready (commit history only, no file contents).");
            return "light";
        } catch (e) {
            process.chdir(home);
            console.log("Light clone not possible, using the standard clone: " + errMsg(e));
        }
    }
    console.log(redact(run("copado-git-get", ["--depth", String(cfg.depth), cfg.feature], STANDARD_CLONE_TIMEOUT_MS)));
    return "standard";
}

function main() {
    collectSecrets();
    const cfg = readConfig();
    if (!cfg.feature || !isSafe(cfg.feature)) {
        return finish(cfg, "Failed", ["No usable feature branch name was provided."], skippedChecks("Not run: no feature branch"));
    }
    progress("Cloning repository" + ELL);
    try {
        prepareRepository(cfg);
    } catch (e) {
        const reason = "Could not clone the repository or check out " + cfg.feature + ": " + errMsg(e);
        return finish(cfg, "Failed", [reason], skippedChecks("Not run: repository could not be cloned"));
    }

    progress("Fetching base and environment branches" + ELL);
    const prepared = fetchBranchesForChecks(cfg);
    if (prepared.error) {
        return finish(cfg, "Failed", [prepared.error], skippedChecks("Not run: branches not available"));
    }
    const base = prepared.base;
    const envOk = prepared.envOk;
    const missing = prepared.missing;
    if (!ensureMergeBase(base, cfg)) {
        const reason = "origin/" + base + " and the feature branch share no common history within the fetched depth, so nothing was verified from git.";
        return finish(cfg, "Failed", [reason], skippedChecks("Skipped: no merge base with origin/" + base));
    }

    const ctx = { cfg: cfg, base: base, envOk: envOk, missing: missing, problems: [], isCovered: makeIsCovered(cfg.metadata, cfg.hasLabels) };
    const checks = [];
    progress("Checking org/environment branch merge" + ELL);
    const org = guarded("org-branch-merge", ctx, checkOrgMerge);
    console.log(org.title + ": " + org.status + " - " + org.summary);
    checks.push(org);
    if (org.status === "fail") {
        const why = "Skipped: environment branch merge detected";
        checks.push(mk("unregistered-commits", "skipped", why, []), mk("metadata-coverage", "skipped", why, []));
    } else {
        progress("Checking unregistered commits" + ELL);
        const unreg = guarded("unregistered-commits", ctx, checkUnregistered);
        console.log(unreg.title + ": " + unreg.status + " - " + unreg.summary);
        checks.push(unreg);
        progress("Checking metadata coverage" + ELL);
        const meta = guarded("metadata-coverage", ctx, checkMetadata);
        console.log(meta.title + ": " + meta.status + " - " + meta.summary);
        checks.push(meta);
    }
    const hasIssue = checks.some((c) => c.status === "fail") || cfg.findings.some((f) => f.severity === "issue");
    const status = ctx.problems.length > 0 ? "Failed" : hasIssue ? "Issues" : "Clean";
    return finish(cfg, status, ctx.problems, checks);
}

try {
    main();
} catch (err) {
    const msg = errMsg(err);
    console.log("Fatal: " + msg);
    emit(
        JSON.stringify({
            runId: str(env.runId),
            status: "Failed",
            details: "Fatal: " + msg,
            checks: skippedChecks("Not run: " + msg),
            salesforceFindings: []
        })
    );
    process.exit(1);
}
