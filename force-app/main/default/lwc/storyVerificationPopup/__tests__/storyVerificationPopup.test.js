import { createElement } from 'lwc';
import StoryVerificationPopup from 'c/storyVerificationPopup';
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
const RUN_ID = 'run-123';
const TIMEOUT_TEXT = 'Still running. You can close this window; open the story later and check Verification Status.';

const FINDINGS = [
    { severity: 'info', message: 'Registered commits: 1, selected metadata items: 1.' },
    { severity: 'issue', message: 'No metadata is selected on this story.' }
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

function mount() {
    const element = createElement('c-story-verification-popup', { is: StoryVerificationPopup });
    element.recordId = STORY_ID;
    document.body.appendChild(element);
    return element;
}

function byId(element, id) {
    return element.shadowRoot.querySelector(`[data-id="${id}"]`);
}

function stepTexts(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="step"]')).map((li) => li.textContent);
}

function factRows(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[data-id="fact"]'));
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
    const element = mount();
    await flush();
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

        const element = mount();
        await flush();

        expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });
        expect(byId(element, 'state').textContent).toContain('job queued in Copado');
        expect(byId(element, 'state-spinner')).not.toBeNull();
        const steps = stepTexts(element);
        expect(steps[0]).toContain('Registered commits: 1');
        expect(steps[1]).toContain('No metadata is selected');
        expect(steps[2]).toContain('Verification job in Copado');
        expect(steps[3]).toContain('Unregistered commits: pending');
        expect(steps[4]).toContain('Metadata coverage: pending');
        expect(steps[5]).toContain('Org/environment branch merge: pending');
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
                details: ['ISSUE: No metadata is selected on this story.', 'INFO: Registered commits: 1.']
            })
        );

        const element = mount();
        await flush();
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

        const element = mount();
        await flush();
        await tick();

        const verdict = byId(element, 'state');
        expect(verdict.textContent).toBe('Verification finished: Failed');
        expect(verdict.className).toContain('slds-text-color_error');
        expect(byId(element, 'failure').textContent).toContain('Function exited with code 1');
        expect(stepTexts(element).some((text) => text.includes('Verification job in Copado: failed'))).toBe(true);
    });

    it('stops polling and says so when a newer run replaced this one', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ runId: 'newer-run', isCurrentRun: false }));

        const element = mount();
        await flush();
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

        const element = mount();
        await flush();
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

        const element = mount();
        await flush();

        expect(byId(element, 'error').textContent).toContain('You do not have access to this story.');
        expect(getProgress).not.toHaveBeenCalled();
        expect(byId(element, 'state-spinner')).toBeNull();
    });

    it('shows the message when start reports that a run is already in progress', async () => {
        start.mockResolvedValue({ errorMessage: 'Verification is already running' });

        const element = mount();
        await flush();

        expect(byId(element, 'error').textContent).toContain('Verification is already running');
        expect(getProgress).not.toHaveBeenCalled();
    });

    it('shows an error banner and stops when polling fails', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockRejectedValue({ body: { message: 'Polling failed' } });

        const element = mount();
        await flush();
        await tick();

        expect(byId(element, 'error').textContent).toContain('Polling failed');
        expect(jest.getTimerCount()).toBe(0);
    });
    it('waits for the record id before starting (quick actions set it after connecting)', async () => {
        const element = createElement('c-story-verification-popup', { is: StoryVerificationPopup });
        document.body.appendChild(element);
        await Promise.resolve();
        expect(start).not.toHaveBeenCalled();

        start.mockResolvedValue(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful', details: ['INFO: ok'] }));
        element.recordId = STORY_ID;
        await flush();

        expect(start).toHaveBeenCalledTimes(1);
        expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });
    });
    it('keeps using the story id captured at the start even if recordId is cleared later', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful' }));
        const element = mount();
        await flush();
        expect(start).toHaveBeenCalledWith({ storyId: STORY_ID });

        element.recordId = undefined; // what the quick action framework can do after opening
        await tick();

        expect(getProgress).toHaveBeenCalledWith({ storyId: STORY_ID, runId: RUN_ID });
    });



    it('clears the poll timer when disconnected', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());

        const element = mount();
        await flush();
        expect(jest.getTimerCount()).toBe(1);

        document.body.removeChild(element);

        expect(jest.getTimerCount()).toBe(0);
        await tick(10000);
        expect(getProgress).not.toHaveBeenCalled();
    });

    it('restarts the whole run when Verify again is clicked', async () => {
        start.mockResolvedValueOnce(snapshot()).mockResolvedValueOnce(snapshot({ runId: 'run-456' }));
        getProgress
            .mockResolvedValueOnce(snapshot({ status: 'Clean', isFinished: true, jobStatus: 'Successful' }))
            .mockResolvedValue(snapshot({ runId: 'run-456', jobStatus: 'In Progress' }));

        const element = mount();
        await flush();
        await tick();
        expect(byId(element, 'state').textContent).toContain('Verification finished');

        byId(element, 'retry').click();
        await flush();

        expect(start).toHaveBeenCalledTimes(2);
        expect(byId(element, 'state').textContent).not.toContain('Verification finished');
        expect(byId(element, 'state-spinner')).not.toBeNull();

        await tick();
        expect(getProgress).toHaveBeenLastCalledWith({ storyId: STORY_ID, runId: 'run-456' });
    });

    it('renders the promotion readiness rows with ok and issue icons', async () => {
        start.mockResolvedValue(
            snapshot({
                facts: [
                    { label: 'Pending tests', value: '3', state: 'issue' },
                    { label: 'Pull request approved', value: 'Yes', state: 'ok' }
                ]
            })
        );
        getProgress.mockResolvedValue(snapshot());

        const element = mount();
        await flush();

        expect(element.shadowRoot.textContent).toContain('Promotion readiness');
        const rows = factRows(element);
        expect(rows).toHaveLength(2);
        expect(rows[0].textContent).toBe('Pending tests: 3');
        expect(rows[0].querySelector('lightning-icon').iconName).toBe('utility:close');
        expect(rows[0].querySelector('lightning-icon').variant).toBe('error');
        expect(rows[1].textContent).toBe('Pull request approved: Yes');
        expect(rows[1].querySelector('lightning-icon').iconName).toBe('utility:check');
        expect(rows[1].querySelector('lightning-icon').variant).toBe('success');
    });

    it('updates the readiness rows on the next poll', async () => {
        start.mockResolvedValue(
            snapshot({
                facts: [
                    { label: 'Pending tests', value: '2', state: 'issue' },
                    { label: 'Pull request approved', value: 'No', state: 'issue' }
                ]
            })
        );
        getProgress.mockResolvedValue(snapshot({ jobStatus: 'In Progress' }));

        const element = mount();
        await flush();
        expect(factRows(element).map((li) => li.textContent)).toEqual([
            'Pending tests: 2',
            'Pull request approved: No'
        ]);

        await tick();

        expect(factRows(element).map((li) => li.textContent)).toEqual([
            'Pending tests: 0',
            'Pull request approved: Yes'
        ]);
        expect(factRows(element)[0].querySelector('lightning-icon').iconName).toBe('utility:check');
    });

    it('hides the readiness section when there are no facts', async () => {
        start.mockResolvedValue(snapshot({ facts: [] }));
        getProgress.mockResolvedValue(snapshot({ facts: [] }));

        const element = mount();
        await flush();

        expect(byId(element, 'readiness-section')).toBeNull();
        expect(element.shadowRoot.textContent).not.toContain('Promotion readiness');
    });

    it('shows the three git checks as pending rows while the job is queued', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());

        const element = mount();
        await flush();

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

        const element = mount();
        await flush();
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

        const element = mount();
        await flush();
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

    it('dispatches the close event from the Close button', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot());
        const element = mount();
        await flush();
        const handler = jest.fn();
        element.addEventListener('lightning__actionsclosescreen', handler);

        byId(element, 'close').click();

        expect(handler).toHaveBeenCalledTimes(1);
    });
});
