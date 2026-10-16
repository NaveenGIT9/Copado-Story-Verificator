# Copado Story Verification Gate

A gate for Copado User Stories. Before anyone can tick **Ready to Promote** or **Promote and Deploy**, the story must be **verified**, and the verification must be **Clean** and **current**.

A user clicks **Verify** on the story. A popup runs six checks live, shows each result with the reason, and stores the verdict on the story. Validation rules then allow or block the two checkboxes based on that verdict.

## What it checks

| Check | Passes when | Where it runs |
|---|---|---|
| **Unregistered commits** | Every commit on the feature branch (compared with the base branch) is registered in Copado. A commit made outside Copado by the same person, on components that are registered, is only a **warning**. A commit by someone else, or on components that are not registered, **fails**. | Copado Function (git) |
| **Metadata coverage** | Every component changed in git is registered on the story, so it will actually be deployed. A changed component is registered only by an item of the **same type with exactly its name**. Nothing registered under a related name stands in for it (an object's fields do not cover the object, a class does not cover a trigger of the same name). | Copado Function (git) |
| **External branch merge** | No other branch was merged into the feature branch since it left its base branch: not an environment branch (for example `dev1`, `uat`), a promotion branch or another story's feature branch (fails). The story's own feature branch is ignored, and merging only the base branch is a warning. | Copado Function (git) |
| **Pull request approval** | The story's *Pull Requests Approved* box is ticked. Stories with no commits and no metadata are not asked for one (see below). | Apex |
| **Pending tests** | *Pending Tests* is 0. | Apex |
| **Parent story dependencies** | Parent stories (through the base branch or a dependency) are promoted ahead of this story. | Apex |

Verdicts:

| Verdict | Meaning | Can promote? |
|---|---|---|
| **Clean** | No check failed (warnings are allowed). | Yes, while the verification is current. |
| **Issues** | At least one check failed. | No. |
| **Failed** | The run itself crashed (for example the repository could not be cloned). | No. |
| **Running** | A verification is in progress. | No. |
| *(blank)* | Never verified. | No. |

A **Clean** verification becomes stale when a newer commit appears. The gate then asks for a new Verify.

### Stories with no commits

A story that has **no commit records and no metadata records** (only deployment steps, or nothing at all) has no code to review, so no pull request is expected. The Function asks Git whether the feature branch (`feature/<story>`) exists and the rows follow this table:

| Commits or metadata on the story | Feature branch in Git | Result |
|---|---|---|
| none, but there are deployment steps | missing | **Pull Request Approval : No commits** (green). The three git rows show "No feature branch" (green). The story can be promoted. |
| none, no deployment steps either | missing | **Pull Request Approval : Nothing to promote** (amber warning). It does not block. |
| none | exists | **Pull Request Approval : No commits** (amber warning, even when the box is ticked, because a branch should not exist without commits). It does not block. |
| yes | **missing** | **Blocks.** Unregistered Commits shows `No feature branch (feature/US-x not found in Git)`. The other git rows are "Not run". The verdict is Issues. |
| yes | exists | The normal checks. |

The two *PR Not Approved* validation rules follow the same idea. Each verification stores whether the story had no commits in the field `Verification_No_Commits__c`, and the rules do not ask for an approved pull request when it is true. Stories verified before this field existed keep the old behaviour until they are verified again.

## How it works

1. **Verify** (quick action on the User Story) opens the popup, which shows what will be checked. Clicking **Verify** in it starts the run.
2. Apex (`StoryVerificationService`) gathers the Salesforce-side facts and starts a Copado job from the Job Template `Story_Verification`.
3. The job runs the Copado Function, which clones the repository (history only, no file contents) and runs the three git checks.
4. The job result is written back by the flow `Story_Verification_Completion` (Apex `StoryVerificationComplete`) to the five `Verification_*` fields on the story.
5. The popup polls progress, shows the checks passed-first, and displays **Time taken** (with a split into *Copado queue* and *checks* when Copado took 15 s or more to start the job).
6. Twelve validation rules compare the checkbox being ticked with the stored verdict, the *Pull Requests Approved* box and *Pending Tests*.

The rules only run when **Ready to Promote** or **Promote and Deploy** is being ticked, not on every save.

## What is in the package

`manifest/package.xml` lists 37 components (API 63.0):

| Type | Components |
|---|---|
| Apex classes (11) | `StoryVerificationService`, `StoryVerificationController`, `StoryVerificationComplete`, `StoryVerificationException`, `StoryVerificationSetup` (creates the Copado Function, Job Template and Job Step, and holds the Function text), `StoryVerificationMetadataController` (Create Selected Metadata), and five test classes |
| Lightning component | `storyVerificationPopup` |
| Fields (6, on `copado__User_Story__c`) | `Verification_No_Commits__c`, `Verification_Status__c`, `Verification_Date__c`, `Verification_Details__c`, `Verification_Run_Id__c`, `Verification_Checks__c` |
| Custom permissions (2) | `Bypass_Verification_Gate`, `Create_Story_Metadata` |
| Flow | `Story_Verification_Completion` |
| Permission sets (3) | `Copado_Story_Verification_User`, `Copado_Story_Verification_Bypass`, `Copado_Story_Verification_Metadata_Creator` |
| Quick action | `copado__User_Story__c.Verify_Story_Live` |
| Validation rules (12) | `Ready_Promote_Gate_*` and `Promote_Deploy_Gate_*`, each with: `Never_Verified`, `Running`, `Issues`, `Stale`, `Pending_Tests`, `PR_Not_Approved` |

**Not in the package** (they are Copado data records, not metadata): the Copado **Function**, **Job Template** and **Job Step**. They are created by `StoryVerificationSetup.run()` (see Install).

## Requirements

- A Salesforce org with **Copado** installed (managed package, namespace `copado`), with a pipeline, a project and an authenticated Git repository.
- Salesforce CLI (`sf`) and a user who can deploy metadata and run anonymous Apex.
- A Git repository connected to Copado. OAuth repositories are supported.

## Install

1. **Deploy the metadata**
   ```
   sf project deploy start --manifest manifest/package.xml --target-org <alias> --test-level RunSpecifiedTests --tests StoryVerificationServiceTest --tests StoryVerificationCompleteTest --tests StoryVerificationControllerTest --tests StoryVerificationSetupTest --wait 30
   ```
   Add `--dry-run` for a check-only run first.
2. **Create the Copado records** (Function, Job Template, Job Step). This runs the deployed class `StoryVerificationSetup`:
   ```
   sf apex run --file scripts/create-copado-records.apex --target-org <alias>
   ```
   The file is one line, `StoryVerificationSetup.run();`, so you can also paste that line into Execute Anonymous in the Developer Console. Look for `Story Verification records ready` in the debug log. It updates existing records in place, so you can rerun it safely, and **must** rerun it after any change to the Function (that is, after deploying a new version of the package).
3. **Add the Verify action to the page layout.** Add the quick action **Verify** to the User Story page layout. Optionally add `Verification Status`, `Verification Date` and `Verification Details` to the Lightning record page.
4. **Assign permission sets** (see the next section).
5. **Check the repository.** The pipeline's Git repository must show as authenticated in Copado.

The Function source is `function/index.js`. The setup class `StoryVerificationSetup` (which carries a copy of it) is generated from it, so after editing the Function run:
```
node scripts/build-create-records.js          # regenerate StoryVerificationSetup.cls and the one-line script
node scripts/build-create-records.js --check  # verify they are up to date
```

## Who gets which permission set

| Who | Permission set(s) | What it gives |
|---|---|---|
| **Developers and anyone who runs Verify** | **Copado Story Verification User** | Access to the Verify popup's Apex and read access to the five `Verification_*` fields. The gate applies to them. |
| **Emergency users who may skip the gate** | **Copado Story Verification Bypass** **and** **Copado Story Verification User** | Bypass switches off all 12 validation rules for the user. They still need User to use the Verify button, otherwise the popup says "You do not have access to this story". |
| **People who may register missing metadata on stories** | **Copado Story Verification Metadata Creator** **and** **Copado Story Verification User** | Shows the **Create Selected Metadata** button (see below). Without it the "Not registered" list is still shown, with ADD or DELETE beside each component, but cannot be ticked. |
| **Everyone else** | none | They cannot run Verify, and the gate still blocks their checkboxes. |

Give **Bypass** to as few people as possible. It lets a user tick Ready to Promote and Promote and Deploy with no verification at all.

Nobody has edit access to the result fields. The Apex writes them in system mode, so users cannot hand-edit a verdict.

To assign from the CLI:
```
sf org assign permset --name Copado_Story_Verification_User --target-org <alias> --on-behalf-of <username>
```
There is no CLI command to remove an assignment. Delete the `PermissionSetAssignment` record in Setup instead.

## Registering missing metadata from the popup

The "Not registered" list under Metadata Coverage shows the components that changed in git but are not in the story's metadata, so they would not deploy. Each one shows the action it needs in Copado: **ADD**, or **DELETE** when the component is gone from the final version of the feature branch (every one of its files was removed, and nothing of it is left).

For users with the **Metadata Creator** permission set the list has tick boxes: **Select all**, one box per metadata type and one per component. Once something is ticked, a **Create Selected Metadata** button appears under the "won't deploy" line.

1. Clicking the button opens a **preview** inside the popup: the story, and the User Story Metadata records that would be created, grouped by metadata type, with their action and file path. Records that already exist are marked and skipped.
2. **Insert** creates them. **Back** returns to the checks with the ticks kept.
3. The result says how many were created. Click **Verify again** to refresh the verification.

The records follow Copado's own pattern: `Metadata API Name`, `Type` (for example ApexClass), `Action` (Add or Delete), `Category` SFDX, `Module Directory` (the file path), `Last Commit Date`, a `Name` of the form `US-0001 Add ApexClass.MyClass` and a unique id built from the story, path, type and name, so clicking twice never creates a duplicate.

Safety: the browser only says which components were ticked. The records are rebuilt on the server from the verification result stored on the story, so only components the verification itself found can be added. Reading and writing run as the user, so the user's own Copado permissions still apply. For types Copado cannot commit from the CLI (Profile, Workflow, CustomLabels, AssignmentRules, Translations, CustomObjectTranslation, AutoResponseRules, MatchingRules, SharingRules, EscalationRules) the **Module Directory is left blank**, because a directory path marks a record as a CLI commit; permission sets and objects keep their path. A workflow file holds every rule and action of one object, so it is read part by part (like the labels file): each changed rule, alert, field update, task, outbound message, knowledge publish and flow action is one component named `Object.PartName` (as written in the file, URL-encoded), and the `Workflow` record named after the object always comes with them, because deploying a rule or an action without it fails. A part counts as deleted only when it is missing from the final version of the file. A matching rules file holds one rule per block, so each changed rule is one `MatchingRule` component named `Object.RuleName` (no record for the whole file, no parent record). A type this tool cannot map to a Copado metadata type has its boxes disabled.

**Custom labels:** git keeps every label in one file, `CustomLabels.labels-meta.xml`. The check reads that file on the base branch and on the feature branch and lists only the labels that were added or changed (ADD) or removed (DELETE), each as its own `CustomLabel` component. A label registered on the story as `CustomLabel` covers itself, and the whole file registered as `CustomLabels` covers every label in it. If the file cannot be read, the file itself is listed as one component, as before, and cannot be ticked.

## Why there is a custom permission

The validation rules need to answer "may this user skip the gate?". A validation rule formula cannot test whether a user holds a particular permission set, but it can test a **custom permission** with `$Permission.Bypass_Verification_Gate`. So:

- Every rule starts with `NOT($Permission.Bypass_Verification_Gate)`.
- The custom permission sits inside the **Bypass** permission set, so holding that set is what switches the rules off.
- You can also add the same custom permission to your own permission set or permission set group (for example for release managers) without editing any of the 12 rules.

## Using it

1. Open the User Story and click **Verify**.
2. Read the list of checks and click **Verify** in the popup.
3. Wait for the result. Passed checks are listed first, failures after. **Show details** and **Hide details** open the reasons. Components that are not registered are listed on a line under the headline.
4. If the verdict is **Clean**, tick **Ready to Promote** or **Promote and Deploy**.
5. If it is **Issues**, fix the cause and click **Verify again**.

If you try to tick a box without a Clean, current verification, the rule's message tells you what to do (verify first, wait for the run, fix the issues, run Verify again after new commits, approve the pull request, or wait for pending tests).

## Troubleshooting

| What you see | Cause and fix |
|---|---|
| `Invalid template name Story_Verification_1` | The Job Template does not exist in this org, or Copado gave it another API name. Run the setup script. If the API name differs, update `TEMPLATE_API_NAME` in `StoryVerificationService` to match. |
| `You do not have access to this story` | The user lacks the **User** permission set (a bypasser also needs it). |
| `Repository not authenticated` | Copado could not log in to the repository. Check the Git repository's authentication, and rerun the setup script so the Function has the `repositoryId` parameter. |
| `Could not clone the repository` or `…list the repository branches` | Read the end of the message. It shows git's own reason. Check the pipeline's repository and the feature branch name. |
| Verify stays on `Accepted by Backend. Scheduling.` | That is Copado's own job start-up wait, not the checks. The popup shows it as `Waiting for Copado to start the job`. It varies from seconds to a few minutes. A larger Function worker size (M) was tried in one org and looked faster, but this is unproven. |
| `Commit … is not a registered committer` | The unregistered commit's author email differs from every registered commit's author email. Register the commit through Copado, or confirm it by hand. |
| Deploy tests fail with a required-field or validation error on `copado__User_Story__c` | The org has extra validation rules (for example a mandatory `Jira_Key__c`). The tests fill `Jira_Key__c` when the field exists. For other rules, extend the test data in the three test classes. |

## Repository layout

```
force-app/main/default/   metadata: classes, lwc, fields, validation rules, flow, permission sets, quick action
function/index.js         the Copado Function (Node.js) that runs the git checks
scripts/                  generator for StoryVerificationSetup.cls, and the one-line create-copado-records.apex
manifest/package.xml      the package list
jest-mocks/               local stubs so the popup's Jest tests run outside Salesforce
docs/exchange-listing.md  short description of the utility for a marketplace listing
```

Popup unit tests:
```
npm install
npx sfdx-lwc-jest force-app/main/default/lwc/storyVerificationPopup
```

## Known limits

- It was built and tested in two orgs. Behaviour on very large repositories (tens of thousands of commits) was checked only with generated test repositories.
- The three git checks depend on Copado's job start-up time, which this project cannot change.
- The parent-dependency check finds a story's parents through its base branch (`feature/<parent story>`) and through Copado dependencies. A parent counts as ahead when it sits in an environment later in the pipeline than the child's environment, or is Completed. Otherwise the parent must be promoted first.
