# Copado Story Verification Gate

A gate for Copado User Stories. Before anyone can tick **Ready to Promote** or **Promote and Deploy**, the story must be **verified**, and the verification must be **Clean** and **current**.

A user clicks **Verify** on the story. A popup runs six checks live, shows each result with the reason, and stores the verdict on the story. Validation rules then allow or block the two checkboxes based on that verdict.

## What it checks

| Check | Passes when | Where it runs |
|---|---|---|
| **Unregistered commits** | Every commit on the feature branch (compared with the base branch) is registered in Copado. A commit made outside Copado by the same person, on components that are registered, is only a **warning**. A commit by someone else, or on components that are not registered, **fails**. | Copado Function (git) |
| **Metadata coverage** | Every component changed in git is registered on the story, so it will actually be deployed. | Copado Function (git) |
| **Org / environment branch merge** | No pipeline environment branch (for example `dev1`, `uat`) was merged into the feature branch. | Copado Function (git) |
| **Pull request approval** | The story's *Pull Requests Approved* box is ticked. | Apex |
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

## How it works

1. **Verify** (quick action on the User Story) opens the popup, which shows what will be checked. Clicking **Verify** in it starts the run.
2. Apex (`StoryVerificationService`) gathers the Salesforce-side facts and starts a Copado job from the Job Template `Story_Verification`.
3. The job runs the Copado Function, which clones the repository (history only, no file contents) and runs the three git checks.
4. The job result is written back by the flow `Story_Verification_Completion` (Apex `StoryVerificationComplete`) to the five `Verification_*` fields on the story.
5. The popup polls progress, shows the checks passed-first, and displays **Time taken** (with a split into *Copado queue* and *checks* when Copado took 15 s or more to start the job).
6. Twelve validation rules compare the checkbox being ticked with the stored verdict, the *Pull Requests Approved* box and *Pending Tests*.

The rules only run when **Ready to Promote** or **Promote and Deploy** is being ticked, not on every save.

## What is in the package

`manifest/package.xml` lists 30 components (API 63.0):

| Type | Components |
|---|---|
| Apex classes (7) | `StoryVerificationService`, `StoryVerificationController`, `StoryVerificationComplete`, `StoryVerificationException`, and three test classes |
| Lightning component | `storyVerificationPopup` |
| Fields (5, on `copado__User_Story__c`) | `Verification_Status__c`, `Verification_Date__c`, `Verification_Details__c`, `Verification_Run_Id__c`, `Verification_Checks__c` |
| Custom permission | `Bypass_Verification_Gate` |
| Flow | `Story_Verification_Completion` |
| Permission sets (2) | `Copado_Story_Verification_User`, `Copado_Story_Verification_Bypass` |
| Quick action | `copado__User_Story__c.Verify_Story_Live` |
| Validation rules (12) | `Ready_Promote_Gate_*` and `Promote_Deploy_Gate_*`, each with: `Never_Verified`, `Running`, `Issues`, `Stale`, `Pending_Tests`, `PR_Not_Approved` |

**Not in the package** (they are Copado data records, not metadata): the Copado **Function**, **Job Template** and **Job Step**. They are created by `scripts/create-copado-records.apex` (see Install).

## Requirements

- A Salesforce org with **Copado** installed (managed package, namespace `copado`), with a pipeline, a project and an authenticated Git repository.
- Salesforce CLI (`sf`) and a user who can deploy metadata and run anonymous Apex.
- A Git repository connected to Copado. OAuth repositories are supported.

## Install

1. **Deploy the metadata**
   ```
   sf project deploy start --manifest manifest/package.xml --target-org <alias> --test-level RunSpecifiedTests --tests StoryVerificationServiceTest --tests StoryVerificationCompleteTest --tests StoryVerificationControllerTest --wait 30
   ```
   Add `--dry-run` for a check-only run first.
2. **Create the Copado records** (Function, Job Template, Job Step)
   ```
   sf apex run --file scripts/create-copado-records.apex --target-org <alias>
   ```
   Look for `Story Verification records ready` in the output. The script updates existing records in place, so you can rerun it safely, and **must** rerun it after any change to the Function.
3. **Add the Verify action to the page layout.** Add the quick action **Verify** to the User Story page layout. Optionally add `Verification Status`, `Verification Date` and `Verification Details` to the Lightning record page.
4. **Assign permission sets** (see the next section).
5. **Check the repository.** The pipeline's Git repository must show as authenticated in Copado.

The Function source is `function/index.js`. The setup script is generated from it:
```
node scripts/build-create-records.js          # regenerate scripts/create-copado-records.apex
node scripts/build-create-records.js --check  # verify it is up to date
```

## Who gets which permission set

| Who | Permission set(s) | What it gives |
|---|---|---|
| **Developers and anyone who runs Verify** | **Copado Story Verification User** | Access to the Verify popup's Apex and read access to the five `Verification_*` fields. The gate applies to them. |
| **Emergency users who may skip the gate** | **Copado Story Verification Bypass** **and** **Copado Story Verification User** | Bypass switches off all 12 validation rules for the user. They still need User to use the Verify button, otherwise the popup says "You do not have access to this story". |
| **Everyone else** | none | They cannot run Verify, and the gate still blocks their checkboxes. |

Give **Bypass** to as few people as possible. It lets a user tick Ready to Promote and Promote and Deploy with no verification at all.

Nobody has edit access to the result fields. The Apex writes them in system mode, so users cannot hand-edit a verdict.

To assign from the CLI:
```
sf org assign permset --name Copado_Story_Verification_User --target-org <alias> --on-behalf-of <username>
```
There is no CLI command to remove an assignment. Delete the `PermissionSetAssignment` record in Setup instead.

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
scripts/                  setup script generator and the generated create-copado-records.apex
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
