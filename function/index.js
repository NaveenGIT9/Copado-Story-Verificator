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
    "org-branch-merge": "External branch merge"
};
const ORDER = ["unregistered-commits", "metadata-coverage", "org-branch-merge"];
const secrets = [];
let verifiedHead = ""; // the feature-branch commit the checks ran against; the gate compares it with later pushes

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
    const text = redact((e && e.stderr ? str(e.stderr).trim() : "") || (e && e.message) || str(e));
    // A traceback names the real reason on its last lines, so keep the end of it, not the start.
    if (/Traceback \(most recent call last\)/.test(text)) {
        const tail = text.split("\n").map((l) => l.trim()).filter(Boolean).slice(-2).join(" | ");
        return clip(tail.replace(/\s+/g, " "), 400);
    }
    const flat = text.replace(/\s+/g, " ");
    // Copado's git wrapper prints progress lines first and the actual git error last, so a long message keeps its end.
    return flat.length > 400 ? ELL + flat.slice(-399) : flat;
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
// "CustomField" -> "Custom Field"; an item without a recorded type goes under "Other".
function typeLabel(type) {
    const t = str(type).trim();
    return t ? t.replace(/([a-z])([A-Z])/g, "$1 $2") : "Other";
}

// [{ name, label }] -> groups by metadata type, sorted by type (untyped "Other" last) and by name.
function groupByType(items) {
    const byType = new Map();
    items.forEach((it) => {
        if (!byType.has(it.label)) byType.set(it.label, []);
        byType.get(it.label).push(it.name);
    });
    return Array.from(byType.entries())
        .sort((x, y) => (x[0] === "Other" ? 1 : y[0] === "Other" ? -1 : x[0].localeCompare(y[0])))
        .map((e) => ({ type: e[0], items: e[1].sort((x, y) => x.toLowerCase().localeCompare(y.toLowerCase())) }));
}

// Keeps at most "limit" names over all groups (in order) and drops groups that end up empty.
function capGroups(groups, limit) {
    let left = limit;
    const out = [];
    groups.forEach((g) => {
        const items = g.items.slice(0, Math.max(0, left));
        left -= items.length;
        if (items.length > 0) out.push(Object.assign({}, g, { items: items }));
    });
    return out;
}

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

// The folder a file lives in tells its metadata type; anything not listed is shown by its folder name ("quickActions" -> "Quick Actions").
// The Copado metadata type of each folder (a "kind"), the same table Apex uses to create the records. A kind that is not listed has
// no type here, and a changed component of that kind is matched by its name alone.
const KIND_TYPES = {
    classes: "ApexClass", triggers: "ApexTrigger", pages: "ApexPage", components: "ApexComponent", lwc: "LightningComponentBundle",
    aura: "AuraDefinitionBundle", flows: "Flow", layouts: "Layout", permissionsets: "PermissionSet", permissionsetgroups: "PermissionSetGroup",
    profiles: "Profile", flexipages: "FlexiPage", customMetadata: "CustomMetadata", customPermissions: "CustomPermission", email: "EmailTemplate",
    approvalProcesses: "ApprovalProcess", quickActions: "QuickAction", tabs: "CustomTab", applications: "CustomApplication", reports: "Report",
    reportTypes: "ReportType", dashboards: "Dashboard", staticresources: "StaticResource", duplicateRules: "DuplicateRule", matchingRules: "MatchingRule",
    globalValueSets: "GlobalValueSet", labels: "CustomLabel", workflows: "Workflow", "workflows/alerts": "WorkflowAlert",
    "workflows/fieldUpdates": "WorkflowFieldUpdate", "workflows/rules": "WorkflowRule", "workflows/tasks": "WorkflowTask",
    "workflows/outboundMessages": "WorkflowOutboundMessage", "workflows/knowledgePublishes": "WorkflowKnowledgePublish",
    "workflows/flowActions": "WorkflowFlowAutomation", "workflows/send": "WorkflowSend", objects: "CustomObject", "objects/fields": "CustomField", "objects/validationRules": "ValidationRule",
    "objects/recordTypes": "RecordType", "objects/listViews": "ListView", "objects/fieldSets": "FieldSet", "objects/webLinks": "WebLink",
    "objects/compactLayouts": "CompactLayout", "objects/businessProcesses": "BusinessProcess"
};

// Other types Copado records for the same folder (a report folder file is a ReportFolder, not a Report): also the same component.
const KIND_ALIASES = {
    matchingRules: ["MatchingRules"], dashboards: ["DashboardFolder"], reports: ["ReportFolder"], email: ["EmailFolder"], flows: ["FlowDefinition"]
};

// Is this registered item the changed component? The exact same name (ignoring case) and, when both sides have a type, the same type.
function sameComponent(item, api, kind) {
    const type = KIND_TYPES[kind];
    if (item.name.toLowerCase() !== api.toLowerCase()) return false;
    if (!type || !item.type) return true;
    return [type].concat(KIND_ALIASES[kind] || []).some((t) => t.toLowerCase() === item.type.toLowerCase());
}

