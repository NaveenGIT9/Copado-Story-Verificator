import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import start from '@salesforce/apex/StoryVerificationController.start';
import getProgress from '@salesforce/apex/StoryVerificationController.getProgress';

const POLL_INTERVAL_MS = 2000;
const MAX_POLL_MS = 5 * 60 * 1000;

const TIMEOUT_TEXT = 'Still running. You can close this window; open the story later and check Verification Status.';
const SUPERSEDED_TEXT =
    'A newer verification run has replaced this one. Close this window and open the story to see the latest result.';

const BANNER_CLASS = {
    Clean: 'slds-notify slds-notify_alert slds-theme_success',
    Issues: 'slds-notify slds-notify_alert slds-theme_warning',
    Failed: 'slds-notify slds-notify_alert slds-theme_error'
};

export default class StoryVerificationPopup extends LightningElement {
    @api recordId;

    snapshot;
    errorText;
    starting = false;
    timedOut = false;
    superseded = false;

    _timer;
    _runId;
    _startedAt = 0;
    // Bumped on every (re)start and on disconnect so late Apex responses from an old session are ignored.
    _session = 0;

    connectedCallback() {
        this.begin();
    }

    disconnectedCallback() {
        this.clearTimer();
        this._session += 1;
    }

    // ---- lifecycle of one run ----

    async begin() {
        this.clearTimer();
        this._session += 1;
        const session = this._session;
        this.snapshot = undefined;
        this.errorText = undefined;
        this.timedOut = false;
        this.superseded = false;
        this._runId = undefined;
        this.starting = true;
        this._startedAt = Date.now();
        try {
            const result = await start({ storyId: this.recordId });
            if (session !== this._session) {
                return;
            }
            this.starting = false;
            if (result.errorMessage) {
                this.errorText = result.errorMessage;
                return;
            }
            this._runId = result.runId;
            this.handleSnapshot(result, session);
        } catch (error) {
            if (session !== this._session) {
                return;
            }
            this.starting = false;
            this.errorText = this.reduceError(error);
        }
    }

    handleSnapshot(result, session) {
        this.snapshot = result;
        // A different run id means this popup's run was replaced; whatever the story shows now is not ours.
        if (!result.isCurrentRun) {
            this.superseded = true;
            return;
        }
        if (result.isFinished) {
            return;
        }
        // setTimeout (not setInterval) so two Apex calls can never overlap.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setTimeout(() => this.poll(session), POLL_INTERVAL_MS);
    }

    async poll(session) {
        this._timer = undefined;
        if (session !== this._session) {
            return;
        }
        if (Date.now() - this._startedAt >= MAX_POLL_MS) {
            this.timedOut = true;
            return;
        }
        try {
            const result = await getProgress({ storyId: this.recordId, runId: this._runId });
            if (session !== this._session) {
                return;
            }
            this.handleSnapshot(result, session);
        } catch (error) {
            if (session !== this._session) {
                return;
            }
            this.errorText = this.reduceError(error);
        }
    }

    clearTimer() {
        if (this._timer) {
            clearTimeout(this._timer);
            this._timer = undefined;
        }
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'Unexpected error while verifying the story.';
    }

    // ---- handlers ----

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleRetry() {
        this.begin();
    }

    // ---- view state ----

    get isFinished() {
        return !this.superseded && !!(this.snapshot && this.snapshot.isFinished);
    }

    get status() {
        return this.snapshot ? this.snapshot.status : undefined;
    }

    get isActive() {
        return !this.isFinished && !this.timedOut && !this.superseded && !this.errorText;
    }

    get showSpinner() {
        return this.isActive;
    }

    get canRetry() {
        return this.isFinished || !!this.errorText;
    }

    get jobStatus() {
        return (this.snapshot && this.snapshot.jobStatus) || 'Queued';
    }

    get stateText() {
        if (this.errorText) {
            return 'Verification could not be completed.';
        }
        if (this.timedOut) {
            return TIMEOUT_TEXT;
        }
        if (this.superseded) {
            return SUPERSEDED_TEXT;
        }
        if (this.isFinished) {
            return 'Verification finished: ' + this.snapshot.status;
        }
        if (this.starting || !this.snapshot) {
            return 'Starting verification…';
        }
        const jobStatus = this.jobStatus;
        if (jobStatus === 'Successful') {
            return 'Verification job finished in Copado — recording the result…';
        }
        if (jobStatus === 'Failed' || jobStatus === 'Error' || jobStatus === 'Cancelled' || jobStatus === 'Canceled') {
            return 'Verification job ended in Copado (' + jobStatus + ') — recording the result…';
        }
        if (jobStatus === 'In Progress') {
            const progress = this.snapshot.progressText;
            return 'Verification job running in Copado…' + (progress ? ' ' + progress : '');
        }
        return 'Checks computed in Salesforce — job queued in Copado';
    }

    get steps() {
        const list = [];
        const findings = (this.snapshot && this.snapshot.findings) || [];
        findings.forEach((finding, index) => {
            const isIssue = finding.severity === 'issue';
            list.push({
                key: 'finding-' + index,
                isSpinner: false,
                iconName: isIssue ? 'utility:close' : 'utility:check',
                iconVariant: isIssue ? 'error' : 'success',
                altText: isIssue ? 'Issue' : 'OK',
                text: finding.message,
                textClass: isIssue ? 'slds-text-color_error' : ''
            });
        });
        list.push(this.jobStep());
        list.push({
            key: 'git',
            isSpinner: false,
            iconName: 'utility:dash',
            iconVariant: undefined,
            altText: 'Not implemented',
            text: 'Git checks (unregistered commits, org/env branch merge): Not yet implemented (phase B)',
            textClass: 'slds-text-color_weak'
        });
        return list;
    }

    jobStep() {
        const step = {
            key: 'job',
            isSpinner: false,
            iconVariant: undefined,
            textClass: '',
            text: 'Verification job in Copado'
        };
        const failedJob = ['Failed', 'Error', 'Cancelled', 'Canceled'].includes(this.jobStatus);
        const doneJob = this.jobStatus === 'Successful' || (this.isFinished && this.status !== 'Failed');
        if (failedJob || (this.isFinished && this.status === 'Failed' && !doneJob)) {
            return { ...step, iconName: 'utility:close', iconVariant: 'error', altText: 'Failed', text: step.text + ': failed' };
        }
        if (doneJob) {
            return { ...step, iconName: 'utility:check', iconVariant: 'success', altText: 'Done', text: step.text + ': done' };
        }
        if (this.snapshot && this.jobStatus === 'In Progress' && this.isActive) {
            return { ...step, isSpinner: true, altText: 'Running', text: step.text + ': running' };
        }
        return { ...step, iconName: 'utility:clock', altText: 'Pending', text: step.text + ': pending' };
    }

    get bannerClass() {
        return (BANNER_CLASS[this.status] || BANNER_CLASS.Failed) + ' slds-m-top_small';
    }

    get whyLines() {
        const lines = [];
        const details = (this.snapshot && this.snapshot.details) || [];
        const jobError = this.snapshot && this.snapshot.jobError;
        if (this.status === 'Failed' && jobError && !details.some((line) => line.includes(jobError))) {
            lines.push('Job error: ' + jobError);
        }
        details.forEach((line) => lines.push(line));
        const visible = lines.filter((line) => line.trim() !== '');
        if (visible.length === 0) {
            visible.push('No further details were recorded.');
        }
        return visible.map((text, index) => ({
            key: 'why-' + index,
            text,
            cls: text.startsWith('ISSUE:') ? 'slds-text-title_bold slds-text-color_error' : ''
        }));
    }
}
