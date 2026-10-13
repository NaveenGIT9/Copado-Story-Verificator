# Story Verification Gate — build spec (Phase A)

Target org: alias `360` (satyabhargav1113@gmail.com.data360). Copado is installed there (managed package, namespace `copado`).
This is a standalone SFDX project (API 63.0). NEVER deploy from here to any org other than `360`. Nothing is deployed without the user's explicit confirmation.

## Purpose
Before a user can tick **Ready to Promote** (`copado__Promote_Change__c`) or **Promote and Deploy** (`copado__Promote_and_Deploy__c`) on a Copado User Story, a verification must have been run on that story and be clean and current. A **Verify** quick action starts a Copado Function asynchronously; its result is written back to the story. Validation rules on the story refuse the ticks otherwise.

## Facts from the org (confirmed by describe; see `reference/*.txt` for the full field lists)
- `copado__User_Story__c`: has `copado__Promote_Change__c` (checkbox), `copado__Promote_and_Deploy__c` (checkbox), `copado__Latest_Commit_Date__c` (datetime), `copado__Base_Branch__c` (string 180), `copado__Status__c` (picklist: Draft, Backlog, Backburner, Awaiting Approval, Approved, Rejected, In Progress, Ready for testing, Completed, Cancelled, Ready for Development, Testing In Progress), `copado__Last_Promotion_Date__c`, `copado__Is_Bundle__c`. Record types: Bug, Investigation, User Story, Utility, Master. No required fields on create. No field named Verification* exists yet.
- `copado__User_Story_Commit__c` (`copado__User_Story__c`, `copado__CommitMessage__c`, `copado__Status__c`, CreatedDate), `copado__User_Story_Metadata__c` (`copado__User_Story__c`, `copado__Metadata_API_Name__c`, `copado__Type__c`, `copado__Action__c`, `copado__Last_Commit_Date__c`, `copado__Status__c`).
- The story's feature branch is NOT a field. By Copado convention it is `feature/<Story Name>` (e.g. `feature/US-0000025`). `copado__Base_Branch__c` is the branch the feature branch was cut from.
- Existing validation rules on the story are all Copado's own (managed). Existing flows on the story: SetApexTestLevel, cml_User_Story_Metrics_Automation, cml_User_Story_Severity_Update_Promotion — do not touch them.
- Copado objects exist: `copado__Function__c`, `copado__JobTemplate__c`, `copado__JobStep__c`, `copado__JobExecution__c`, `copado__Result__c`.

## Proven Copado pattern (copy it; reference implementation in `D:\Users\SriRama.Bonthu\Downloads\UserManagementAccess\`: `classes/UAMUserProvisioning.cls`, `flows/UAM_Job_Completion_Handler.flow-meta.xml`, `function/index.js`)
- Start: `copado.CreateExecution.Request` with `templateName`, `parentId` (the story Id), `dataJson` (JSON string), `runAfterInstantiation = true`; call `copado.CreateExecution.execute(new List<copado.CreateExecution.Request>{ req })` — ONE request per call (throws if the list has more than one).
- Function: a Node script stored in `copado__Script__c`; it is executed as a shell script so the FIRST LINE MUST be `#!/usr/bin/env node`. Data from `dataJson` arrives as environment variables (`process.env.<key>`). Report progress with the Copado CLI `copado -p "<text>"` and the result with `copado -r '<json>'` (also acceptable: print a final line `RESULT:<json>` as the UAM function does). Exit 0 on success, non-zero on failure.
- Completion: an after-update record-triggered flow on `copado__JobExecution__c` fires when `copado__Status__c` changes to Successful / Failed / Error; the story Id is in `copado__ParentRecord_Id__c`; the run's input is in `copado__DataJson__c`; an error text may be in `copado__ErrorMessage__c`. A step result may be in `copado__JobStep__c.copado__ResultDataJson__c` (JobStep.`copado__JobExecution__c` = the JE) or in `copado__Result__c.copado__Result_Data__c` (Result.`copado__JobStep__c` = the step). Code defensively: try the step field first, then the Result record.
- Job Template (a DATA record, not metadata): name/API `Story_Verification`, one Function step running Function `Story_Verification`. The Function record (`copado__Function__c`, API name `Story_Verification`, Type Custom) holds the script. These two records are created by a script in `scripts/`, not deployed as metadata.

## Contract between the pieces (both agents must use exactly these names)

### Fields on `copado__User_Story__c` (admin)
| API name | Type | Notes |
|---|---|---|
| `Verification_Status__c` | Picklist, restricted, no default | values: `Running`, `Clean`, `Issues`, `Failed`. Blank = never verified. `Failed` = the run itself crashed. |
| `Verification_Details__c` | Long Text Area 32768, 10 visible lines | human-readable findings, one per line |
| `Verification_Date__c` | Date/Time | the START time of the latest run |
| `Verification_Run_Id__c` | Text(80) | correlation id of the latest run |