const FOLDER_TYPES = {
    labels: "Custom Label", matchingRules: "Matching Rule", workflows: "Workflow", classes: "Apex Class", triggers: "Apex Trigger", pages: "Visualforce Page", lwc: "Lightning Web Component", aura: "Aura Component",
    flows: "Flow", permissionsets: "Permission Set", duplicateRules: "Duplicate Rule", fields: "Custom Field", validationRules: "Validation Rule"
};

function folderType(folder) {
    const t = str(folder).replace(/([a-z])([A-Z])/g, "$1 $2");
    return FOLDER_TYPES[folder] || t.charAt(0).toUpperCase() + t.slice(1);
}

// The same component as parseApiName, plus its metadata type: { api, type }.
function parseComponent(filePath) {
    const api = parseApiName(filePath);
    if (!api) return null;
    const parts = filePath.replace(/\\/g, "/").split("/");
    const at = parts.indexOf("default");
    if (parts[at + 1] === "objects") {
        const member = parts.length >= at + 5;
        return { api: api, kind: member ? "objects/" + parts[at + 3] : "objects", type: member ? folderType(parts[at + 3]) : "Custom Object" };
    }
    return { api: api, kind: parts[at + 1], type: folderType(parts[at + 1]) };
}

// "git diff --name-status -z" -> [{ status: "A" | "M" | "D" ..., path }]
function parseNameStatus(raw) {
    const tokens = raw.split("\0").filter(Boolean);
    const out = [];
    for (let i = 0; i + 1 < tokens.length; i += 2) out.push({ status: tokens[i].charAt(0), path: tokens[i + 1] });
    return out;
}

// The changed components with their files: { api, kind, type, files: [{ status, path }] }
function componentsFromChanges(changes) {
    const seen = new Map();
    changes.forEach((ch) => {
        const c = parseComponent(ch.path);
        if (!c) return;
        if (!seen.has(c.api)) seen.set(c.api, { api: c.api, kind: c.kind, type: c.type, files: [] });
        seen.get(c.api).files.push({ status: ch.status, path: ch.path });
    });
    return Array.from(seen.values());
}

// Is anything of a component whose changed files were all deleted still in the final version of the branch? Its other file
// (a class and its -meta.xml), or for a bundle anything left in its folder.
function stillThere(c) {
    return c.files.some((f) => {
        const parts = f.path.split("/");
        if (c.kind === "lwc" || c.kind === "aura") {
            const out = tryRun("git", ["ls-tree", "--name-only", "HEAD", parts.slice(0, parts.indexOf("default") + 3).join("/") + "/"]);
            return out !== null && out.trim() !== "";
        }
        const other = /-meta\.xml$/.test(f.path) ? f.path.replace(/-meta\.xml$/, "") : f.path + "-meta.xml";
        return tryRun("git", ["cat-file", "-e", "HEAD:" + other]) !== null;
    });
}

// A component that is gone from the final version of the branch (every one of its files deleted, nothing left) is a Delete;
// anything else, even with some files removed, is an Add.
function actionOf(c) {
    if (c.action) return c.action;
    if (c.files.length === 0 || !c.files.every((f) => f.status === "D")) return "Add";
    return stillThere(c) ? "Add" : "Delete";
}

// The file that stands for the component: its main file, not the -meta.xml; for a bundle the file named like it.
function primaryPath(c) {
    const paths = c.files.map((f) => f.path);
    const main = c.kind === "lwc" ? c.api + ".js" : c.kind === "aura" ? c.api + ".cmp" : null;
    return paths.find((p) => main && p.endsWith("/" + main)) || paths.find((p) => !/-meta\.xml$/.test(p)) || paths[0];
}

// path -> time of the latest commit on the feature branch that touched it (ISO text), one git call for everything.
function commitTimes(base) {
    const out = tryRun("git", ["log", "--no-renames", "--name-only", "--format=%x01%cI", "origin/" + base + "..HEAD"]);
    const times = new Map();
    if (out === null) return times;
    out.split("\u0001").forEach((chunk) => {
        const lines = chunk.split("\n").map((l) => l.trim()).filter(Boolean);
        if (lines.length === 0) return;
        lines.slice(1).forEach((p) => {
            if (!times.has(p)) times.set(p, lines[0]);
        });
    });
    return times;
}

function latestTime(c, times) {
    let best = "";
    c.files.forEach((f) => {
        const t = times.get(f.path);
        if (t && (best === "" || Date.parse(t) > Date.parse(best))) best = t;
    });
    return best;
}

// Unique components of a list of git file paths: { api, type }.
function componentsOf(paths) {
    const seen = new Map();
    paths.forEach((p) => {
        const c = parseComponent(p);
        if (c && !seen.has(c.api)) seen.set(c.api, c);
    });
    return Array.from(seen.values());
}

// A changed component is registered only by an item of the same type with exactly its name. Nothing registered under a related
// name stands in for it: not an object's fields for the object, not a class for a trigger of the same name.
function makeIsCovered(items, hasLabels) {
    return (c, kind) =>
        items.some((it) => sameComponent(it, c, kind)) ||
        // The whole labels file registered as "CustomLabels" covers every label in it.
        (kind === "labels" && items.some((it) => it.name.toLowerCase() === "customlabels")) ||
        (c.toLowerCase() === "customlabels" && hasLabels);
}

