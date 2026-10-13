# Shorter, stronger messages (Apex findings + popup)

Project: D:\copado-story-verification (standalone SFDX, API 63.0, org alias `360`). You have NO shell: cannot compile, run Jest or deploy; re-read your work and report what you could not verify. Do NOT touch function/index.js, scripts/, validation rules, flows or quick actions (the Function's own wording is already shortened). Read the current StoryVerificationService.cls / StoryVerificationController.cls, their tests and lwc/storyVerificationPopup (html, js, css, __tests__).

Goal: every message the user sees is short and striking but loses no information. Rules: no repeated information (a row's detail list must add something beyond its own one-line message), no filler words ("was", "have been", "for this story" unless needed), keep names/environments/numbers.

## 1. Apex finding wording (StoryVerificationService; update every test that asserts the old text, including ControllerTest, CompleteTest and the Jest fixtures that copy these strings)
Parent story findings (group `parent-dependencies`). The via label loses the relationship type and the word "via": base-branch parent -> `base branch`; dependency parent -> `dependency`; both -> `base branch + dependency`. Messages:
- ahead (info): `<Name> (<via>) is in <ParentEnv> — ahead of <ChildEnv>.`
- not ahead (issue): `<Name> (<via>) is in <ParentEnv> — not ahead of <ChildEnv>; promote it first.`
- parent has no environment (issue): `<Name> (<via>) has no environment yet; promote it first.`
- fallback when no pipeline order: promoted (info) `<Name> (<via>) is in <ParentEnv>, already promoted.`; not promoted (issue) `<Name> (<via>) is in <ParentEnv>, not promoted yet; promote it first.`
- completed parent: same text as ahead.
- base-branch name that names no story (info): `Base branch <branch> names no story (<name> not found).`
- no parents at all (info): `None.`
(Use an em dash character exactly as shown, written as the same escape/character style the file already uses for non-ASCII; if the file is ASCII-only use " - " instead and keep the tests consistent.)
Other findings:
- Pull request: info `Approved.`; issue `Not approved yet.`
- Pending tests: info `None pending.`; issue `<n> pending — must be 0.` (n without a trailing .0; null counts as 0).
- Commit summary (info): `Registered commits: <c>, metadata items: <m>.` and with others `Registered commits: <c> (+<k> not Complete), metadata items: <m>.`
- No complete commits (issue): `No registered commits.`; when other records exist `No Complete commits (<k> other record(s), e.g. "Commit not in branch").`
- No metadata (issue): `No metadata selected on this story.`
- No pipeline (issue): `Story has no pipeline; git checks could not run.`
- Truncation note (info): `Lists cut at <N> entries to fit the job size; git checks may be incomplete.`
Keep all severities, groups, counts of findings and their order unchanged. Keep the `pullRequestApprovedOverride` hook usage.

## 2. Popup (LWC) layout
- Job row text: `Copado job: pending|running|done|failed` (was `Verification job in Copado: ...`).
- Grouped findings: a group with ONE finding is a plain row `Title: message` and NEVER gets a details toggle (remove the "long single message gets a toggle" rule); a group with several findings keeps the summary row plus the toggle listing them (expanded when any is an issue). A row's title prefix is not repeated when the message already starts with it.
- Git-check rows: keep the one-line summary and the toggle only when the check has detail lines. (The Function now sends detail lines only when they add information.)
- Compact "Promotion readiness": replace the section (heading + one row per fact) by ONE line directly under the check list, hidden when there are no facts: `Live now:` followed by each fact as `<icon> <label> <value>` separated by ` · ` (for example `Live now: ✓ Pending tests 0 · ✗ Pull request approved No`), using lightning-icon (green check / red cross, size x-small, with alternative-text) and the same red text class for an issue. Keep `data-id="readiness-section"` on the line and `data-id="fact"` on each fact so the live-update behaviour stays testable.
- Update every Jest test and fixture string that depends on the old wording or on the old readiness layout; add tests for: a single long grouped message has no toggle, the job row wording, the compact readiness line (separator, icons, hidden when empty, updates on the next poll).

## Report back
Files changed, what you could not verify, anything you think is wrong or risky.
