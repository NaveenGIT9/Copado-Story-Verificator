// Creates/updates the Copado data records for the Story Verification Gate (target org: alias 360 only).
// Run (after the user confirms): sf apex run --file scripts/create-copado-records.apex --target-org 360
// Idempotent: finds existing records by API name and updates them instead of inserting duplicates.
//
// MUST BE CHECKED IN THE ORG after running (these field values were copied from the reference
// examples in reference/*.json, not from a describe of those objects):
//  1. Function: copado__Type__c 'Custom' is a valid picklist value; copado__Image_Name__c
//     'copado-multicloud-dx:v6' (taken from the standard sfdx_execute_apex function) contains Node.js.
//     No UAM Function record was available in reference/, so Parameters mirror the standard
//     function format ([{required,name,defaultValue}]) - if the UAM function is declared differently, copy that.
//  2. Job Template: copado__ApiName__c. Copado normally derives the API name as <Name>_<version>
//     (e.g. SNOW_Deploy -> SNOW_Deploy_1). The Apex service starts the job with templateName
//     'Story_Verification_1'. If Copado assigns a different API name, change
//     StoryVerificationService.TEMPLATE_API_NAME to match. The template NAME must stay
//     'Story_Verification' because the completion logic matches copado__Template__r.Name.
//  3. Job Step: Type/CustomType 'Function' and the ConfigJson format follow example-job-steps.json.
//  4. Findings is an array inside DataJson; check that {$Context.JobExecution__r.DataJson.findings}
//     resolves to JSON text in the function's env var (function/index.js also accepts a double-encoded string).

final String FUNCTION_API_NAME = 'Story_Verification';
final String TEMPLATE_NAME = 'Story_Verification';
final String TEMPLATE_API_NAME = 'Story_Verification_1';
final String STEP_API_NAME = 'Story_Verification_1_Story_Verification_1'; // Copado normalises the step API name to this on insert
final List<String> PARAM_KEYS = new List<String>{ 'storyId', 'storyName', 'runId', 'baseBranch', 'findings' };

// Must stay identical to function/index.js (which contains no single quotes or backslashes, so no escaping is needed).
final String SCRIPT = String.join(
    new List<String>{
        '#!/usr/bin/env node',
        '"use strict";',
        '',
        '// Story Verification (phase A): aggregates the findings computed in Apex into a result.',
        '// NOTE: keep this file free of single quotes and backslashes - scripts/create-copado-records.apex',
        '// embeds it verbatim as an Apex string literal without escaping.',
        '',
        'const childProcess = require("child_process");',
        '',
        'const NL = String.fromCharCode(10);',
        'const EM_DASH = String.fromCharCode(8212);',
        'const SENSITIVE = ["TOKEN", "SECRET", "PASSWORD", "SESSION", "KEY"];',
        'const RELEVANT = ["COPADO", "STORY", "JOB", "RUN", "BRANCH", "GIT", "FINDINGS", "PIPELINE", "ENVIRONMENT"];',
        '',
        '// Uses execFileSync (no shell) so JSON and quotes in the text need no escaping.',
        'function copadoCli(args) {',
        '    try {',
        '        childProcess.execFileSync("copado", args, { stdio: "inherit" });',
        '    } catch (e) {',
        '        console.log("copado CLI unavailable or failed: " + e.message);',
        '    }',
        '}',
        '',
        'function progress(text) {',
        '    console.log(text);',
        '    copadoCli(["-p", text]);',
        '}',
        '',
        'function emit(runId, status, details) {',
        '    const payload = JSON.stringify({ runId: runId, status: status, details: details });',
        '    copadoCli(["-r", payload]);',
        '    console.log("RESULT:" + payload);',
        '}',
        '',
        '// findings may arrive as a JSON array string, or as a string that itself contains a JSON string.',
        'function parseFindings(raw) {',
        '    if (raw === undefined || raw === null || String(raw).trim() === "") {',
        '        return null;',
        '    }',
        '    let value = raw;',
        '    for (let i = 0; i < 2 && typeof value === "string"; i++) {',
        '        try {',
        '            value = JSON.parse(value);',
        '        } catch (e) {',
        '            return null;',
        '        }',
        '    }',
        '    return Array.isArray(value) ? value : null;',
        '}',
        '',
        '// Names only, never values.',
        'function relevantEnvNames() {',
        '    return Object.keys(process.env)',
        '        .filter((name) => {',
        '            const upper = name.toUpperCase();',
        '            return !SENSITIVE.some((s) => upper.includes(s)) && RELEVANT.some((r) => upper.includes(r));',
        '        })',
        '        .sort();',
        '}',
        '',
        'function main() {',
        '    const runId = process.env.runId || "";',
        '    const storyName = process.env.storyName || "";',
        '',
        '    progress("Story verification started for " + storyName + " (run " + runId + ")");',
        '    progress("Relevant environment variable names: " + relevantEnvNames().join(", "));',
        '',
        '    const findings = parseFindings(process.env.findings);',
        '    if (findings === null) {',
        '        progress("No findings received");',
        '        emit(runId, "Failed", "No findings received");',
        '        process.exit(1);',
        '    }',
        '',
        '    let hasIssue = false;',
        '    const lines = findings.map((f) => {',
        '        const isIssue = f !== null && typeof f === "object" && f.severity === "issue";',
        '        const message = f !== null && typeof f === "object" && f.message ? String(f.message) : String(f);',
        '        if (isIssue) {',
        '            hasIssue = true;',
        '        }',
        '        return (isIssue ? "ISSUE: " : "INFO: ") + message;',
        '    });',
        '    lines.push(',
        '        "NOT RUN: git checks (unregistered commits, org/env branch merged into the feature branch) " +',
        '            EM_DASH +',
        '            " phase B."',
        '    );',
        '',
        '    const status = hasIssue ? "Issues" : "Clean";',
        '    progress("Verification finished with status " + status);',
        '    emit(runId, status, lines.join(NL));',
        '    process.exit(0);',
        '}',
        '',
        'try {',
        '    main();',
        '} catch (err) {',
        '    console.log("Fatal: " + err.message);',
        '    emit(process.env.runId || "", "Failed", "Fatal: " + err.message);',
        '    process.exit(1);',
        '}',
        ''
    },
    '\n'
);

