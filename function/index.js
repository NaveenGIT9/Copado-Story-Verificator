#!/usr/bin/env node
"use strict";

// Story Verification (phase A): aggregates the findings computed in Apex into a result.
// NOTE: keep this file free of single quotes and backslashes - scripts/create-copado-records.apex
// embeds it verbatim as an Apex string literal without escaping.

const childProcess = require("child_process");

const NL = String.fromCharCode(10);
const EM_DASH = String.fromCharCode(8212);
const SENSITIVE = ["TOKEN", "SECRET", "PASSWORD", "SESSION", "KEY"];
const RELEVANT = ["COPADO", "STORY", "JOB", "RUN", "BRANCH", "GIT", "FINDINGS", "PIPELINE", "ENVIRONMENT"];

// Uses execFileSync (no shell) so JSON and quotes in the text need no escaping.
function copadoCli(args) {
    try {
        childProcess.execFileSync("copado", args, { stdio: "inherit" });
    } catch (e) {
        console.log("copado CLI unavailable or failed: " + e.message);
    }
}

function progress(text) {
    console.log(text);
    copadoCli(["-p", text]);
}

function emit(runId, status, details) {
    const payload = JSON.stringify({ runId: runId, status: status, details: details });
    copadoCli(["-r", payload]);
    console.log("RESULT:" + payload);
}

// findings may arrive as a JSON array string, or as a string that itself contains a JSON string.
function parseFindings(raw) {
    if (raw === undefined || raw === null || String(raw).trim() === "") {
        return null;
    }
    let value = raw;
    for (let i = 0; i < 2 && typeof value === "string"; i++) {
        try {
            value = JSON.parse(value);
        } catch (e) {
            return null;
        }
    }
    return Array.isArray(value) ? value : null;
}

// Names only, never values.
function relevantEnvNames() {
    return Object.keys(process.env)
        .filter((name) => {
            const upper = name.toUpperCase();
            return !SENSITIVE.some((s) => upper.includes(s)) && RELEVANT.some((r) => upper.includes(r));
        })
        .sort();
}

function main() {
    const runId = process.env.runId || "";
    const storyName = process.env.storyName || "";

    progress("Story verification started for " + storyName + " (run " + runId + ")");
    progress("Relevant environment variable names: " + relevantEnvNames().join(", "));

    const findings = parseFindings(process.env.findings);
    if (findings === null) {
        progress("No findings received");
        emit(runId, "Failed", "No findings received");
        process.exit(1);
    }

    let hasIssue = false;
    const lines = findings.map((f) => {
        const isIssue = f !== null && typeof f === "object" && f.severity === "issue";
        const message = f !== null && typeof f === "object" && f.message ? String(f.message) : String(f);
        if (isIssue) {
            hasIssue = true;
        }
        return (isIssue ? "ISSUE: " : "INFO: ") + message;
    });
    lines.push(
        "NOT RUN: git checks (unregistered commits, org/env branch merged into the feature branch) " +
            EM_DASH +
            " phase B."
    );

    const status = hasIssue ? "Issues" : "Clean";
    progress("Verification finished with status " + status);
    emit(runId, status, lines.join(NL));
    process.exit(0);
}

try {
    main();
} catch (err) {
    console.log("Fatal: " + err.message);
    emit(process.env.runId || "", "Failed", "Fatal: " + err.message);
    process.exit(1);
}
