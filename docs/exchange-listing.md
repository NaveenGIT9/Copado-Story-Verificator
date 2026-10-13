# Story Verification Gate: marketplace listing text

*Draft text for a marketplace or partner submission. Items in [square brackets] must be filled in by the publisher.*

## Name
Story Verification Gate for Copado

## One-line description
Blocks **Ready to Promote** and **Promote and Deploy** on a Copado User Story until a live verification of its commits, metadata, pull request and dependencies comes back clean.

## The problem
In a Copado pipeline, nothing stops a story from being marked ready to promote while its branch has commits that were never registered in Copado, changed components that are not on the story, an environment branch merged into the feature branch, a pull request that is not approved, or pending tests. These problems usually surface later, as a failed or incomplete promotion.

## What it does
A **Verify** button on the User Story runs six checks in a live popup, shows each result with the reason, and stores the verdict on the story. Validation rules then only allow the two promotion checkboxes when the verdict is Clean and still current.

| Check | What it catches |
|---|---|
| Unregistered commits | Commits made outside Copado, with extra care for different authors and unregistered components |
| Metadata coverage | Components changed in git that are not registered on the story (they would not deploy) |
| Org / environment branch merge | An environment branch merged into the feature branch |
| Pull request approval | A story whose pull request is not approved |
| Pending tests | A story that still has pending tests |
| Parent story dependencies | A parent story that has not been promoted ahead of its child |

Emergency users can be given a bypass permission set. A verification becomes stale when a newer commit appears.

## How it is built
- A Copado **Function** (Node.js) clones the repository history only (no file contents) and runs the three git checks.
- A Copado **Job Template** starts it. A record-triggered **Flow** writes the result back to the story.
- Apex runs the Salesforce-side checks and feeds the popup. A Lightning Web Component shows the live progress.
- Twelve **validation rules** enforce the gate. Access is controlled by two permission sets.

## Requirements
- Salesforce org with Copado installed, a pipeline, a project and an authenticated Git repository (OAuth supported).
- Permission to deploy metadata and run anonymous Apex once, to create the Copado Function, Job Template and Job Step.

## Install in brief
1. Deploy `manifest/package.xml`.
2. Run `scripts/create-copado-records.apex` once.
3. Add the Verify quick action to the User Story page layout.
4. Assign the permission sets (User for everyone who verifies; Bypass plus User for emergency users).

Full steps are in `README.md`.

## Tested with
Built and run in two Copado orgs: a Copado trial org and a company sandbox, API version 63.0. [Add Copado package version, Salesforce release and repository provider details before submitting.]

## Support, license and owner
- Publisher: [organisation name]
- Contact: [support email or page]
- License: [license, to be chosen by the publisher]
- Repository: [repository URL]