### Custom permission (admin)
`Bypass_Verification_Gate` — "Bypass Verification Gate". Lets emergency users tick the boxes without a clean verification.

### Permission sets (admin)
- `Copado_Story_Verification_User`: read on the 4 fields; access to Apex classes `StoryVerificationStart`, `StoryVerificationComplete`, `StoryVerificationService`; flow access to `Verify_Story_Screen`.
- `Copado_Story_Verification_Bypass`: contains only the custom permission `Bypass_Verification_Gate`.
- `Copado_Story_Verification_Writer`: edit on the 4 fields (for any integration/system user that must write results).
Normal users get NO edit access to the 4 fields.

### Validation rules on `copado__User_Story__c` (admin) — 8 rules, all created with `<active>false</active>`
Common prefix for every formula: `AND( NOT($Permission.Bypass_Verification_Gate), <TICK>, <REASON> )`
- Ready to Promote: TICK = `AND(copado__Promote_Change__c = TRUE, OR(ISNEW(), ISCHANGED(copado__Promote_Change__c)))`
- Promote and Deploy: TICK = `AND(copado__Promote_and_Deploy__c = TRUE, OR(ISNEW(), ISCHANGED(copado__Promote_and_Deploy__c)))`
- REASON per rule (mutually exclusive):
  - `..._Never_Verified`: `ISPICKVAL(Verification_Status__c, "")`
  - `..._Running`: `ISPICKVAL(Verification_Status__c, "Running")`
  - `..._Issues`: `OR(ISPICKVAL(Verification_Status__c, "Issues"), ISPICKVAL(Verification_Status__c, "Failed"))`
  - `..._Stale`: `AND(ISPICKVAL(Verification_Status__c, "Clean"), OR(ISBLANK(Verification_Date__c), AND(NOT(ISBLANK(copado__Latest_Commit_Date__c)), Verification_Date__c < copado__Latest_Commit_Date__c)))`
Rule API names: `Ready_Promote_Gate_Never_Verified`, `Ready_Promote_Gate_Running`, `Ready_Promote_Gate_Issues`, `Ready_Promote_Gate_Stale`, `Promote_Deploy_Gate_Never_Verified`, `Promote_Deploy_Gate_Running`, `Promote_Deploy_Gate_Issues`, `Promote_Deploy_Gate_Stale`.
Error messages (top of page, no errorDisplayField), e.g. Never: "Run verification first: click Verify on this story, then try again."; Running: "Verification is still running. Wait for it to finish, then try again."; Issues: "Verification found issues. Fix them and run Verify again. See Verification Details on this story."; Stale: "There are new commits since the last verification. Run Verify again, then try again." (name the action, Ready to Promote vs Promote and Deploy, in each message).

### Quick action + flows (admin)
- Quick action `Verify_Story` on `copado__User_Story__c` (type Flow, label "Verify", flowDefinition `Verify_Story_Screen`). Add it to the story page layouts that exist in the project; if no layout metadata is present, say so in your report instead of inventing one.
- Screen flow `Verify_Story_Screen` (input variable `recordId`, text): screen 1 asks "Run verification for this story? It runs in the background and can take a minute."; then an Apex action calling `StoryVerificationStart` with the story id; final screen "Verification started. Refresh the story and check Verification Status." Fault path shows the error text.
- Record-triggered flow `Story_Verification_Completion`: object `copado__JobExecution__c`, RecordAfterSave, Update, start filter formula like `UAM_Job_Completion_Handler` (parent not blank; status Successful/Failed/Error; status changed) AND the JE's template name = `Story_Verification` (use `{!$Record.copado__Template__r.Name}` — if that cannot be used, call `StoryVerificationComplete` for every JE and let the Apex ignore non-matching ones). It calls the Apex action `StoryVerificationComplete` with the JobExecution id. Active.