// The labels file holds every custom label, so a change to it is a change to some labels. Which ones is read from the file: its
// <labels> blocks on the base branch and on the feature branch, matched by <fullName>. Returns [{ name, action }] (a new or changed
// label is an Add, a label that is no longer in the file a Delete), or null when the file cannot be read (then the file itself
// stays one component).
function changedLabels(base, file) {
    const gone = file.status === "D";
    const added = file.status === "A";
    const before = added ? "" : tryRun("git", ["show", baseRef(base) + ":" + file.path]);
    const after = gone ? "" : tryRun("git", ["show", "HEAD:" + file.path]);
    if (before === null || after === null) return null;
    const blocks = (text) => {
        const map = new Map();
        (text.match(/<labels>[\s\S]*?<\/labels>/g) || []).forEach((block) => {
            const m = /<fullName>([^<]+)<\/fullName>/.exec(block);
            if (m) map.set(m[1].trim(), block.replace(/\s+/g, " ").trim());
        });
        return map;
    };
    const old = blocks(before);
    const now = blocks(after);
    const out = [];
    now.forEach((block, name) => {
        if (!old.has(name) || old.get(name) !== block) out.push({ name: name, action: "Add" });
    });
    old.forEach((block, name) => {
        if (!now.has(name)) out.push({ name: name, action: "Delete" });
    });
    return out;
}

// Where the feature branch split off the base branch. The labels and the workflow parts of the base branch are read from there, not
// from the base branch's latest commit: a label or rule that the base branch gained after the split is not in the feature branch,
// but it was not removed by it either. So a part is a Delete only when it was in the file at the split and the feature branch's own
// commits took it out. Falls back to the base branch tip when the common ancestor cannot be found (a very shallow clone).
function baseRef(base) {
    const mb = tryRun("git", ["merge-base", "origin/" + base, "HEAD"]);
    return mb && mb.trim() ? mb.trim() : "origin/" + base;
}

// The <labels> blocks of a file, keyed by <fullName>, each as one normalised string.
function blocksOf(text, tag) {
    const map = new Map();
    (text.match(new RegExp("<" + tag + ">[\\s\\S]*?</" + tag + ">", "g")) || []).forEach((block) => {
        const m = /<fullName>([^<]+)<\/fullName>/.exec(block);
        if (m) map.set(m[1].trim(), block.replace(/\s+/g, " ").trim());
    });
    return map;
}

// The parts of a workflow file: XML tag -> [kind, label shown in the popup]. The Copado type of each kind is in KIND_TYPES.
const WORKFLOW_PARTS = {
    rules: ["workflows/rules", "Workflow Rule"],
    alerts: ["workflows/alerts", "Workflow Alert"],
    fieldUpdates: ["workflows/fieldUpdates", "Workflow Field Update"],
    tasks: ["workflows/tasks", "Workflow Task"],
    outboundMessages: ["workflows/outboundMessages", "Workflow Outbound Message"],
    knowledgePublishes: ["workflows/knowledgePublishes", "Workflow Knowledge Publish"],
    flowActions: ["workflows/flowActions", "Workflow Flow Action"],
    send: ["workflows/send", "Workflow Send"]
};

// A workflow file holds every rule and action of one object. Like the labels, the parts that changed are read from the file: the base
// branch against the FINAL version on the feature branch (HEAD), matched by <fullName> (kept as written in the file, so URL-encoded,
// which is how Copado records them). A part is a Delete only when it is not in that final version, so a part removed in one commit and
// put back in a later one is not a Delete. Each part is named <Object>.<fullName>; a Workflow record named <Object> comes with them,
// because the deployment of a rule or an action needs it. Returns null when the file cannot be read (it then stays one component).
function changedWorkflowParts(base, file, objectName) {
    const gone = file.status === "D";
    const added = file.status === "A";
    const before = added ? "" : tryRun("git", ["show", baseRef(base) + ":" + file.path]);
    const after = gone ? "" : tryRun("git", ["show", "HEAD:" + file.path]);
    if (before === null || after === null) return null;
    const out = [];
    Object.keys(WORKFLOW_PARTS).forEach((tag) => {
        const old = blocksOf(before, tag);
        const now = blocksOf(after, tag);
        now.forEach((block, name) => {
            if (!old.has(name) || old.get(name) !== block) out.push({ api: objectName + "." + name, kind: WORKFLOW_PARTS[tag][0], type: WORKFLOW_PARTS[tag][1], action: "Add" });
        });
        old.forEach((block, name) => {
            if (!now.has(name)) out.push({ api: objectName + "." + name, kind: WORKFLOW_PARTS[tag][0], type: WORKFLOW_PARTS[tag][1], action: "Delete" });
        });
    });
    return out;
}

