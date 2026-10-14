import { createElement } from 'lwc';
import StoryVerificationPopup from 'c/storyVerificationPopup';
import { getRecord } from 'lightning/uiRecordApi';
import start from '@salesforce/apex/StoryVerificationController.start';
import getProgress from '@salesforce/apex/StoryVerificationController.getProgress';

jest.mock(
    '@salesforce/apex/StoryVerificationController.start',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/StoryVerificationController.getProgress',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const STORY_ID = 'a0X000000000001AAA';
const STORY_NAME = 'US-0000026';
const RUN_ID = 'run-123';
const TIMEOUT_TEXT = 'Still running. You can close this window; open the story later and check Verification Status.';

const INTRO_ITEMS = [
    'Unregistered commits',
    'Metadata coverage',
    'Pull request approval',
    'Pending tests',
    'Parent story dependencies (and which environment the parent is in)',
    'Org/environment branch merge into the feature branch'
];

const FINDINGS = [
    { severity: 'info', message: 'Registered commits: 1, metadata items: 1.' },
    { severity: 'issue', message: 'No metadata selected on this story.' }
];

const PARENT_OK = 'US-0000010 (base branch) is in INT-SFP - ahead of Dev1-SFP.';
const PARENT_BAD = 'US-0000011 (dependency) is in Dev2-SFP - not ahead of Dev1-SFP; promote it first.';

// Deliberately NOT in display order: the popup must order the rows itself.
const GROUPED_FINDINGS = [
    { severity: 'info', message: PARENT_OK, groupKey: 'parent-dependencies' },
    { severity: 'info', message: 'Registered commits: 1, metadata items: 1.' },
    { severity: 'issue', message: PARENT_BAD, groupKey: 'parent-dependencies' },
    { severity: 'info', message: 'None pending.', groupKey: 'pending-tests' },
    { severity: 'issue', message: 'Not approved yet.', groupKey: 'pull-request' }
];

const FACTS = [
    { label: 'Pending tests', value: '0', state: 'ok' },
    { label: 'Pull request approved', value: 'Yes', state: 'ok' }
];

function snapshot(overrides = {}) {
    return {
        facts: FACTS,
        status: 'Running',
        runId: RUN_ID,
        isFinished: false,
        isCurrentRun: true,
        details: [],
        findings: FINDINGS,
        jobStatus: 'Queued',
        jobError: null,
        progressText: null,
        errorMessage: null,
        ...overrides
    };
}

// Lets pending promise callbacks (Apex mocks, LWC re-render) settle without advancing fake timers.
async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

async function tick(ms = 2000) {
    jest.advanceTimersByTime(ms);
    await flush();
}

// Mounts the popup in its intro phase (nothing has run yet).
function mount() {
    const element = createElement('c-story-verification-popup', { is: StoryVerificationPopup });
    element.recordId = STORY_ID;
    document.body.appendChild(element);
    return element;
}

function byId(element, id) {
    return element.shadowRoot.querySelector(`[data-id="${id}"]`);
}

// Mounts and clicks Verify, so the run has started once the mocked start() has resolved.
async function mountAndVerify() {
    const element = mount();
    await flush();
    byId(element, 'verify').click();
    await flush();
    return element;
}

function stepTexts(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="step"]')).map((li) => li.textContent);
}

function stepTitles(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="step-text"]')).map((span) => span.textContent);
}

function factRows(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="fact"]'));
}

function factTexts(element) {
    return factRows(element).map((span) => span.querySelector('[data-id="fact-text"]').textContent);
}

function separators(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="fact-separator"]'));
}

const CHECKS = [
    {
        id: 'unregistered-commits',
        title: 'Unregistered commits',
        status: 'fail',
        summary: '1 commit(s) made outside Copado change components that are not registered on the story',
        lines: ['abcdef1234 Dev One "quick fix" — uncovered: Account.Foo__c']
    },
    {
        id: 'metadata-coverage',
        title: 'Metadata coverage',
        status: 'pass',
        summary: 'All 2 changed components are registered',
        lines: ['registered on the story but unchanged in git: old__c']
    },
    {
        id: 'org-branch-merge',
        title: 'Org/environment branch merge',
        status: 'warn',
        summary: 'Environment branches not compared',
        lines: ['environment branches not found on the remote (not compared): qa']
    }
];

function finishedSnapshot(checks, overrides = {}) {
    return snapshot({
        status: 'Issues',
        isFinished: true,
        jobStatus: 'Successful',
        details: ['ISSUE: something'],
        checks,
        ...overrides
    });
}

// The li of one step row, found by its title text.
function stepRow(element, title) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="step"]')).find((li) =>
        li.querySelector('[data-id="step-text"]').textContent.startsWith(title)
    );
}

async function mountFinished(checks, overrides) {
    start.mockResolvedValue(snapshot());
    getProgress.mockResolvedValue(finishedSnapshot(checks, overrides));
    const element = await mountAndVerify();
    await tick();
    return element;
}

