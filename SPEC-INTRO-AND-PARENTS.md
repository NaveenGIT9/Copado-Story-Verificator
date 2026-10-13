# Verify popup: confirmation screen first, one fixed list of checks, richer parent-story check

Project: D:\copado-story-verification (standalone SFDX project, API 63.0, org alias `360`). You have NO shell: you cannot compile, run Jest or deploy; re-read your work carefully and report what you could not verify. Read first: SPEC.md, SPEC-PHASE-B.md, the current code (force-app/main/default/classes/StoryVerification*.cls and tests, lwc/storyVerificationPopup incl. __tests__). Do NOT touch function/index.js, scripts/, validation rules, flows or quick actions.

## 1. LWC: confirmation screen before anything runs
Clicking the Verify quick action must NOT start a run. It opens the popup in an **intro phase**:
- Header "Verify story" (as today). Body text: `Verify {storyName} for` (storyName e.g. US-0000026, loaded with `@wire(getRecord, { recordId: '$recordId', fields: [NAME_FIELD] })`, `NAME_FIELD` from `@salesforce/schema/copado__User_Story__c.Name`; until it loads show `Verify this story for`).
- Then a bulleted list using real bullet markers (SLDS `slds-list_dotted`, not letters/numbers), in exactly this order:
  - Unregistered commits
  - Metadata coverage
  - Pull request approval
  - Pending tests
  - Parent story dependencies (and which environment the parent is in)
  - Org/environment branch merge into the feature branch
- Footer: a brand **Verify** button (`data-id="verify"`) and a **Close** button (`data-id="close"`). Nothing is sent to Apex in this phase.
- Clicking Verify starts the run exactly as the current `begin()` does (capture the story id from recordId at that moment, as today; keep the existing run-id/polling/timeouts/session logic). Remove the automatic start (`startWhenReady`/auto begin on connect); keep `_recordId` handling (ignore a cleared recordId). During/after the run the footer shows Close, and `Verify again` after a finished run (as today). "Verify again" restarts the run directly (no intro again).
- While the run is in progress or finished, the intro text/bullets are hidden (the run view replaces them).
- Jest: update the existing tests (they currently expect the run to start on mount; they must click `[data-id="verify"]` first) and add tests: intro shows the story name from the wire, the six bullets in order with `slds-list_dotted`, fallback text before the name loads, no Apex call before the click, Verify click starts the run, Close dispatches the close event in the intro. Use the standard sfdx-lwc-jest `getRecord` wire adapter test helper (`getRecord.emit(...)` imported from `lightning/uiRecordApi`).

## 2. LWC: one fixed list of checks, in the same order as the intro
In the run view (running AND finished) the step list shows these six rows in this order, then the technical "Verification job in Copado" row, then any remaining ungrouped info lines (registered-commit count, truncation note, "no pipeline" issue, etc.):
1. Unregistered commits (git check result)  2. Metadata coverage (git check result)  3. Pull request approval (Apex finding, group `pull-request`)  4. Pending tests (Apex finding, group `pending-tests`)  5. Parent story dependencies (Apex findings, group `parent-dependencies`)  6. Org/environment branch merge (git check result).
- Apex findings now carry an optional `group` (see section 3). Findings WITHOUT a group render exactly as today (a row each, icon by severity). Findings WITH a group are rendered as ONE row per group titled as above: icon red cross if any finding in the group is an issue, else green check; text `Title: <message>` when the group has one finding, or `Title: <n> parent stories — <k> need attention` / `Title: <n> parent stories, all ahead` for several; when the group has more than one finding (or the single message is long), add the same expandable details toggle used for the git checks listing every message, expanded by default when any is an issue.
- Git-check rows keep their pending/running/pass/fail/warn/skipped behaviour (pending/spinner while the job runs).
- The existing "Promotion readiness" live section stays as is.
- Jest tests: row order, grouped parent row with several parents (issue + ok), grouped single message, pull-request and pending-tests rows, ungrouped infos still shown, ordering while running.