// Each changed workflow file becomes its changed parts plus the Workflow record of the object (a Delete only when the file is gone).
function expandWorkflows(comps, base) {
    const out = [];
    comps.forEach((c) => {
        const parts = c.kind === "workflows" && c.files.length > 0 ? changedWorkflowParts(base, c.files[0], c.api) : null;
        if (parts === null) {
            out.push(c);
            return;
        }
        const path = c.files[0].path;
        parts.forEach((p) => out.push(Object.assign({}, p, { files: [{ status: p.action === "Delete" ? "D" : "A", path: path }] })));
        if (parts.length > 0) {
            const fileGone = c.files[0].status === "D";
            out.push({ api: c.api, kind: "workflows", type: c.type, action: fileGone ? "Delete" : "Add", files: [{ status: fileGone ? "D" : "A", path: path }] });
        }
    });
    return out;
}

// The matching rules file of an object holds one <matchingRules> block per rule. Like the labels, each changed rule is one component,
// named <Object>.<fullName> (the file is named after the object), compared with the file at the split from the base branch and with the
// final version on the feature branch. There is no parent record: the rules alone are registered. Returns null when the file cannot
// be read (it then stays one component).
function changedMatchingRules(base, file, objectName) {
    const gone = file.status === "D";
    const added = file.status === "A";
    const before = added ? "" : tryRun("git", ["show", baseRef(base) + ":" + file.path]);
    const after = gone ? "" : tryRun("git", ["show", "HEAD:" + file.path]);
    if (before === null || after === null) return null;
    const old = blocksOf(before, "matchingRules");
    const now = blocksOf(after, "matchingRules");
    const out = [];
    now.forEach((block, name) => {
        if (!old.has(name) || old.get(name) !== block) out.push({ name: objectName + "." + name, action: "Add" });
    });
    old.forEach((block, name) => {
        if (!now.has(name)) out.push({ name: objectName + "." + name, action: "Delete" });
    });
    return out;
}

function expandMatchingRules(comps, base) {
    const out = [];
    comps.forEach((c) => {
        const rules = c.kind === "matchingRules" && c.files.length > 0 ? changedMatchingRules(base, c.files[0], c.api) : null;
        if (rules === null) {
            out.push(c);
            return;
        }
        rules.forEach((r) => out.push({ api: r.name, kind: "matchingRules", type: c.type, action: r.action, files: [{ status: r.action === "Delete" ? "D" : "A", path: c.files[0].path }] }));
    });
    return out;
}

// Each changed component as it is, except the labels file, which becomes one component per changed label.
function expandLabels(comps, base) {
    const out = [];
    comps.forEach((c) => {
        const labels = c.kind === "labels" && c.files.length > 0 ? changedLabels(base, c.files[0]) : null;
        if (labels === null) {
            out.push(c);
            return;
        }
        labels.forEach((l) => out.push({ api: l.name, kind: "labels", type: c.type, action: l.action, files: [{ status: l.action === "Delete" ? "D" : "A", path: c.files[0].path }] }));
    });
    return out;
}

// rows (optional): structured detail rows for the popup (coloured parts, collapsible lists); lines stay as the plain-text version.
function mk(id, status, summary, lines, rows) {
    return { id: id, title: TITLES[id], status: status, summary: summary, lines: lines, rows: rows || [] };
}

function skippedChecks(reason) {
    return ORDER.map((id) => mk(id, "skipped", reason, []));
}

function readConfig() {
    const storyName = str(env.storyName);
    // Registered metadata arrives as "Type|Name" ("Name" alone when the type is unknown): unique per type and name, exact spelling kept.
    const metadata = [];
    const seenMetadata = new Set();
    parseList(env.registeredMetadataJson).forEach((entry) => {
        const text = str(entry).trim();
        const bar = text.indexOf("|");
        const type = bar > 0 ? text.slice(0, bar).trim() : "";
        const name = (bar > 0 ? text.slice(bar + 1) : text).trim();
        const key = type.toLowerCase() + "|" + name.toLowerCase();
        if (name && !seenMetadata.has(key)) {
            seenMetadata.add(key);
            metadata.push({ name: name, type: type });
        }
    });
    const depth = parseInt(env.gitDepth, 10);
    const envBranches = new Map();
    parseList(env.envBranchesJson).forEach((b) => {
        const n = str(b).trim();
        if (n && !envBranches.has(n.toLowerCase())) envBranches.set(n.toLowerCase(), n);
    });
    // A finding is info, a warning or an issue; "noCommits" marks the pull request finding of a story that has no commits or
    // metadata, and "nothing" that it has no deployment steps either.
    const findings = parseList(env.findings).map((f) =>
        f !== null && typeof f === "object"
            ? {
                  severity: f.severity === "issue" || f.severity === "warn" ? f.severity : "info",
                  message: str(f.message),
                  group: str(f.group),
                  noCommits: f.noCommits === true || f.noCommits === "true",
                  nothing: f.nothing === true || f.nothing === "true",
                  // The parts of a parent story finding, passed back untouched for the popup.
                  kind: str(f.kind),
                  parentId: str(f.parentId),
                  parentName: str(f.parentName),
                  via: str(f.via),
                  parentEnv: str(f.parentEnv),
                  childEnv: str(f.childEnv)
              }
            : { severity: "info", message: str(f), group: "", noCommits: false, nothing: false }
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
        metadata: metadata, // [{ name, type }]
        hasLabels: str(env.hasCustomLabelMetadata).toLowerCase() === "true",
        findings: findings,
        noWork: findings.some((f) => f.noCommits)
    };
}