describe('c-story-verification-popup', () => {
    beforeEach(() => {
        jest.useFakeTimers();
        start.mockReset();
        getProgress.mockReset();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllTimers();
        jest.useRealTimers();
    });

    describe('confirmation screen', () => {
        it('shows the story name loaded by the getRecord wire', async () => {
            const element = mount();
            getRecord.emit({ fields: { Name: { value: STORY_NAME } } });
            await flush();

            expect(byId(element, 'intro-text').textContent).toBe('Verify ' + STORY_NAME + ' for');
        });

        it('shows a fallback text until the story name has loaded', async () => {
            const element = mount();
            await flush();

            expect(byId(element, 'intro-text').textContent).toBe('Verify this story for');
        });

        it('falls back to the generic text when the wire reports an error', async () => {
            const element = mount();
            getRecord.emit({ fields: { Name: { value: STORY_NAME } } });
            await flush();
            getRecord.error();
            await flush();

            expect(byId(element, 'intro-text').textContent).toBe('Verify this story for');
        });

        it('lists the six checks in order as a dotted (bullet) list', async () => {
            const element = mount();
            await flush();

            const list = byId(element, 'intro-list');
            expect(list.tagName).toBe('UL');
            expect(list.classList.contains('slds-list_dotted')).toBe(true);
            const items = Array.from(element.shadowRoot.querySelectorAll('[data-id="intro-item"]')).map(
                (li) => li.textContent
            );
            expect(items).toEqual(INTRO_ITEMS);
        });

        it('has a brand Verify button and a Close button and no run view or retry button', async () => {
            const element = mount();
            await flush();

            expect(byId(element, 'verify')).not.toBeNull();
            expect(byId(element, 'verify').variant).toBe('brand');
            expect(byId(element, 'verify').label).toBe('Verify');
            expect(byId(element, 'close')).not.toBeNull();
            expect(byId(element, 'retry')).toBeNull();
            expect(byId(element, 'state')).toBeNull();
            expect(byId(element, 'steps')).toBeNull();
            expect(byId(element, 'readiness-section')).toBeNull();
        });

        it('sends nothing to Apex before Verify is clicked', async () => {
            mount();
            await flush();
            await tick(10000);

            expect(start).not.toHaveBeenCalled();
            expect(getProgress).not.toHaveBeenCalled();
            expect(jest.getTimerCount()).toBe(0);
        });

        it('starts the run when Verify is clicked and replaces the intro with the run view', async () => {
            start.mockResolvedValue(snapshot());
            getProgress.mockResolvedValue(snapshot());
            const element = mount();
            await flush();

            byId(element, 'verify').click();
            await flush();

            expect(start).toHaveBeenCalledTimes(1);
            expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });
            expect(byId(element, 'intro')).toBeNull();
            expect(byId(element, 'intro-text')).toBeNull();
            expect(byId(element, 'intro-list')).toBeNull();
            expect(byId(element, 'verify')).toBeNull();
            expect(byId(element, 'state')).not.toBeNull();
            expect(byId(element, 'close')).not.toBeNull();
        });

        it('starts only one run when Verify is clicked repeatedly', async () => {
            start.mockResolvedValue(snapshot());
            getProgress.mockResolvedValue(snapshot());
            const element = mount();
            await flush();

            const button = byId(element, 'verify');
            button.click();
            button.click();
            await flush();

            expect(start).toHaveBeenCalledTimes(1);
        });

        it('does nothing when Verify is clicked before a record id is known', async () => {
            const element = createElement('c-story-verification-popup', { is: StoryVerificationPopup });
            document.body.appendChild(element);
            await flush();

            byId(element, 'verify').click();
            await flush();

            expect(start).not.toHaveBeenCalled();
            expect(byId(element, 'intro')).not.toBeNull();
        });

        it('uses the record id set after connecting (quick actions set it late)', async () => {
            start.mockResolvedValue(snapshot());
            getProgress.mockResolvedValue(snapshot());
            const element = createElement('c-story-verification-popup', { is: StoryVerificationPopup });
            document.body.appendChild(element);
            await flush();
            element.recordId = STORY_ID;
            await flush();

            byId(element, 'verify').click();
            await flush();

            expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });
        });

        it('dispatches the close event from the Close button in the intro', async () => {
            const element = mount();
            await flush();
            const handler = jest.fn();
            element.addEventListener('lightning__actionsclosescreen', handler);

            byId(element, 'close').click();

            expect(handler).toHaveBeenCalledTimes(1);
            expect(start).not.toHaveBeenCalled();
        });

        it('keeps the intro hidden after the run finished', async () => {
            const element = await mountFinished(CHECKS);

            expect(byId(element, 'intro')).toBeNull();
            expect(byId(element, 'verify')).toBeNull();
            expect(byId(element, 'retry')).not.toBeNull();
        });
    });

    it('starts the run, shows the running state, then the final Clean result', async () => {
        start.mockResolvedValue(snapshot());
        getProgress
            .mockResolvedValueOnce(snapshot({ jobStatus: 'In Progress', progressText: 'Aggregating findings' }))
            .mockResolvedValueOnce(
                snapshot({
                    status: 'Clean',
                    isFinished: true,
                    jobStatus: 'Successful',
                    details: ['INFO: all good']
                })
            );

        const element = await mountAndVerify();

        expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });
        expect(byId(element, 'state').textContent).toContain('job queued in Copado');
        expect(byId(element, 'state-spinner')).not.toBeNull();
        const steps = stepTexts(element);
        expect(stepTitles(element)[6]).toBe('Copado job: pending');
        expect(steps[0]).toContain('Unregistered commits: pending');
        expect(steps[1]).toContain('Metadata coverage: pending');
        expect(steps[2]).toContain('Pull request approval: pending');
        expect(steps[3]).toContain('Pending tests: pending');
        expect(steps[4]).toContain('Parent story dependencies: pending');
        expect(steps[5]).toContain('Org/environment branch merge: pending');
        expect(steps[6]).toContain('Copado job: pending');
        expect(steps[7]).toContain('Registered commits: 1');
        expect(steps[8]).toContain('No metadata selected');
        expect(byId(element, 'state').textContent).not.toContain('finished');

        await tick();
        expect(getProgress).toHaveBeenCalledWith({ storyId: STORY_ID, runId: RUN_ID });
        expect(byId(element, 'state').textContent).toBe('Aggregating findings');

        await tick();
        expect(getProgress).toHaveBeenCalledTimes(2);
        const verdict = byId(element, 'state');
        expect(verdict.textContent).toBe('Verification finished: Clean');
        expect(verdict.className).toContain('slds-text-color_success');
        expect(byId(element, 'banner')).toBeNull();
        expect(byId(element, 'why-section')).toBeNull();
        expect(byId(element, 'state-spinner')).toBeNull();
        expect(byId(element, 'retry')).not.toBeNull();
        expect(jest.getTimerCount()).toBe(0);

        await tick(10000);
        expect(getProgress).toHaveBeenCalledTimes(2);
    });

    it('shows an amber Issues verdict in the heading and no banner or repeated Why block', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(
            snapshot({
                status: 'Issues',
                isFinished: true,
                jobStatus: 'Successful',
                details: ['ISSUE: No metadata selected on this story.', 'INFO: Registered commits: 1, metadata items: 1.']
            })
        );

        const element = await mountAndVerify();
        await tick();

        const verdict = byId(element, 'state');
        expect(verdict.textContent).toBe('Verification finished: Issues');
        expect(verdict.className).toContain('state-issues');
        expect(byId(element, 'banner')).toBeNull();
        expect(byId(element, 'why-section')).toBeNull();
        expect(byId(element, 'failure')).toBeNull();
    });

    it('shows the job error for a Failed result', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(
            snapshot({
                status: 'Failed',
                isFinished: true,
                jobStatus: 'Failed',
                jobError: 'Function exited with code 1',
                details: ['Verification job failed: Function exited with code 1']
            })
        );

        const element = await mountAndVerify();
        await tick();

        const verdict = byId(element, 'state');
        expect(verdict.textContent).toBe('Verification finished: Failed');
        expect(verdict.className).toContain('slds-text-color_error');
        expect(byId(element, 'failure').textContent).toContain('Function exited with code 1');
        expect(stepTitles(element)).toContain('Copado job: failed');
    });

    describe('job row wording', () => {
        it('reads "Copado job: pending" when queued', async () => {
            start.mockResolvedValue(snapshot());
            getProgress.mockResolvedValue(snapshot());
            const element = await mountAndVerify();

            expect(stepTitles(element)[6]).toBe('Copado job: pending');
        });

        it('reads "Copado job: running" while the job is in progress', async () => {
            start.mockResolvedValue(snapshot());
            getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));
            const element = await mountAndVerify();
            await tick();

            expect(stepTitles(element)[6]).toBe('Copado job: running');
        });

        it('hides the Copado job row once a run has finished with a verdict (Clean or Issues)', async () => {
            const element = await mountFinished(CHECKS);

            expect(stepTitles(element).some((text) => text.startsWith('Copado job'))).toBe(false);
        });
    });

    it('stops polling and says so when a newer run replaced this one', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ runId: 'newer-run', isCurrentRun: false }));

        const element = await mountAndVerify();
        await tick();

        expect(byId(element, 'state').textContent).toContain('newer verification run');
        expect(byId(element, 'state').textContent).not.toContain('Verification finished');
        expect(jest.getTimerCount()).toBe(0);
        await tick(10000);
        expect(getProgress).toHaveBeenCalledTimes(1);
    });

    it('stops after five minutes and tells the user to check the story later', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));

        const element = await mountAndVerify();
        for (let i = 0; i < 160; i++) {
            // eslint-disable-next-line no-await-in-loop
            await tick();
        }

        expect(byId(element, 'state').textContent).toBe(TIMEOUT_TEXT);
        expect(byId(element, 'state-spinner')).toBeNull();
        expect(jest.getTimerCount()).toBe(0);
        const calls = getProgress.mock.calls.length;
        await tick(10000);
        expect(getProgress.mock.calls.length).toBe(calls);
    });

    it('shows an error banner when start fails in Apex', async () => {
        start.mockRejectedValue({ body: { message: 'You do not have access to this story.' } });

        const element = await mountAndVerify();

        expect(byId(element, 'error').textContent).toContain('You do not have access to this story.');
        expect(getProgress).not.toHaveBeenCalled();
        expect(byId(element, 'state-spinner')).toBeNull();
        expect(byId(element, 'retry')).not.toBeNull();
    });

    it('shows the message when start reports that a run is already in progress', async () => {
        start.mockResolvedValue({ errorMessage: 'Verification is already running' });

        const element = await mountAndVerify();

        expect(byId(element, 'error').textContent).toContain('Verification is already running');
        expect(getProgress).not.toHaveBeenCalled();
    });

    it('shows an error banner and stops when polling fails', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockRejectedValue({ body: { message: 'Polling failed' } });

        const element = await mountAndVerify();
        await tick();

        expect(byId(element, 'error').textContent).toContain('Polling failed');
        expect(jest.getTimerCount()).toBe(0);
    });

    it('keeps using the story id captured at the start even if recordId is cleared later', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful' }));
        const element = await mountAndVerify();
        expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });

        element.recordId = undefined; // what the quick action framework can do after opening
        await tick();

        expect(getProgress).toHaveBeenCalledWith({ storyId: STORY_ID, runId: RUN_ID });
    });

    it('clears the poll timer when disconnected', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());

        const element = await mountAndVerify();
        expect(jest.getTimerCount()).toBe(1);

        document.body.removeChild(element);

        expect(jest.getTimerCount()).toBe(0);
        await tick(10000);
        expect(getProgress).not.toHaveBeenCalled();
    });

    it('restarts the whole run directly (no intro) when Verify again is clicked', async () => {
        start.mockResolvedValueOnce(snapshot()).mockResolvedValueOnce(snapshot({ runId: 'run-456' }));
        getProgress
            .mockResolvedValueOnce(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful' }))
            .mockResolvedValue(snapshot({ runId: 'run-456', jobStatus: 'In Progress' }));

        const element = await mountAndVerify();
        await tick();
        expect(byId(element, 'state').textContent).toContain('Verification finished');

        byId(element, 'retry').click();
        await flush();

        expect(start).toHaveBeenCalledTimes(2);
        expect(byId(element, 'intro')).toBeNull();
        expect(byId(element, 'state').textContent).not.toContain('Verification finished');
        expect(byId(element, 'state-spinner')).not.toBeNull();

        await tick();
        expect(getProgress).toHaveBeenLastCalledWith({ storyId: STORY_ID, runId: 'run-456' });
    });

    it('shows the three git checks as pending rows while the job is queued', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());

        const element = await mountAndVerify();

        ['Unregistered commits', 'Metadata coverage', 'Org/environment branch merge'].forEach((title) => {
            const row = stepRow(element, title);
            expect(row).toBeDefined();
            expect(row.textContent).toContain(title + ': pending');
            expect(row.querySelector('lightning-icon').iconName).toBe('utility:clock');
            expect(row.querySelector('[data-id="toggle"]')).toBeNull();
        });
        expect(element.shadowRoot.textContent).not.toContain('phase B');
    });

    it('shows a spinner on the git check rows while the job is in progress', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));

        const element = await mountAndVerify();
        await tick();

        const row = stepRow(element, 'Metadata coverage');
        expect(row.textContent).toContain('Metadata coverage: running');
        expect(row.querySelector('lightning-spinner')).not.toBeNull();
        expect(row.querySelector('lightning-icon')).toBeNull();
    });

    it('shows the Function progress text live in the state line and updates it on every poll', async () => {
        start.mockResolvedValue(snapshot());
        getProgress
            .mockResolvedValueOnce(snapshot({ jobStatus: 'In Progress', progressText: 'Cloning repository…' }))
            .mockResolvedValueOnce(snapshot({ jobStatus: 'In Progress', progressText: 'Checking unregistered commits…' }))
            .mockResolvedValue(snapshot({ jobStatus: 'In Progress', progressText: 'Checking metadata coverage…' }));

        const element = await mountAndVerify();
        await tick();
        expect(byId(element, 'state').textContent).toBe('Cloning repository…');

        await tick();
        expect(byId(element, 'state').textContent).toBe('Checking unregistered commits…');

        await tick();
        expect(byId(element, 'state').textContent).toBe('Checking metadata coverage…');
        expect(byId(element, 'state-spinner')).not.toBeNull();
    });

    it('renders the real result of every check with its icon and summary', async () => {
        const element = await mountFinished(CHECKS);

        const unregistered = stepRow(element, 'Unregistered commits');
        expect(unregistered.querySelector('lightning-icon').iconName).toBe('utility:close');
        expect(unregistered.querySelector('lightning-icon').variant).toBe('error');
        expect(unregistered.querySelector('[data-id="step-text"]').textContent).toBe(
            'Unregistered commits: ' + CHECKS[0].summary
        );

        const metadata = stepRow(element, 'Metadata coverage');
        expect(metadata.querySelector('lightning-icon').iconName).toBe('utility:check');
        expect(metadata.querySelector('lightning-icon').variant).toBe('success');
        expect(metadata.querySelector('[data-id="step-text"]').textContent).toBe(
            'Metadata coverage: All 2 changed components are registered'
        );

        const org = stepRow(element, 'Org/environment branch merge');
        expect(org.querySelector('lightning-icon').iconName).toBe('utility:warning');
        expect(org.querySelector('lightning-icon').variant).toBe('warning');
        expect(byId(element, 'state').textContent).toContain('Issues');
    });

    it('shows an unregistered commit as separate parts: id, author, message and uncovered components', async () => {
        const checks = [
            {
                id: 'unregistered-commits',
                title: 'Unregistered commits',
                status: 'fail',
                summary: '1 commit(s) outside Copado change unregistered components',
                lines: ['plain version'],
                rowsJson: JSON.stringify([
                    { t: 'commit', sha: 'be25d73457', author: 'NaveenBonthu9', subject: 'Update ChatterUtil.cls', comps: ['ChatterUtil.cls', 'Contact.Dup.duplicateRule'], moreComps: 0, note: '' }
                ])
            }
        ];
        const element = await mountFinished(checks);

        const li = stepRow(element, 'Unregistered commits').querySelector('[data-id="check-lines"] li');
        expect(li.querySelector('[data-id="c-sha"]').textContent).toBe('be25d73457');
        expect(li.querySelector('[data-id="c-author"]').textContent).toBe('NaveenBonthu9');
        expect(li.querySelector('[data-id="c-subject"]').textContent).toBe('"Update ChatterUtil.cls"');
        expect(li.querySelector('[data-id="c-comps"]').textContent).toBe('ChatterUtil.cls, Contact.Dup.duplicateRule');
        expect(li.querySelector('[data-id="c-note"]')).toBeNull();
        expect(li.textContent).not.toContain('plain version');
    });

    it('shows the "won\'t deploy" sentence with a warning icon', async () => {
        const checks = [
            {
                id: 'metadata-coverage',
                title: 'Metadata coverage',
                status: 'fail',
                summary: '1 of 2 changed components not registered',
                lines: [],
                rowsJson: JSON.stringify([
                    { t: 'names', label: 'Not registered', items: ['Foo.cls'], more: 0 },
                    { t: 'danger', text: "Their changes won't deploy to target - add them to the story in Copado." }
                ])
            }
        ];
        const element = await mountFinished(checks);

        const items = Array.from(stepRow(element, 'Metadata coverage').querySelectorAll('[data-id="check-lines"] > li'));
        expect(items[0].textContent).toBe('Not registered: Foo.cls');
        expect(items[0].classList.contains('component-names')).toBe(true);
        expect(items[1].classList.contains('danger-line')).toBe(true);
        expect(items[1].querySelector('lightning-icon').iconName).toBe('utility:warning');
        expect(items[1].querySelector('lightning-icon').variant).toBe('error');
        expect(items[1].querySelector('[data-id="danger-text"]').textContent).toContain("won't deploy");
    });

    it('collapses the unchanged registered components into a count and lists them one per line when opened', async () => {
        const checks = [
            {
                id: 'metadata-coverage',
                title: 'Metadata coverage',
                status: 'fail',
                summary: '1 of 2 changed components not registered',
                lines: [],
                rowsJson: JSON.stringify([
                    { t: 'group', label: 'Registered but unchanged in git', count: 3, items: ['Attachment.Body', 'AssetRelationship', 'Account.Name'] }
                ])
            }
        ];
        const element = await mountFinished(checks);
        const row = () => stepRow(element, 'Metadata coverage');

        expect(row().querySelector('[data-id="group-label"]').textContent).toBe('Registered but unchanged in git: 3');
        expect(row().querySelector('[data-id="group-items"]')).toBeNull();
        expect(row().querySelector('[data-id="group-toggle"]').getAttribute('aria-expanded')).toBe('false');

        row().querySelector('[data-id="group-toggle"]').click();
        await tick();
        const listed = Array.from(row().querySelectorAll('[data-id="group-items"] li')).map((li) => li.textContent);
        expect(listed).toEqual(['Attachment.Body', 'AssetRelationship', 'Account.Name']);
        expect(row().querySelector('[data-id="group-toggle"]').getAttribute('aria-expanded')).toBe('true');

        row().querySelector('[data-id="group-toggle"]').click();
        await tick();
        expect(row().querySelector('[data-id="group-items"]')).toBeNull();
    });

    it('lists the unchanged registered components under a heading per metadata type, in different styles', async () => {
        const checks = [
            {
                id: 'metadata-coverage',
                title: 'Metadata coverage',
                status: 'fail',
                summary: 's',
                lines: [],
                rowsJson: JSON.stringify([
                    {
                        t: 'group',
                        label: 'Registered but unchanged in git',
                        count: 3,
                        groups: [
                            { type: 'Custom Object', items: ['Authorization', 'Contact'] },
                            { type: 'Custom Field', items: ['Contact.field1'] }
                        ]
                    }
                ])
            }
        ];
        const element = await mountFinished(checks);
        const row = () => stepRow(element, 'Metadata coverage');

        expect(row().querySelector('[data-id="group-label"]').textContent).toBe('Registered but unchanged in git: 3');
        row().querySelector('[data-id="group-toggle"]').click();
        await tick();

        const entries = Array.from(row().querySelectorAll('[data-id="group-items"] li'));
        expect(entries.map((li) => li.textContent)).toEqual(['Custom Object', 'Authorization', 'Contact', 'Custom Field', 'Contact.field1']);
        expect(entries.map((li) => li.className)).toEqual(['type-heading', 'component-name', 'component-name', 'type-heading', 'component-name']);
    });

    it('falls back to the plain lines when the structured rows are missing or unreadable', async () => {
        const checks = [
            { id: 'metadata-coverage', title: 'Metadata coverage', status: 'fail', summary: 's', lines: ['line one', 'line two'], rowsJson: 'not json' }
        ];
        const element = await mountFinished(checks);

        const items = Array.from(stepRow(element, 'Metadata coverage').querySelectorAll('[data-id="check-lines"] > li')).map((li) => li.textContent);
        expect(items).toEqual(['line one', 'line two']);
    });

    it('splits every check row into a key (shown in capitals by its style) and a value', async () => {
        const element = await mountFinished(CHECKS);

        const row = stepRow(element, 'Unregistered commits');
        expect(row.querySelector('[data-id="step-key"]').textContent).toBe('Unregistered commits: ');
        expect(row.querySelector('[data-id="step-text"]').textContent).toBe(
            'Unregistered commits: 1 commit(s) made outside Copado change components that are not registered on the story'
        );
        const keys = Array.from(element.shadowRoot.querySelectorAll('[data-id="step-key"]')).map((k) => k.textContent);
        expect(keys).toContain('Metadata coverage: ');
        expect(keys).toContain('Org/environment branch merge: ');
    });

    it('puts the not-registered component names on their own line under the headline, in their own style', async () => {
        const checks = [
            {
                id: 'metadata-coverage',
                title: 'Metadata coverage',
                status: 'fail',
                summary: '1 of 2 changed components not registered',
                lines: ['Not registered: Account.Foo__c', "Their changes won't deploy to target - add them to the story in Copado."]
            }
        ];
        const element = await mountFinished(checks);

        const row = stepRow(element, 'Metadata coverage');
        expect(row.querySelector('[data-id="step-text"]').textContent).toBe('Metadata coverage: 1 of 2 changed components not registered');
        const items = Array.from(row.querySelectorAll('[data-id="check-lines"] li'));
        expect(items[0].textContent).toBe('Not registered: Account.Foo__c');
        expect(items[0].classList.contains('component-names')).toBe(true);
        expect(items[1].classList.contains('component-names')).toBe(false);
    });

    it('expands fail and warn checks by default and collapses pass checks', async () => {
        const element = await mountFinished(CHECKS);

        const unregistered = stepRow(element, 'Unregistered commits');
        expect(unregistered.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('true');
        expect(unregistered.querySelector('[data-id="check-lines"]').textContent).toContain('abcdef1234 Dev One');

        const org = stepRow(element, 'Org/environment branch merge');
        expect(org.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('true');
        expect(org.querySelector('[data-id="check-lines"]')).not.toBeNull();

        const metadata = stepRow(element, 'Metadata coverage');
        expect(metadata.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('false');
        expect(metadata.querySelector('[data-id="check-lines"]')).toBeNull();
    });

    it('toggles a check open and closed with the details button', async () => {
        const element = await mountFinished(CHECKS);

        stepRow(element, 'Metadata coverage').querySelector('[data-id="toggle"]').click();
        await flush();
        let metadata = stepRow(element, 'Metadata coverage');
        expect(metadata.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('true');
        expect(metadata.querySelector('[data-id="check-lines"]').textContent).toContain('unchanged in git: old__c');

        metadata.querySelector('[data-id="toggle"]').click();
        await flush();
        metadata = stepRow(element, 'Metadata coverage');
        expect(metadata.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('false');
        expect(metadata.querySelector('[data-id="check-lines"]')).toBeNull();

        stepRow(element, 'Unregistered commits').querySelector('[data-id="toggle"]').click();
        await flush();
        const unregistered = stepRow(element, 'Unregistered commits');
        expect(unregistered.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('false');
        expect(unregistered.querySelector('[data-id="check-lines"]')).toBeNull();
    });

    it('shows skipped checks with a grey dash, their reason and no toggle when there are no lines', async () => {
        const reason = 'skipped because an environment branch merge brings in unrelated commits';
        const checks = [
            { id: 'unregistered-commits', title: 'Unregistered commits', status: 'skipped', summary: reason, lines: [] },
            { id: 'metadata-coverage', title: 'Metadata coverage', status: 'skipped', summary: reason, lines: [] },
            {
                id: 'org-branch-merge',
                title: 'Org/environment branch merge',
                status: 'fail',
                summary: 'Environment branch merged into the feature branch: main',
                lines: ['merged main in commit 0123456789']
            }
        ];
        const element = await mountFinished(checks);

        const unregistered = stepRow(element, 'Unregistered commits');
        expect(unregistered.querySelector('lightning-icon').iconName).toBe('utility:dash');
        expect(unregistered.querySelector('[data-id="step-text"]').textContent).toBe('Unregistered commits: ' + reason);
        expect(unregistered.querySelector('[data-id="step-text"]').className).toContain('slds-text-color_weak');
        expect(unregistered.querySelector('[data-id="toggle"]')).toBeNull();
        expect(stepRow(element, 'Metadata coverage').querySelector('lightning-icon').iconName).toBe('utility:dash');
        expect(stepRow(element, 'Org/environment branch merge').querySelector('lightning-icon').iconName).toBe(
            'utility:close'
        );
    });

    it('treats an unknown check status as skipped', async () => {
        const element = await mountFinished([
            { id: 'metadata-coverage', title: 'Metadata coverage', status: 'weird', summary: 'odd', lines: [] }
        ]);

        expect(stepRow(element, 'Metadata coverage').querySelector('lightning-icon').iconName).toBe('utility:dash');
    });

    it('shows the failure prominently and marks the git checks as not reported for a Failed run', async () => {
        const element = await mountFinished([], {
            status: 'Failed',
            jobStatus: 'Failed',
            jobError: 'Could not clone the repository',
            details: ['Verification job failed: Could not clone the repository']
        });

        expect(byId(element, 'state').className).toContain('slds-text-color_error');
        expect(byId(element, 'failure').textContent).toContain('Could not clone the repository');
        const row = stepRow(element, 'Unregistered commits');
        expect(row.querySelector('[data-id="step-text"]').textContent).toBe(
            'Unregistered commits: no result was reported'
        );
        expect(row.querySelector('lightning-icon').iconName).toBe('utility:dash');
    });

    it('shows only the reason (the NOTE lines) in the failure box, not the whole details text', async () => {
        const element = await mountFinished([], {
            status: 'Failed',
            jobStatus: 'Successful',
            jobError: null,
            details: [
                'NOTE: No base branch was found on the remote (tried: feature/US-1, main, master).',
                'ISSUE: Not approved yet.',
                'INFO: None pending.',
                'Unregistered commits: SKIPPED — Not run: branches not available'
            ]
        });

        const text = byId(element, 'failure').textContent;
        expect(text).toContain('No base branch was found on the remote');
        expect(text).not.toContain('NOTE:');
        expect(text).not.toContain('ISSUE:');
        expect(text).not.toContain('INFO:');
        expect(text).not.toContain('SKIPPED');
        expect(byId(element, 'failure').className).toContain('failure-text');
    });

    it('shows how long a finished run took, at the bottom right', async () => {
        const element = await mountFinished(CHECKS);

        const timeTaken = byId(element, 'time-taken');
        expect(timeTaken.textContent).toMatch(/^Time taken: \d+ s$/);
        expect(timeTaken.className).toContain('slds-text-align_right');
    });

    it('shows the time taken in minutes and seconds for a long run', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));
        const element = await mountAndVerify();
        for (let i = 0; i < 36; i++) {
            // eslint-disable-next-line no-await-in-loop
            await tick();
        }
        expect(byId(element, 'time-taken')).toBeNull(); // nothing shown until the run has finished

        getProgress.mockResolvedValue(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful' }));
        await tick();

        expect(byId(element, 'time-taken').textContent).toMatch(/^Time taken: 1 min \d+ s$/);
    });

    it('says Copado is starting the job (and for how long) while its own queue text shows', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress', progressText: 'Accepted by Backend. Scheduling.' }));
        const element = await mountAndVerify();
        await tick();

        const state = byId(element, 'state').textContent;
        expect(state).toMatch(/^Waiting for Copado to start the job \(Accepted by Backend\. Scheduling\)/);
        expect(state).toMatch(/\d+ s$/);
    });

    it('splits a long total into Copado queue time and the checks when the function reported its run time', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));
        const element = await mountAndVerify();
        for (let i = 0; i < 60; i++) {
            // eslint-disable-next-line no-await-in-loop
            await tick();
        }
        getProgress.mockResolvedValue(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful', scriptSeconds: 18 }));
        await tick();

        const text = byId(element, 'time-taken').textContent;
        expect(text).toMatch(/^Time taken: 2 min \d+ s \(Copado queue 1 min \d+ s \+ checks 18 s\)$/);
    });

    it('does not split a short run into queue and checks', async () => {
        const element = await mountFinished(CHECKS, { scriptSeconds: 3 });

        expect(byId(element, 'time-taken').textContent).toMatch(/^Time taken: \d+ s$/);
    });

    it('shows no time taken while the run is still going', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));
        const element = await mountAndVerify();
        await tick();

        expect(byId(element, 'time-taken')).toBeNull();
    });

    it('shows the time taken for a Failed run too', async () => {
        const element = await mountFinished([], {
            status: 'Failed',
            jobStatus: 'Failed',
            jobError: 'Function exited with code 1',
            details: ['Verification job failed: Function exited with code 1']
        });

        expect(byId(element, 'time-taken').textContent).toMatch(/^Time taken: \d+ s$/);
    });

    it('keeps the Copado job row visible when the run Failed, to help explain what happened', async () => {
        const element = await mountFinished([], {
            status: 'Failed',
            jobStatus: 'Failed',
            jobError: 'Function exited with code 1',
            details: ['Verification job failed: Function exited with code 1']
        });

        expect(stepTitles(element)).toContain('Copado job: failed');
    });

    it('shows the failure text from the details when there is no job error', async () => {
        const element = await mountFinished([], {
            status: 'Failed',
            jobStatus: 'Successful',
            jobError: null,
            details: ['The git checks did not report a result (nothing was verified from git).']
        });

        expect(byId(element, 'failure').textContent).toContain('nothing was verified from git');
    });

    it('does not show the failure block for Clean or Issues results', async () => {
        const element = await mountFinished(CHECKS);

        expect(byId(element, 'failure')).toBeNull();
    });

    describe('one fixed list of checks', () => {
        const EXPECTED_ORDER_PREFIXES = [
            'Unregistered commits',
            'Metadata coverage',
            'Pull request approval',
            'Pending tests',
            'Parent story dependencies',
            'Org/environment branch merge',
            'Copado job',
            'Registered commits'
        ];

        it('orders the rows like the confirmation screen while the job is running', async () => {
            start.mockResolvedValue(snapshot({ findings: GROUPED_FINDINGS }));
            getProgress.mockResolvedValue(snapshot({ findings: GROUPED_FINDINGS, jobStatus: 'In Progress' }));

            const element = await mountAndVerify();
            await tick();

            const titles = stepTitles(element);
            expect(titles).toHaveLength(EXPECTED_ORDER_PREFIXES.length);
            EXPECTED_ORDER_PREFIXES.forEach((prefix, index) => {
                expect(titles[index].startsWith(prefix)).toBe(true);
            });
            // Git checks still running, grouped Apex rows already known.
            expect(titles[0]).toBe('Unregistered commits: running');
            expect(titles[5]).toBe('Org/environment branch merge: running');
        });

        it('puts passed checks first and failed checks last once the run has finished', async () => {
            const element = await mountFinished(CHECKS, { findings: GROUPED_FINDINGS });

            const rank = { 'utility:check': 0, 'utility:warning': 1, 'utility:dash': 2, 'utility:close': 3 };
            const ranks = Array.from(element.shadowRoot.querySelectorAll('[data-id="step"]')).map(
                (li) => rank[li.querySelector('lightning-icon').iconName]
            );
            expect(ranks).toHaveLength(EXPECTED_ORDER_PREFIXES.length - 1); // the technical job row is hidden once finished
            expect(ranks).toEqual([...ranks].sort((a, b) => a - b));
            expect(ranks[0]).toBe(0);
            expect(ranks[ranks.length - 1]).toBe(3);
        });

        it('does not reorder rows while the job is still running', async () => {
            start.mockResolvedValue(snapshot({ findings: GROUPED_FINDINGS }));
            getProgress.mockResolvedValue(snapshot({ findings: GROUPED_FINDINGS, jobStatus: 'In Progress' }));

            const element = await mountAndVerify();
            await tick();

            const titles = stepTitles(element);
            EXPECTED_ORDER_PREFIXES.forEach((prefix, index) => {
                expect(titles[index].startsWith(prefix)).toBe(true);
            });
        });

        it('accepts the group on a key named group as well', async () => {
            start.mockResolvedValue(
                snapshot({ findings: [{ severity: 'issue', message: 'Not approved yet.', group: 'pull-request' }] })
            );
            getProgress.mockResolvedValue(snapshot());

            const element = await mountAndVerify();

            expect(stepTitles(element)[2]).toBe('Pull request approval: Not approved yet.');
        });

        it('shows one grouped parent row with an issue icon and the counts when several parents differ', async () => {
            const element = await mountFinished(CHECKS, { findings: GROUPED_FINDINGS });

            const parentRows = Array.from(element.shadowRoot.querySelectorAll('[data-id="step"]')).filter((li) =>
                li.querySelector('[data-id="step-text"]').textContent.startsWith('Parent story dependencies')
            );
            expect(parentRows).toHaveLength(1);
            const row = parentRows[0];
            expect(row.querySelector('[data-id="step-text"]').textContent).toBe(
                'Parent story dependencies: 2 parent stories — 1 need attention'
            );
            expect(row.querySelector('[data-id="step-text"]').className).toContain('slds-text-color_error');
            expect(row.querySelector('lightning-icon').iconName).toBe('utility:close');
            expect(row.querySelector('lightning-icon').variant).toBe('error');
            expect(row.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('true');
            const lines = Array.from(row.querySelectorAll('[data-id="check-lines"] li')).map((li) => li.textContent);
            expect(lines).toEqual([PARENT_OK, PARENT_BAD]);
        });

        it('collapses and re-expands the grouped parent details with the toggle', async () => {
            const element = await mountFinished(CHECKS, { findings: GROUPED_FINDINGS });

            stepRow(element, 'Parent story dependencies').querySelector('[data-id="toggle"]').click();
            await flush();
            let row = stepRow(element, 'Parent story dependencies');
            expect(row.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('false');
            expect(row.querySelector('[data-id="check-lines"]')).toBeNull();

            row.querySelector('[data-id="toggle"]').click();
            await flush();
            row = stepRow(element, 'Parent story dependencies');
            expect(row.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('true');
            expect(row.querySelector('[data-id="check-lines"]')).not.toBeNull();
        });

        it('shows a green check and "all ahead" when every parent is fine, details collapsed', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [
                    { severity: 'info', message: PARENT_OK, groupKey: 'parent-dependencies' },
                    {
                        severity: 'info',
                        message: 'US-0000012 (base branch + dependency) is in UAT-SFP - ahead of INT-SFP.',
                        groupKey: 'parent-dependencies'
                    }
                ]
            });

            const row = stepRow(element, 'Parent story dependencies');
            expect(row.querySelector('[data-id="step-text"]').textContent).toBe(
                'Parent story dependencies: 2 parent stories, all ahead'
            );
            expect(row.querySelector('lightning-icon').iconName).toBe('utility:check');
            expect(row.querySelector('lightning-icon').variant).toBe('success');
            expect(row.querySelector('[data-id="toggle"]').getAttribute('aria-expanded')).toBe('false');
            expect(row.querySelector('[data-id="check-lines"]')).toBeNull();
        });

        it('shows a single short grouped message as "Title: message" without a toggle', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [{ severity: 'info', message: 'None.', groupKey: 'parent-dependencies' }]
            });

            const row = stepRow(element, 'Parent story dependencies');
            expect(row.querySelector('[data-id="step-text"]').textContent).toBe('Parent story dependencies: None.');
            expect(row.querySelector('lightning-icon').iconName).toBe('utility:check');
            expect(row.querySelector('[data-id="toggle"]')).toBeNull();
        });

        it('never gives a single long grouped message a toggle or a details list', async () => {
            const longMessage = PARENT_BAD + ' ' + 'x'.repeat(200);
            const element = await mountFinished(CHECKS, {
                findings: [
                    { severity: 'issue', message: PARENT_BAD, groupKey: 'parent-dependencies' },
                    { severity: 'issue', message: longMessage, groupKey: 'pull-request' }
                ]
            });

            const parent = stepRow(element, 'Parent story dependencies');
            expect(parent.querySelector('[data-id="step-text"]').textContent).toBe(
                'Parent story dependencies: ' + PARENT_BAD
            );
            expect(parent.querySelector('lightning-icon').iconName).toBe('utility:close');
            expect(parent.querySelector('[data-id="toggle"]')).toBeNull();
            expect(parent.querySelector('[data-id="check-lines"]')).toBeNull();

            const pullRequest = stepRow(element, 'Pull request approval');
            expect(pullRequest.querySelector('[data-id="step-text"]').textContent).toBe(
                'Pull request approval: ' + longMessage
            );
            expect(pullRequest.querySelector('[data-id="toggle"]')).toBeNull();
            expect(pullRequest.querySelector('[data-id="check-lines"]')).toBeNull();
        });

        it('does not repeat the title when the single message already starts with it', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [{ severity: 'info', message: 'Pending tests: 0.', groupKey: 'pending-tests' }]
            });

            expect(stepRow(element, 'Pending tests').querySelector('[data-id="step-text"]').textContent).toBe(
                'Pending tests: 0.'
            );
        });

        it('renders the pull request and pending tests rows from their groups', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [
                    { severity: 'issue', message: 'Not approved yet.', groupKey: 'pull-request' },
                    { severity: 'issue', message: '3 pending - must be 0.', groupKey: 'pending-tests' }
                ]
            });

            const pullRequest = stepRow(element, 'Pull request approval');
            expect(pullRequest.querySelector('[data-id="step-text"]').textContent).toBe(
                'Pull request approval: Not approved yet.'
            );
            expect(pullRequest.querySelector('lightning-icon').iconName).toBe('utility:close');
            expect(pullRequest.querySelector('[data-id="toggle"]')).toBeNull();

            const pending = stepRow(element, 'Pending tests');
            expect(pending.querySelector('[data-id="step-text"]').textContent).toBe(
                'Pending tests: 3 pending - must be 0.'
            );
            expect(pending.querySelector('lightning-icon').iconName).toBe('utility:close');
            expect(pending.querySelector('lightning-icon').variant).toBe('error');
            expect(pending.querySelector('[data-id="toggle"]')).toBeNull();
        });

        it('renders passing pull request and pending tests rows with a green check', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [
                    { severity: 'info', message: 'Approved.', groupKey: 'pull-request' },
                    { severity: 'info', message: 'None pending.', groupKey: 'pending-tests' }
                ]
            });

            const pullRequest = stepRow(element, 'Pull request approval');
            expect(pullRequest.querySelector('[data-id="step-text"]').textContent).toBe(
                'Pull request approval: Approved.'
            );
            expect(pullRequest.querySelector('lightning-icon').iconName).toBe('utility:check');
            const pending = stepRow(element, 'Pending tests');
            expect(pending.querySelector('[data-id="step-text"]').textContent).toBe('Pending tests: None');
            expect(pending.querySelector('lightning-icon').iconName).toBe('utility:check');
        });

        it('still shows ungrouped findings after the job row, with icons by severity', async () => {
            const element = await mountFinished(CHECKS, {
                findings: [
                    { severity: 'info', message: 'Registered commits: 1, metadata items: 1.' },
                    { severity: 'issue', message: 'Story has no pipeline; git checks could not run.' },
                    { severity: 'info', message: 'Approved.', groupKey: 'pull-request' }
                ]
            });

            const titles = stepTitles(element);
            expect(titles).toHaveLength(8); // six fixed rows, then the two ungrouped findings (no job row once finished)
            expect(titles).toContain('Registered commits: 1, metadata items: 1.');
            // The failed ungrouped finding sorts to the bottom with the other failures.
            expect(titles[7]).toBe('Story has no pipeline; git checks could not run.');
            const issueRow = stepRow(element, 'Story has no pipeline');
            expect(titles).toContain('Story has no pipeline; git checks could not run.');
            expect(issueRow.querySelector('lightning-icon').iconName).toBe('utility:close');
            expect(stepRow(element, 'Registered commits').querySelector('lightning-icon').iconName).toBe(
                'utility:check'
            );
        });

        it('shows the grouped rows as pending when no findings have arrived yet', async () => {
            start.mockResolvedValue(snapshot({ findings: [] }));
            getProgress.mockResolvedValue(snapshot({ findings: [] }));

            const element = await mountAndVerify();

            expect(stepTitles(element).slice(0, 6)).toEqual([
                'Unregistered commits: pending',
                'Metadata coverage: pending',
                'Pull request approval: pending',
                'Pending tests: pending',
                'Parent story dependencies: pending',
                'Org/environment branch merge: pending'
            ]);
        });
    });

    it('dispatches the close event from the Close button during a run', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());
        const element = await mountAndVerify();
        const handler = jest.fn();
        element.addEventListener('lightning__actionsclosescreen', handler);

        byId(element, 'close').click();

        expect(handler).toHaveBeenCalledTimes(1);
    });
});