## 3. Apex: parent story dependencies (StoryVerificationService + StoryVerificationController)
- `Finding` (controller) gets `@AuraEnabled public String group;` filled from the finding's `group` key when present. The service's finding maps may now contain a third key `group`. Existing consumers (Function pass-through, fallback verdict, Jest/Apex tests) must keep working with the extra key (the Function only reads severity and message).
- Put `group` = `pull-request` on the pull-request finding, `pending-tests` on the pending-tests finding, `parent-dependencies` on every parent finding below.
- Replace `addParentFinding` with a fuller check, only when the story is queried (extend the story query with whatever is needed). Parents of the story are:
  a) the base-branch parent: `copado__Base_Branch__c` starts with `feature/` -> the story whose Name equals the rest (as today), label "via base branch";
  b) Copado dependencies where this story is the child: `copado__Team_Dependency__c` with `copado__Dependent_User_Story__c = :storyId` and `copado__Skip_Dependency__c = false`, the parent being `copado__Provider_User_Story__c`; label "via dependency (<copado__Relationship_Type__c>)". De-duplicate parents by Id (a parent reached both ways is listed once with both labels). Cap at 50 parents.
  For each parent story read `Name`, `copado__Status__c`, `copado__Last_Promotion_Date__c`, `copado__Environment__c`, `copado__Environment__r.Name`.
- Environment ordering: from the pipeline steps `copado__Deployment_Flow_Step__c` of the story's pipeline (`copado__Source_Environment__c` -> `copado__Destination_Environment__c`; real example in the org: Dev1-SFP and Dev2-SFP -> INT-SFP -> UAT-SFP -> Production-SFP, and Hotfix-SFP -> Production-SFP) compute a level per environment id = the longest distance from an environment that is never a destination (roots = level 0), via iterative relaxation limited to the number of steps (guard against cycles). Write this as pure, `@TestVisible` static methods that take plain lists/maps (e.g. a small `StepEdge {Id sourceId; Id destinationId}` class and `Map<Id,Integer> computeLevels(List<StepEdge>)`; and `String parentVerdict(Integer childLevel, Integer parentLevel, Boolean parentCompleted)` returning `ahead`/`not-ahead`/`unknown`) so they can be unit-tested without DML.
- Findings, one per parent, severity and text:
  - parent `Completed` status, or parentLevel > childLevel: `info`, `Parent story <Name> (<via>) is in <ParentEnv>, ahead of this story (<ChildEnv>).`
  - otherwise `issue`: `Parent story <Name> (<via>) is in <ParentEnv>, not ahead of this story (<ChildEnv>). Promote the parent first.`
  - parent has no environment: `issue`, `Parent story <Name> (<via>) has no environment yet, so it has not been promoted.`
  - no pipeline levels available (no pipeline or an environment missing from the steps): fall back to the old rule (parent Completed or has a last promotion date = ok/info, else issue) but still name the environment(s) in the text (`... is in <ParentEnv>`, or `no environment`).
  - a base-branch name that looks like a feature branch but no story is found: keep the `info` line as today.
  - if the story has NO parents at all: one `info` finding `No parent story dependencies.` with group `parent-dependencies`.
- All bulk-safe SOQL (binds only, no SOQL in loops), never throw for missing optional data.
- Update ALL existing tests that depend on the old parent messages (startFlagsUnpromotedParentFeatureBranch, startAcceptsCompletedParent, startNotesUnknownParentAsInfo, startIgnoresNonFeatureBaseBranch, finding-count assertions) and add: pure tests for computeLevels (chain, two roots into one env, a cycle, empty) and parentVerdict (ahead, not-ahead, completed, unknown), a DML test for a Copado dependency parent (create a second story and a `copado__Team_Dependency__c`, no pipeline => fallback rule), a base-branch + dependency duplicate listed once, `No parent story dependencies.` when none, and that grouped findings carry `group`. Keep the `pullRequestApprovedOverride` hook usage for the PR field. Keep every still-valid assertion.

## Report back
Every file changed, what you could not verify, anything in this spec you believe is wrong or risky.