// ---- git preparation ----

function hasRef(ref) {
    return tryRun("git", ["rev-parse", "--verify", "--quiet", ref + "^{commit}"]) !== null;
}

// Every copado-git-get call costs seconds (a failing one far more), so the remote branches are listed once and only the
// existing ones are fetched, in one command. A failed listing is retried once and then the run stops with the real reason:
// trying branch after branch would turn a connection hiccup into minutes of failing calls.
let remoteListing = null; // the branch list read by checkFeatureBranch, reused when the checks fetch their branches

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

// Asks the remote whether the feature branch exists, before anything is cloned: an empty repository in a temporary folder is
// enough for the credentialed "git ls-remote" of copado-git-get. true / false, or null when the remote could not be asked
// (the normal clone then decides, as before).
function checkFeatureBranch(cfg) {
    const home = process.cwd();
    try {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "svb-"));
        process.chdir(dir);
        run("git", ["init", "--quiet"]);
        const listing = listRemoteBranches();
        process.chdir(home);
        if (!listing.names) return null;
        remoteListing = listing;
        return listing.names.has(cfg.feature);
    } catch (e) {
        try {
            process.chdir(home);
        } catch (ignored) {
        }
        console.log("Could not check the feature branch: " + errMsg(e));
        return null;
    }
}

// A story with no commits or metadata: its pull request finding becomes a warning when the feature branch exists, and
// "Nothing to promote" (a warning) when there is nothing at all (no deployment steps and no branch); otherwise it stays "No commits".
function adjustNoCommitsFinding(cfg, branchExists) {
    cfg.findings.forEach((f) => {
        if (!f.noCommits || branchExists === null) return;
        if (branchExists) {
            f.severity = "warn";
            f.message = "No commits";
        } else if (f.nothing) {
            f.severity = "warn";
            f.message = "Nothing to promote";
        }
    });
}

// What the three git checks say when the feature branch does not exist. A story with commits or metadata registered on it must
// have a branch, so that fails (and the others cannot run); a story with only deployment steps simply has nothing in Git.
function noBranchChecks(cfg) {
    if (!cfg.noWork) {
        const why = "Not run: no feature branch";
        return [
            mk("unregistered-commits", "fail", "No feature branch (" + cfg.feature + " not found in Git)", []),
            mk("metadata-coverage", "skipped", why, []),
            mk("org-branch-merge", "skipped", why, [])
        ];
    }
    return ORDER.map((id) => mk(id, "pass", "No feature branch", []));
}

function verdictOf(cfg, checks, problems) {
    const hasIssue = checks.some((c) => c.status === "fail") || cfg.findings.some((f) => f.severity === "issue");
    return problems.length > 0 ? "Failed" : hasIssue ? "Issues" : "Clean";
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
    const listing = remoteListing || listRemoteBranches();
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

// The branch a merge commit brought in, read from its message: "Merge branch 'x'", "Merge remote-tracking branch 'origin/x'" and
// GitHub's "Merge pull request #12 from org/x". null when the message does not name it.
const MERGE_SUBJECTS = [/^Merge (?:remote-tracking )?branch '(?:origin\/)?([^']+)'/i, /^Merge pull request #\d+ from [^/\s]+\/(\S+)/i];

function mergedBranchName(subject) {
    for (let i = 0; i < MERGE_SUBJECTS.length; i++) {
        const m = MERGE_SUBJECTS[i].exec(subject);
        if (m) return m[1].trim();
    }
    return null;
}

const MERGE_KINDS = {
    env: "environment branch",
    promotion: "promotion branch",
    feature: "feature branch",
    base: "base branch",
    other: "other branch",
    unknown: "branch not named in the merge message"
};