### Apex (developer)
All classes `with sharing`, API 63.0, no hardcoded Ids. An `@InvocableMethod` must be alone in its class.
- `StoryVerificationService` — all logic, `public`:
  - `@TestVisible interface JobStarter { void start(copado.CreateExecution.Request req); }`, default implementation calling `copado.CreateExecution.execute(new List<...>{req})`; `@TestVisible static JobStarter starter` so tests can inject a stub (the managed class cannot be mocked).
  - `static void startVerification(Id storyId)`: guard — if the story is already `Running` and `Verification_Date__c` is within the last 30 minutes, throw `StoryVerificationException('Verification is already running')`; stale `Running` (older) may be restarted. Generate a run id (32 hex chars). Update the story: status `Running`, date = `System.now()`, run id, details blank. Build the findings (below), build dataJson, start the job (templateName `Story_Verification`, parentId = story Id). If starting throws, set status `Failed` with the message in details and rethrow.
  - Copado-data checks computed in Apex and passed to the Function as `findings` (a JSON array of `{severity: 'issue'|'info', message}`):
    1. No `copado__User_Story_Commit__c` for the story -> issue "No commits are registered in Copado for this story."
    2. No `copado__User_Story_Metadata__c` for the story -> issue "No metadata is selected on this story."
    3. If `copado__Base_Branch__c` starts with `feature/` -> the parent story is the story whose Name equals the rest of the branch; if found and its `copado__Status__c` is not `Completed` and it has no `copado__Last_Promotion_Date__c` -> issue "Base branch is the feature branch of <Name>, which has not been promoted yet." If not found -> info line.
    4. Always add info "Registered commits: N, selected metadata items: M."
  - dataJson keys: `storyId`, `storyName`, `runId`, `baseBranch`, `findings` (array). Keep it well under the size limit.
  - `static void completeVerification(Id jobExecutionId)`: load the JE (`copado__ParentRecord_Id__c`, `copado__Status__c`, `copado__ErrorMessage__c`, `copado__DataJson__c`, `copado__Template__r.Name`); ignore it unless the template name is `Story_Verification`. Read the runId from its DataJson and IGNORE the call if it does not equal the story's current `Verification_Run_Id__c` (stale/late run). If the JE status is Failed or Error -> story `Failed` with the error text. If Successful -> read the result JSON (`{runId, status:'Clean'|'Issues', details}`; see the lookup order above), set status/details accordingly; if the result cannot be read, set `Failed` with "Result could not be read". Must be idempotent (running it twice gives the same state) and bulk-safe.
- `StoryVerificationStart` — `@InvocableMethod(label='Start Story Verification')`, `Request` inner class with `@InvocableVariable(required=true) public Id storyId;`, calls the service for each request, one at a time.
- `StoryVerificationComplete` — `@InvocableMethod(label='Complete Story Verification')`, inner `Request` with `@InvocableVariable(required=true) public Id jobExecutionId;`.
- `StoryVerificationException extends Exception` (own file or inner).
- Tests: one test class per class (`StoryVerificationServiceTest`, `StoryVerificationStartTest`, `StoryVerificationCompleteTest`) — at least one assertion per test method, 85%+ coverage, a bulk case (200 stories for the Complete path), negative paths (no commits, no metadata, parent not promoted, double run, stale run id ignored, JE Failed), and a `System.runAs` block. Create test data in a `@TestSetup` using the standard constructors: `new copado__User_Story__c(copado__User_Story_Title__c = '...')` (check `reference/copado__User_Story__c.txt` for the title field name) and children from the reference files. If a managed-package required field blocks DML, report it. Never `seeAllData=true`.

### Copado Function (developer): `function/index.js`
- First line `#!/usr/bin/env node`, then `'use strict'`. Reads env vars `storyId`, `storyName`, `runId`, `baseBranch`, `findings` (JSON string).
- Phase A has NO git access: it only aggregates `findings` into the result. It must NOT claim the git checks were done: add the line `NOT RUN: git checks (unregistered commits, org/env branch merged into the feature branch) — phase B.` to the details.
- `status` = `Issues` if any finding has severity `issue`, else `Clean`.
- For discovery, call `copado -p` with the NAMES (never the values) of the environment variables present that look relevant (names only, filter out anything containing TOKEN, SECRET, PASSWORD, SESSION, KEY).
- Output the result with `copado -r` as JSON `{"runId": "...", "status": "...", "details": "..."}` (details: newline-separated lines) and also print `RESULT:` + the same JSON on a line by itself. Handle a missing/invalid `findings` by producing status `Failed` details "No findings received" and a non-zero exit.
- Also write `scripts/create-copado-records.apex` (anonymous Apex): creates/updates the `copado__Function__c` (Name `Story Verification`, API Name `Story_Verification`, Type `Custom`, Script = the contents of function/index.js embedded as a string literal, Parameters listing the env var keys `storyId`, `storyName`, `runId`, `baseBranch`, `findings` as `[{"name":"storyId","defaultValue":"{$Context.JobExecution__r.DataJson.storyId}"}, ...]` — mirror how the UAM function declares its parameters if its record is available in the reference folder, otherwise explain the uncertainty) and the `copado__JobTemplate__c` `Story Verification` (API name `Story_Verification`) with one `copado__JobStep__c` of Type Function pointing at it. Make it idempotent (upsert by API name). Mark clearly in comments anything that must be checked in the org.

## Out of scope for Phase A
Git-based checks, the optional LWC, the promotion-status display (lives in the Commit Validator VS Code extension), back-filling existing stories, any deployment (a separate confirmation step follows).

## Report back
List every file you created with its path, anything you could not verify, and anything in this spec you believe is wrong. Do not deploy.