// Function parameters: one per dataJson key, in the standard {name, defaultValue} format.
List<Map<String, Object>> functionParams = new List<Map<String, Object>>();
List<Map<String, Object>> stepParams = new List<Map<String, Object>>();
for (String key : PARAM_KEYS) {
    String expression = '{$Context.JobExecution__r.DataJson.' + key + '}';
    functionParams.add(new Map<String, Object>{ 'required' => false, 'name' => key, 'defaultValue' => expression });
    stepParams.add(new Map<String, Object>{ 'name' => key, 'value' => expression, 'required' => false });
}

// 1. Function
List<copado__Function__c> existingFunctions = [
    SELECT Id
    FROM copado__Function__c
    WHERE copado__API_Name__c = :FUNCTION_API_NAME
    LIMIT 1
];
copado__Function__c fn = existingFunctions.isEmpty() ? new copado__Function__c() : existingFunctions[0];
fn.Name = 'Story Verification';
fn.copado__API_Name__c = FUNCTION_API_NAME;
fn.copado__Type__c = 'Custom';
fn.copado__Script__c = SCRIPT;
fn.copado__Parameters__c = JSON.serializePretty(functionParams);
fn.copado__Options__c = '[ ]';
fn.copado__Image_Name__c = 'copado-multicloud-dx:v6';
fn.copado__Worker_Size__c = 'S';
fn.copado__Timeout__c = 60;
fn.copado__Version__c = '1';
upsert fn;

// 2. Job Template (Name must equal 'Story_Verification' - the completion logic matches on it)
List<copado__JobTemplate__c> existingTemplates = [
    SELECT Id
    FROM copado__JobTemplate__c
    WHERE copado__ApiName__c = :TEMPLATE_API_NAME OR Name = :TEMPLATE_NAME
    LIMIT 1
];
copado__JobTemplate__c template = existingTemplates.isEmpty() ? new copado__JobTemplate__c() : existingTemplates[0];
template.Name = TEMPLATE_NAME;
template.copado__ApiName__c = TEMPLATE_API_NAME;
upsert template;

// 3. Job Step (one Function step)
List<copado__JobStep__c> existingSteps = [
    SELECT Id
    FROM copado__JobStep__c
    WHERE copado__JobTemplate__c = :template.Id AND copado__ApiName__c = :STEP_API_NAME
    LIMIT 1
];
copado__JobStep__c step = existingSteps.isEmpty() ? new copado__JobStep__c() : existingSteps[0];
step.Name = 'Story_Verification';
step.copado__ApiName__c = STEP_API_NAME;
step.copado__JobTemplate__c = template.Id;
step.copado__Type__c = 'Function';
step.copado__CustomType__c = 'Function';
step.copado__Order__c = 1;
step.copado__ConfigJson__c = JSON.serialize(
    new Map<String, Object>{ 'functionName' => FUNCTION_API_NAME, 'parameters' => stepParams }
);
upsert step;

System.debug('Story Verification records ready. Function=' + fn.Id + ' Template=' + template.Id + ' Step=' + step.Id);