function classifyMerge(name, ctx) {
    if (name === null) return "unknown";
    const lower = name.toLowerCase();
    if (lower === ctx.cfg.feature.toLowerCase()) return "own";
    if (lower === ctx.base.toLowerCase()) return "base";
    if (ctx.cfg.envBranches.has(lower)) return "env";
    if (/^promotion\//i.test(name)) return "promotion";
    if (/^feature\//i.test(name)) return "feature";
    return "other";
}

// Every branch merged into the feature branch since it left the base branch is reported, except the feature branch itself (a story
// branch merged into its own copy is normal). An environment, promotion or other feature branch merged in is a failure: its commits
// are not this story's. Merging the base branch is only a warning (a catch-up). The branch is read from the merge message; when the
// message does not name it, an environment branch holding the merged commits is still recognised, otherwise it is "not named".
function checkOrgMerge(ctx) {
    const id = "org-branch-merge";
    const cfg = ctx.cfg;
    const notes = ctx.missing.length ? ["Not on the remote, so not compared: " + ctx.missing.join(", ")] : [];
    const raw = run("git", ["log", "--first-parent", "--format=%H%x00%P%x00%s%x00%an", "origin/" + ctx.base + "..HEAD"]);
    const rows = raw
        .split("\n")
        .filter((l) => l.indexOf("\0") >= 0)
        .map((l) => {
            const p = l.split("\0");
            return { sha: p[0].trim(), parents: str(p[1]).trim().split(/\s+/).filter(Boolean), subject: str(p[2]), author: str(p[3]) };
        })
        .filter((r) => r.sha.length >= 40);
    const found = [];
    rows.forEach((r) => {
        if (r.parents.length < 2) return;
        let name = mergedBranchName(r.subject);
        if (name === null) {
            const entries = Array.from(ctx.envOk.entries());
            for (let j = 0; j < entries.length; j++) {
                if (isAncestor(r.parents[1], "origin/" + entries[j][1]) && !isAncestor(r.parents[1], "origin/" + ctx.base)) {
                    name = entries[j][1];
                    break;
                }
            }
        }
        const kind = classifyMerge(name, ctx);
        if (kind === "own") return;
        found.push({ sha: r.sha.slice(0, 10), full: r.sha, author: r.author, subject: r.subject, branch: name, kind: kind });
    });
    if (found.length > 0) {
        const named = (f) => (f.branch === null ? "A branch" : f.branch);
        const blocking = found.some((f) => f.kind !== "base");
        // One merge: everything is in the summary (no repeated detail line). Several: the summary counts them, the lines list each.
        const summary =
            found.length === 1
                ? named(found[0]) + " (" + MERGE_KINDS[found[0].kind] + ") merged into the feature branch"
                : found.length + " branch merges: " + uniq(found.map((f) => named(f))).join(", ");
        const lines = (found.length === 1 ? [] : found.map((f) => named(f) + " " + DASH + " " + MERGE_KINDS[f.kind] + " " + DASH + " commit " + f.sha)).concat(notes);
        // The merge commits are listed as commit rows (the id links to the commit on GitHub, like the unregistered commits).
        const commitRows = found.map((f) => ({
            t: "commit",
            sha: f.sha,
            full: f.full,
            author: f.author || "unknown",
            subject: f.subject,
            note: found.length === 1 ? "" : named(f) + " (" + MERGE_KINDS[f.kind] + ")"
        }));
        return mk(id, blocking ? "fail" : "warn", summary, lines, commitRows);
    }
    return mk(id, "pass", "None", notes);
}

// Author emails (lower case) of the registered commits that exist in the local history; unknown or abbreviated-ambiguous ids are skipped.
function registeredAuthorEmails(shas) {
    const known = shas
        .filter((s) => /^[0-9a-f]{7,40}$/.test(s))
        .slice(0, 200)
        .filter((s) => tryRun("git", ["cat-file", "-e", s + "^{commit}"]) !== null);
    if (known.length === 0) return [];
    const out = tryRun("git", ["log", "--no-walk", "--format=%ae"].concat(known));
    return out === null ? [] : out.split("\n").map((l) => l.trim().toLowerCase()).filter(Boolean);
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
        if (cfg.noWork) return mk(id, "warn", "No commits on the story, but the feature branch exists in Git", []);
        return mk(id, "fail", "No commits beyond " + ctx.base + " " + DASH + " nothing to promote", []);
    }
    const regSet = new Set(cfg.registered);
    const isReg = (sha) => {
        const s = sha.toLowerCase();
        return regSet.has(s) || cfg.registered.some((r) => r.length >= 7 && (r.startsWith(s) || s.startsWith(r)));
    };
    // "Registered committer" = an author email on any commit registered for this story. Registered commits that are already in
    // the base branch are not in base..HEAD, so their authors are read straight from the registered commit ids too.
    const regEmails = new Set(extra.filter((c) => isReg(c.sha) && c.email).map((c) => c.email));
    registeredAuthorEmails(cfg.registered).forEach((e) => regEmails.add(e));
    const unreg = extra.filter((c) => !isReg(c.sha));
    const analysed = unreg.slice(0, MAX_ANALYSE);
    const details = analysed.map((c) => {
        const out = tryRun("git", ["diff-tree", "--no-commit-id", "-r", "--name-only", "--no-renames", "-z", c.sha]);
        const comps = componentsOf(out === null ? [] : out.split("\0").filter(Boolean));
        const sl = c.sha.toLowerCase();
        const nc = cfg.nonComplete.find((n) => n.sha.length >= 7 && (sl.startsWith(n.sha) || n.sha.startsWith(sl)));
        return {
            sha10: c.sha.slice(0, 10),
            fullSha: c.sha,
            author: c.name || c.email || "unknown",
            email: c.email,
            subject: c.subject,
            auto: AUTO_PREFIXES.some((p) => c.subject.startsWith(p)),
            status: nc ? nc.status : null,
            uncovered: comps.filter((x) => !ctx.isCovered(x.api, x.kind)).map((x) => x.api)
        };
    });
    const lines = details.slice(0, 50).map((d) => {
        let line = d.sha10 + " " + d.author + " \"" + d.subject + "\"";
        if (d.uncovered.length > 0) line += " " + DASH + " uncovered: " + capList(d.uncovered, 30);
        if (d.auto) line += " (Copado auto-commit, exempt)";
        if (d.status) line += " [Copado status: " + d.status + "]";
        return line;
    });
    // One structured row per commit so the popup can colour the id, the author, the message and the component names apart.
    const rows = details.slice(0, 50).map((d) => ({
        t: "commit",
        sha: d.sha10,
        full: d.fullSha,
        author: d.author,
        subject: d.subject,
        note: d.auto ? "Copado auto-commit, exempt" : d.status ? "Copado status: " + d.status : ""
    }));
    if (details.length > 50) {
        lines.push("+" + (details.length - 50) + " more");
        rows.push({ t: "text", text: "+" + (details.length - 50) + " more" });
    }
    if (unreg.length > analysed.length) {
        const cutOff = "Only the first " + analysed.length + " of " + unreg.length + " commits were analysed.";
        lines.push(cutOff);
        rows.push({ t: "text", text: cutOff });
        return mk(id, "fail", unreg.length + " commits outside Copado " + DASH + " too many to analyse", lines, rows);
    }
    const effective = details.filter((d) => !d.auto);
    const hard = details.filter((d) => d.status && d.status.toLowerCase() !== "failed");
    const uncoveredCommits = effective.filter((d) => d.uncovered.length > 0);
    const authors = uniq(effective.filter((d) => d.email && !regEmails.has(d.email)).map((d) => d.author));
    if (effective.length === 0) {
        const note = unreg.length === 0 ? "all registered" : unreg.length + " Copado auto-commit(s) exempt, rest registered";
        return mk(id, "pass", extra.length + " commit(s), " + note, lines, rows);
    }
    if (hard.length > 0) {
        return mk(id, "fail", "Commit " + hard[0].sha10 + " has Copado status \"" + hard[0].status + "\"", lines, rows);
    }
    if (uncoveredCommits.length > 0) {
        // The list shows every unregistered commit, so the headline counts them all and then says how many change unregistered components.
        const listed = details.length;
        return mk(
            id,
            "fail",
            uncoveredCommits.length === listed
                ? listed + " commit(s) outside Copado change unregistered components"
                : listed + " commit(s) outside Copado, " + uncoveredCommits.length + " of them change unregistered components",
            lines,
            rows
        );
    }
    if (authors.length > 0) {
        return mk(id, "fail", "Commit by " + authors.join(", ") + " is not a registered committer " + DASH + " verify manually", lines, rows);
    }
    return mk(
        id,
        "warn",
        effective.length + " commit(s) outside Copado; components registered, same author",
        lines,
        rows
    );
}

function checkMetadata(ctx) {
    const id = "metadata-coverage";
    let raw = tryRun("git", ["diff", "--name-status", "--no-renames", "-z", "origin/" + ctx.base + "...HEAD"]);
    if (raw === null) raw = tryRun("git", ["diff", "--name-status", "--no-renames", "-z", "origin/" + ctx.base + "..HEAD"]);
    if (raw === null) throw new Error("git diff against origin/" + ctx.base + " failed");
    const comps = expandMatchingRules(expandWorkflows(expandLabels(componentsFromChanges(parseNameStatus(raw)), ctx.base), ctx.base), ctx.base);
    const uncoveredComps = comps.filter((c) => !ctx.isCovered(c.api, c.kind));
    const uncovered = uncoveredComps.map((c) => c.api);
    const WONT_DEPLOY = "Their changes won't deploy to target - add them to the story in Copado.";
    const lines = [];
    const rows = [];
    if (uncovered.length > 0) {
        // In the popup the names are a collapsible group per metadata type (closed until clicked); the warning sentence is a "danger" row.
        lines.push("Not registered: " + capList(uncovered, 100));
        lines.push(WONT_DEPLOY);
        // A selectable row: each component with the action it needs in Copado (Add, or Delete when it is gone from the branch),
        // its main file and the time of its latest commit, so the popup can offer to register the ones the user picks.
        const times = commitTimes(ctx.base);
        const byKind = new Map();
        uncoveredComps.forEach((c) => {
            if (!byKind.has(c.kind)) byKind.set(c.kind, { kind: c.kind, type: c.type, items: [] });
            byKind.get(c.kind).items.push({ name: c.api, action: actionOf(c), date: latestTime(c, times), path: primaryPath(c) });
        });
        const selectGroups = Array.from(byKind.values())
            .sort((x, y) => (x.type === "Other" ? 1 : y.type === "Other" ? -1 : x.type.localeCompare(y.type)))
            .map((g) => Object.assign({}, g, { items: g.items.sort((x, y) => x.name.toLowerCase().localeCompare(y.name.toLowerCase())) }));
        rows.push({ t: "select", label: "Not registered", count: uncovered.length, groups: capGroups(selectGroups, 100) });
        rows.push({ t: "danger", text: WONT_DEPLOY });
    }
    // Registered items that are not one of the changed components (same type and exact name): related components are not hidden.
    const unchanged = ctx.cfg.metadata.filter((it) => !comps.some((c) => sameComponent(it, c.api, c.kind)));
    if (unchanged.length > 0) {
        const groups = groupByType(unchanged.map((it) => ({ name: it.name, label: typeLabel(it.type) })));
        const allNames = [].concat.apply([], groups.map((g) => g.items));
        lines.push("Registered but unchanged in git (" + allNames.length + "): " + capList(allNames, 50));
        // A collapsible row in the popup: the count, then the components under their metadata type, one per line, when opened.
        rows.push({ t: "group", label: "Registered but unchanged in git", count: allNames.length, groups: capGroups(groups, 500) });
    }
    if (uncovered.length > 0) {
        return mk(id, "fail", uncovered.length + " of " + comps.length + " changed components not registered under story metadata", lines, rows);
    }
    return mk(id, "pass", comps.length === 0 ? "No changed components found in git" : "All " + comps.length + " changed components registered", lines, rows);
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
        const rows = (ch.rows || []).slice(0, cap).map((r) => (r.t === "group" || r.t === "select" ? Object.assign({}, r, { groups: capGroups(r.groups, cap * 5) }) : r));
        return { id: ch.id, title: ch.title, status: ch.status, summary: clip(ch.summary), lines: lines, rows: rows };
    });
    const findingLines = cfg.findings.map((f) => (f.severity === "issue" ? "ISSUE: " : f.severity === "warn" ? "WARN: " : "INFO: ") + clip(f.message));
    const noteLines = notes.map((n) => "NOTE: " + clip(n));
    const text = status === "Failed" ? noteLines.concat(findingLines) : findingLines.concat(noteLines);
    cut.forEach((ch) => {
        text.push(ch.title + ": " + ch.status.toUpperCase() + " " + DASH + " " + ch.summary);
        ch.lines.forEach((l) => text.push("  " + l));
    });
    // scriptSeconds: how long this script ran, so the popup can tell Copado's queue time from the checks' own time.
    return { runId: cfg.runId, status: status, details: text.join("\n"), checks: cut, salesforceFindings: cfg.findings, scriptSeconds: Math.round((Date.now() - startedAt) / 1000), headSha: verifiedHead };
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
            // The Copado wrapper can report success without having cloned anything, so check that the folder holds a repository
            // with the feature branch checked out as HEAD before relying on it.
            process.chdir(dir);
            if (!fs.existsSync(".git") || tryRun("git", ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) === null) {
                throw new Error("the light clone reported success but left no repository in " + dir);
            }
            console.log("Light clone ready (commit history only, no file contents).");
            return "light";
        } catch (e) {
            process.chdir(home);
            console.log("Light clone not possible, using the standard clone: " + errMsg(e));
        }
    }
    console.log(redact(run("copado-git-get", ["--depth", String(cfg.depth), cfg.feature], STANDARD_CLONE_TIMEOUT_MS)));
    enterClonedRepository();
    return "standard";
}

