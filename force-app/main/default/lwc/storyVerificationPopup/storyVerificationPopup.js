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

// The three git checks run by the Copado Function, in display order (ids match function/index.js).
const GIT_CHECKS = [
    { id: 'unregistered-commits', title: 'Unregistered commits' },
    { id: 'metadata-coverage', title: 'Metadata coverage' },
    { id: 'org-branch-merge', title: 'Org/environment branch merge' }
];

const CHECK_VISUALS = {
    pass: { iconName: 'utility:check', iconVariant: 'success', altText: 'Passed', textClass: '' },
    fail: { iconName: 'utility:close', iconVariant: 'error', altText: 'Failed', textClass: 'slds-text-color_error' },
    warn: { iconName: 'utility:warning', iconVariant: 'warning', altText: 'Warning', textClass: '' },
    skipped: { iconName: 'utility:dash', iconVariant: undefined, altText: 'Skipped', textClass: 'slds-text-color_weak' }
};

export default class StoryVerificationPopup extends LightningElement {
    // In a quick action the record id is set AFTER connectedCallback, so the run starts only once both are true.
    _recordId;
    _connected = false;
    _started = false;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        // The quick action framework can clear and re-set recordId after the component opens; never forget a known id.
        if (value) {
            this._recordId = value;
        }
        this.startWhenReady();
    }

    snapshot;
    errorText;
    starting = true;
    timedOut = false;
    superseded = false;
    // check id -> true/false once the user has toggled that row; untouched rows use the default (open for fail/warn).
    expandedByUser = {};

    _timer;
    _runId;
    // The story id captured when a run starts; every call of that run uses it, whatever recordId does later.
    _storyId;
    _startedAt = 0;
    // Bumped on every (re)start and on disconnect so late Apex responses from an old session are ignored.
    _session = 0;

    connectedCallback() {
        this._connected = true;
        this.startWhenReady();
    }

    disconnectedCallback() {
        this._connected = false;
        this._started = false;
        this.clearTimer();
        this._session += 1;
    }

    startWhenReady() {
        if (this._connected && this._recordId && !this._started) {
            this._started = true;
            this.begin();
        }
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
        this.expandedByUser = {};
        this._runId = undefined;
        this.starting = true;
        this._startedAt = Date.now();
        try {
            this._storyId = this._recordId;
            const result = await start({ storyId: this._storyId });
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
            const result = await getProgress({ storyId: this._storyId, runId: this._runId });
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

    handleToggle(event) {
        const checkId = event.currentTarget.dataset.checkId;
        const row = this.steps.find((step) => step.checkId === checkId);
        if (!row) {
            return;
        }
        this.expandedByUser = { ...this.expandedByUser, [checkId]: !row.expanded };
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
        // The Function's own "copado -p" message, e.g. "Checking unregistered commits…".
        const progress = this.snapshot.progressText;
        if (progress) {
            return progress;
        }
        if (jobStatus === 'In Progress') {
            return 'Verification job running in Copado…';
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
        this.gitCheckItems().forEach((item) => list.push(this.checkRow(item)));
        return list;
    }

    // The three known checks first (always shown), then any extra check the Function reported.
    gitCheckItems() {
        const results = (this.snapshot && this.snapshot.checks) || [];
        const items = GIT_CHECKS.map((check) => ({
            id: check.id,
            title: check.title,
            result: results.find((r) => r.id === check.id)
        }));
        results
            .filter((r) => !GIT_CHECKS.some((check) => check.id === r.id))
            .forEach((r) => items.push({ id: r.id, title: r.title || r.id, result: r }));
        return items;
    }

    isExpanded(checkId, status) {
        if (Object.prototype.hasOwnProperty.call(this.expandedByUser, checkId)) {
            return this.expandedByUser[checkId];
        }
        return status === 'fail' || status === 'warn';
    }

    checkRow({ id, title, result }) {
        const row = {
            key: 'check-' + id,
            checkId: id,
            isSpinner: false,
            hasLines: false,
            expanded: false,
            ariaExpanded: 'false',
            toggleLabel: 'Show details',
            lines: [],
            textClass: ''
        };
        if (this.isFinished && result) {
            const visual = CHECK_VISUALS[result.status] || CHECK_VISUALS.skipped;
            const lines = (result.lines || []).map((text, index) => ({ key: 'check-' + id + '-' + index, text }));
            const expanded = lines.length > 0 && this.isExpanded(id, result.status);
            return {
                ...row,
                ...visual,
                text: title + ': ' + (result.summary || visual.altText),
                hasLines: lines.length > 0,
                lines,
                expanded,
                ariaExpanded: String(expanded),
                toggleLabel: expanded ? 'Hide details' : 'Show details'
            };
        }
        if (this.isFinished) {
            return { ...row, ...CHECK_VISUALS.skipped, text: title + ': no result was reported' };
        }
        if (this.snapshot && this.jobStatus === 'In Progress' && this.isActive) {
            return { ...row, isSpinner: true, altText: 'Running', text: title + ': running' };
        }
        return { ...row, iconName: 'utility:clock', iconVariant: undefined, altText: 'Pending', text: title + ': pending' };
    }

    get failureText() {
        if (!this.isFinished || this.status !== 'Failed') {
            return '';
        }
        const jobError = this.snapshot.jobError;
        if (jobError) {
            return jobError;
        }
        return (this.snapshot.details || []).filter((line) => line.trim() !== '').join(' ');
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

    get hasFacts() {
        return !!(this.snapshot && this.snapshot.facts && this.snapshot.facts.length > 0);
    }

    get readinessRows() {
        const facts = (this.snapshot && this.snapshot.facts) || [];
        return facts.map((fact, index) => {
            const isIssue = fact.state === 'issue';
            return {
                key: 'fact-' + index,
                iconName: isIssue ? 'utility:close' : 'utility:check',
                iconVariant: isIssue ? 'error' : 'success',
                altText: isIssue ? 'Issue' : 'OK',
                text: fact.label + ': ' + fact.value,
                textClass: isIssue ? 'slds-text-color_error' : ''
            };
        });
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
