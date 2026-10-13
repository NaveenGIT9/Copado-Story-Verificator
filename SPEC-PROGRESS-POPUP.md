# Live verification progress popup — build spec

Project: D:\copado-story-verification (standalone SFDX project, API 63.0). Target org alias `360` ONLY. Do not run sf commands, do not deploy. Read SPEC.md first (existing contract), then the existing classes in force-app/main/default/classes/ (StoryVerificationService, StoryVerificationStart, StoryVerificationComplete and their tests).

## Goal
When the user clicks **Verify** on a Copado User Story, a popup opens and shows, live and in the same popup: what is being checked, the current state of the run, and at the end the final status (Clean / Issues / Failed) and WHY (the findings). The popup must keep working while the verification job runs asynchronously in Copado (about 15-60 s).

## Design
A Lightning Web Component **`storyVerificationPopup`** used as a SCREEN quick action (replaces the screen flow `Verify_Story_Screen` as the action's target; the flow stays in the project). It starts the run, then POLLS the server every 2 seconds until the run is finished or 5 minutes have passed. (A screen flow cannot refresh itself, which is why an LWC is needed.)

### Apex: new class `StoryVerificationController` (`with sharing` at class level; see note on sharing below)
- `@AuraEnabled public static ProgressSnapshot start(Id storyId)`: first verifies the current user can read the story with a SOQL on `copado__User_Story__c` (with sharing); calls `StoryVerificationService.startVerification(storyId)`; returns a snapshot built by the same code as `getProgress`. If starting throws `StoryVerificationException` (e.g. already running) return a snapshot with `errorMessage` set instead of throwing; any other exception: `throw new AuraHandledException(e.getMessage())`.
- `@AuraEnabled public static ProgressSnapshot getProgress(Id storyId, String runId)`: NOT cacheable. Returns:
  - `status` (the story's `Verification_Status__c`: Running / Clean / Issues / Failed / blank), `runId` (story's current run id), `isFinished` (status is Clean, Issues or Failed), `isCurrentRun` (the story's run id equals the `runId` argument — if not, a newer run has replaced this one; the UI should say so and stop polling),
  - `details` (the story's `Verification_Details__c`, split into a `List<String>` of lines),
  - `findings`: `List<Finding>` with `severity` (`issue`/`info`) and `message`, parsed from the `findings` array inside `copado__DataJson__c` of the latest `copado__JobExecution__c` for this story whose `copado__Template__r.Name = 'Story_Verification'` and whose DataJson `runId` equals the story's current run id (the Apex checks are computed before the job starts, so these are available immediately; if the Job Execution does not exist yet, return an empty list and `jobStatus` = `Queued`),
  - `jobStatus`: the Job Execution's `copado__Status__c` (map blank/unknown to `Queued`), `jobError`: its `copado__ErrorMessage__c`,
  - `progressText`: the latest progress text of the job's step result: `copado__Result__c.copado__Progress_Status__c` for the Result whose `copado__JobStep__c` is a step of that Job Execution (newest first, first non-blank); null if none,
  - `errorMessage` (only used by `start`).
- Reading `copado__JobExecution__c`, `copado__JobStep__c`, `copado__Result__c` may not be permitted to normal users, so put these reads in a `private without sharing class JobReader` inner class (documented in a comment: read-only, returns only status text for a story the caller can already read, which is checked first with sharing). Everything else stays with sharing.
- `ProgressSnapshot`, `Finding` are public inner classes with `@AuraEnabled` properties.

### Changes to existing code
- `StoryVerificationService.startVerification(Id)` currently returns void. Keep the behaviour but make it return the run id (`String`) so the controller can pass it along; update every caller and test that needs it (StoryVerificationStart ignores it). Do not break existing tests; update them if a signature change requires it.
- Add class access for `StoryVerificationController` in the permission set `Copado_Story_Verification_User` (permissionsets/Copado_Story_Verification_User.permissionset-meta.xml). Admin-owned files other than this one are handled elsewhere; do NOT edit the quick action file or flows.

### LWC `force-app/main/default/lwc/storyVerificationPopup/` (html, js, css optional, js-meta.xml)
- js-meta.xml: apiVersion 63.0, isExposed true, target `lightning__RecordAction` with `<actionType>ScreenAction</actionType>`.
- Uses `@api recordId`, `lightning-quick-action-panel` with header "Verify story", `CloseActionScreenEvent` from `lightning/actions` for the Close button.
- On connect: call `start({storyId: recordId})` imperatively, then poll `getProgress` every 2000 ms with `setTimeout` (not setInterval, so calls never overlap); clear the timer in `disconnectedCallback`; stop after 5 minutes and show "Still running. You can close this window; open the story later and check Verification Status."; stop at `isFinished` or when `isCurrentRun` is false.
- What is shown (top to bottom), updating live:
  1. A one-line current state with a spinner while running: e.g. "Starting verification…", "Checks computed in Salesforce — job queued in Copado", "Verification job running in Copado…" (use `jobStatus`, and append `progressText` if present), then the final result.
  2. A step list with an icon per step: the Salesforce-side checks from `findings` (green check = info, red cross = issue; show each message), then "Verification job in Copado" (pending / running spinner / done / failed from `jobStatus`), then "Git checks (unregistered commits, org/env branch merge)": always shown as "Not yet implemented (phase B)" with a neutral icon.
  3. At the end a result banner: **Clean** (success theme), **Issues** (warning theme) or **Failed** (error theme), followed by "Why:" and the `details` lines (ISSUE: lines emphasised), or for Failed the job error / details text.
  4. Buttons: Close (always), and "Verify again" after a finished run (restarts the whole thing).
- Errors from Apex are shown in an error banner, never swallowed. No inline DOM manipulation (use template directives and reactive properties). Accessible labels (`alternative-text` on icons/spinners, `aria-live="polite"` on the state line).
- Jest test `__tests__/storyVerificationPopup.test.js`: mock the two Apex methods with `jest.mock('@salesforce/apex/StoryVerificationController.start', ...)`, use fake timers; cover: renders running state then final Clean, final Issues showing the why lines, Failed with job error, `isCurrentRun=false` stops polling with a message, the 5-minute stop, an Apex error shows the banner, timers cleared on disconnect, "Verify again" restarts. (The repo style is `@salesforce/sfdx-lwc-jest`; add a minimal `package.json` with that dev dependency and an `npm run test:unit` script, plus `jest.config.js` using `@salesforce/sfdx-lwc-jest/config`, only if it does not exist. You cannot run npm; say so.)

### Apex tests: `StoryVerificationControllerTest`
- `start` returns a Running snapshot for a readable story (inject the job starter stub via the service's `@TestVisible` hook, as the existing tests do), and returns `errorMessage` (does not throw) when a run is already in progress.
- `getProgress` with a story that is Running and no Job Execution -> `jobStatus` Queued, empty findings; with a Job Execution (template named `Story_Verification`, DataJson holding the run id and a findings array) -> findings parsed, `jobStatus` mapped; finished Clean/Issues/Failed -> `isFinished` true and details split into lines; a different `runId` argument -> `isCurrentRun` false; a Result with a progress text -> `progressText` returned; a story the user cannot read -> exception. Use `System.runAs`, real assertions, no seeAllData; build test data like the existing tests (see `addCommitAndMetadata` and `template(...)`/`jobExecution(...)` helpers in `StoryVerificationCompleteTest` — copy what you need, including the required credential/snapshot-commit chain and `copado__Job_Type__c = 'Integration'` on `copado__Result__c`).

## Out of scope
Quick action XML, flows, validation rules (handled separately); the Function script; any deployment.

## Report back
List every file created/changed, what you could not verify (you cannot compile, run Jest or deploy), and anything in this spec you believe is wrong.