// Depending on how the repository is connected, the standard clone may land in a sub-folder of the working directory instead of
// the working directory itself. Every later git command runs in the current directory, so move into the folder that holds .git.
function enterClonedRepository() {
    if (fs.existsSync(".git")) return;
    const here = process.cwd();
    let entries = [];
    try {
        entries = fs.readdirSync(here);
    } catch (e) {
        entries = [];
    }
    const found = entries.find((n) => {
        try {
            return fs.statSync(path.join(here, n)).isDirectory() && fs.existsSync(path.join(here, n, ".git"));
        } catch (e) {
            return false;
        }
    });
    if (found) {
        process.chdir(path.join(here, found));
        console.log("The clone is in the sub-folder " + found + "; working there.");
        return;
    }
    throw new Error("The clone finished but no git repository was found in " + here + " (contents: " + clip(entries.slice(0, 15).join(", "), 200) + ")");
}

function main() {
    collectSecrets();
    const cfg = readConfig();
    if (!cfg.feature || !isSafe(cfg.feature)) {
        return finish(cfg, "Failed", ["No usable feature branch name was provided."], skippedChecks("Not run: no feature branch"));
    }
    progress("Checking the feature branch" + ELL);
    const branchExists = checkFeatureBranch(cfg);
    adjustNoCommitsFinding(cfg, branchExists);
    if (branchExists === false) {
        const noBranch = noBranchChecks(cfg);
        return finish(cfg, verdictOf(cfg, noBranch, []), [], noBranch);
    }
    progress("Cloning repository" + ELL);
    try {
        prepareRepository(cfg);
    } catch (e) {
        const reason = "Could not clone the repository or check out " + cfg.feature + ": " + errMsg(e);
        return finish(cfg, "Failed", [reason], skippedChecks("Not run: repository could not be cloned"));
    }
    verifiedHead = (tryRun("git", ["rev-parse", "HEAD"]) || "").trim().toLowerCase();

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
    progress("Checking external branch merge" + ELL);
    const org = guarded("org-branch-merge", ctx, checkOrgMerge);
    console.log(org.title + ": " + org.status + " - " + org.summary);
    checks.push(org);
    if (org.status === "fail") {
        const why = "Skipped: another branch was merged into the feature branch";
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
    return finish(cfg, verdictOf(cfg, checks, ctx.problems), ctx.problems, checks);
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
            salesforceFindings: [],
            scriptSeconds: Math.round((Date.now() - startedAt) / 1000)
        })
    );
    process.exit(1);
}
