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

function snapshot(overrides = {}) {
    return {
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
        expect(steps[3]).toContain('Not yet implemented (phase B)');
        expect(byId(element, 'banner')).toBeNull();

        await tick();
        expect(getProgress).toHaveBeenCalledWith({ storyId: STORY_ID, runId: RUN_ID });
        expect(byId(element, 'state').textContent).toContain('running in Copado');
        expect(byId(element, 'state').textContent).toContain('Aggregating findings');

        await tick();
        expect(getProgress).toHaveBeenCalledTimes(2);
        const banner = byId(element, 'banner');
        expect(banner.textContent).toContain('Clean');
        expect(banner.className).toContain('slds-theme_success');
        expect(byId(element, 'why').textContent).toContain('INFO: all good');
        expect(byId(element, 'state-spinner')).toBeNull();
        expect(byId(element, 'retry')).not.toBeNull();
        expect(jest.getTimerCount()).toBe(0);

        await tick(10000);
        expect(getProgress).toHaveBeenCalledTimes(2);
    });

    it('shows the why lines for a final Issues result and emphasises ISSUE lines', async () => {
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

        const banner = byId(element, 'banner');
        expect(banner.textContent).toContain('Issues');
        expect(banner.className).toContain('slds-theme_warning');
        const lines = element.shadowRoot.querySelectorAll('[data-id="why"] li');
        expect(lines).toHaveLength(2);
        expect(lines[0].textContent).toBe('ISSUE: No metadata is selected on this story.');
        expect(lines[0].className).toContain('slds-text-color_error');
        expect(lines[1].className).not.toContain('slds-text-color_error');
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

        const banner = byId(element, 'banner');
        expect(banner.textContent).toContain('Failed');
        expect(banner.className).toContain('slds-theme_error');
        expect(byId(element, 'why').textContent).toContain('Function exited with code 1');
        expect(stepTexts(element).some((text) => text.includes('Verification job in Copado: failed'))).toBe(true);
    });

    it('stops polling and says so when a newer run replaced this one', async () => {
        start.mockResolvedValue(snapshot());
        getProgress.mockResolvedValue(snapshot({ runId: 'newer-run', isCurrentRun: false }));

        const element = mount();
        await flush();
        await tick();

        expect(byId(element, 'state').textContent).toContain('newer verification run');
        expect(byId(element, 'banner')).toBeNull();
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
        expect(byId(element, 'banner')).not.toBeNull();

        byId(element, 'retry').click();
        await flush();

        expect(start).toHaveBeenCalledTimes(2);
        expect(byId(element, 'banner')).toBeNull();
        expect(byId(element, 'state-spinner')).not.toBeNull();

        await tick();
        expect(getProgress).toHaveBeenLastCalledWith({ storyId: STORY_ID, runId: 'run-456' });
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
