import { LightningElement, api, wire } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/copado__User_Story__c.Name';
import start from '@salesforce/apex/StoryVerificationController.start';
import getProgress from '@salesforce/apex/StoryVerificationController.getProgress';
import previewMetadata from '@salesforce/apex/StoryVerificationMetadataController.preview';
import createMetadata from '@salesforce/apex/StoryVerificationMetadataController.create';

const POLL_INTERVAL_MS = 2000;
const MAX_POLL_MS = 5 * 60 * 1000;

// "Org/environment branch merge" -> "Org/Environment Branch Merge": the first letter of every word, other letters untouched.
function titleCase(text) {
    return String(text).replace(/(^|[\s/(-])([a-z])/g, (match, before, letter) => before + letter.toUpperCase());
}

// "Pending tests: None pending." -> key "Pending Tests", colon ": ", value "None". The colon is its own element so it can
// have a gap before it; the text of the row (key + colon + value) reads exactly as before apart from the capital letters.
function keyValue(text) {
    const t = String(text === undefined || text === null ? '' : text);
    const at = t.indexOf(': ');
    if (at < 0) {
        return { keyText: '', colonText: '', valueText: t };
    }
    return { keyText: titleCase(t.slice(0, at)), colonText: ': ', valueText: t.slice(at + 2).replace(/^None pending\.?$/i, 'None') };
}

// 17 s, or 2 min 23 s
function formatDuration(ms) {
    const seconds = Math.max(0, Math.round(ms / 1000));
    const minutes = Math.floor(seconds / 60);
    return minutes > 0 ? minutes + ' min ' + (seconds % 60) + ' s' : seconds + ' s';
}

const TIMEOUT_TEXT = 'Still running. You can close this window; open the story later and check Verification Status.';
const SUPERSEDED_TEXT =
    'A newer verification run has replaced this one. Close this window and open the story to see the latest result.';

// The three git checks run by the Copado Function (ids match function/index.js).
// The timeline: each check row is a node on a vertical line, ringed in the colour of its result.
function timelineClass(row) {
    const tone = row.isSpinner
        ? 'tl-run'
        : row.iconName === 'utility:close'
          ? 'tl-bad'
          : row.iconName === 'utility:warning'
            ? 'tl-warn'
            : row.iconName === 'utility:check'
              ? 'tl-ok'
              : 'tl-wait';
    return 'tl-item ' + tone;
}

const GIT_CHECKS = [
    { id: 'unregistered-commits', title: 'Unregistered commits' },
    { id: 'metadata-coverage', title: 'Metadata coverage' },
    { id: 'org-branch-merge', title: 'Org/environment branch merge' }
];

// Apex findings that carry a group are shown as ONE row per group.
const GROUP_TITLES = {
    'pull-request': 'Pull request approval',
    'pending-tests': 'Pending tests',
    'parent-dependencies': 'Parent story dependencies'
};
const GROUP_WORDS = {
    'parent-dependencies': { noun: 'parent stories', allOk: 'all ahead' }
};
const DEFAULT_GROUP_WORDS = { noun: 'findings', allOk: 'all ok' };

const CHECK_VISUALS = {
    pass: { iconName: 'utility:check', iconVariant: 'success', altText: 'Passed', textClass: '' },
    fail: { iconName: 'utility:close', iconVariant: 'error', altText: 'Failed', textClass: 'slds-text-color_error' },
    warn: { iconName: 'utility:warning', iconVariant: 'warning', altText: 'Warning', textClass: '' },
    skipped: { iconName: 'utility:dash', iconVariant: undefined, altText: 'Skipped', textClass: 'slds-text-color_weak' }
};

export default class StoryVerificationPopup extends LightningElement {
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        // The quick action framework can clear and re-set recordId after the component opens; never forget a known id.
        if (value) {
            this._recordId = value;
        }
    }

    // Story name for the confirmation text, loaded through Lightning Data Service.
    storyName;
    // False while the confirmation (intro) screen is shown; nothing runs until the user clicks Verify.
    runStarted = false;

    @wire(getRecord, { recordId: '$recordId', fields: [NAME_FIELD] })
    wiredStory({ data, error }) {
        if (data) {
            this.storyName = getFieldValue(data, NAME_FIELD);
        } else if (error) {
            this.storyName = undefined;
        }
    }

    snapshot;
    errorText;
    starting = false;
    timedOut = false;
    superseded = false;
    // check id -> true/false once the user has toggled that row; untouched rows use the default (open for fail/warn).
    expandedByUser = {};
    // group row key -> true when its list (for example the unchanged registered components) is opened.
    openGroups = {};
    // The components ticked in the "Not registered" list: "<kind>|<name>" -> true.
    selected = {};
    // 'result' (the checks), 'preview' (what Create Selected Metadata would insert) or 'done' (what was inserted).
    view = 'result';
    previewData;
    createData;
    metaError = '';
    busy = false;

    _timer;
    _runId;
    // The story id captured when a run starts; every call of that run uses it, whatever recordId does later.
    _storyId;
    _startedAt = 0;
    // How long the run took, from the click on Verify to the final result (set once, when the finished result arrives).
    durationMs;
    // Bumped on every (re)start and on disconnect so late Apex responses from an old session are ignored.
    _session = 0;

    // A checkbox cannot be "partly ticked" through an attribute, only through its property.
    renderedCallback() {
        this.template.querySelectorAll('input[data-scope]').forEach((box) => {
            box.indeterminate = box.dataset.indeterminate === 'true';
        });
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
        this.runStarted = true;
        this.selected = {};
        this.view = 'result';
        this.previewData = undefined;
        this.createData = undefined;
        this.metaError = '';
        this.snapshot = undefined;
        this.errorText = undefined;
        this.timedOut = false;
        this.superseded = false;
        this.expandedByUser = {};
        this.openGroups = {};
        this._runId = undefined;
        this.starting = true;
        this._startedAt = Date.now();
        this.durationMs = undefined;
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
            if (this.durationMs === undefined) {
                this.durationMs = Date.now() - this._startedAt;
            }
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

    handleVerify() {
        if (!this._recordId || this.runStarted) {
            return;
        }
        this.begin();
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

    // ---- Create Selected Metadata ----

    // The groups of the "Not registered" list of the stored Metadata Coverage check: { kind, type, items: [{ name, action, ... }] }.
    get selectGroups() {
        const check = ((this.snapshot && this.snapshot.checks) || []).find((c) => c.id === 'metadata-coverage');
        if (!check || !check.rowsJson) {
            return [];
        }
        try {
            const rows = JSON.parse(check.rowsJson);
            const row = (Array.isArray(rows) ? rows : []).find((r) => r && r.t === 'select');
            return row && Array.isArray(row.groups) ? row.groups : [];
        } catch (e) {
            return [];
        }
    }

    get canSelectMetadata() {
        return !!(this.snapshot && this.snapshot.canCreateMetadata && this.isFinished);
    }

    isSupportedKind(kind) {
        return ((this.snapshot && this.snapshot.supportedKinds) || []).includes(kind);
    }

    keysOfKind(kind) {
        const keys = [];
        this.selectGroups
            .filter((g) => g.kind === kind && this.isSupportedKind(g.kind))
            .forEach((g) => (g.items || []).forEach((item) => keys.push(g.kind + '|' + item.name)));
        return keys;
    }

    // Every component that may be ticked (its kind can be registered).
    get selectableKeys() {
        const keys = [];
        this.selectGroups.forEach((g) => {
            if (this.isSupportedKind(g.kind)) {
                (g.items || []).forEach((item) => keys.push(g.kind + '|' + item.name));
            }
        });
        return keys;
    }

    get selectedKeys() {
        return this.selectableKeys.filter((key) => this.selected[key]);
    }

    handleSelectChange(event) {
        const box = event.currentTarget;
        const keys =
            box.dataset.scope === 'item'
                ? [box.dataset.key]
                : box.dataset.scope === 'group'
                  ? this.keysOfKind(box.dataset.kind)
                  : this.selectableKeys;
        const next = { ...this.selected };
        keys.forEach((key) => {
            if (box.checked) {
                next[key] = true;
            } else {
                delete next[key];
            }
        });
        this.selected = next;
    }

    apexMessage(error) {
        return (error && error.body && error.body.message) || (error && error.message) || 'Something went wrong.';
    }

    async handleCreateSelected() {
        if (this.busy || this.selectedKeys.length === 0) {
            return;
        }
        this.busy = true;
        this.metaError = '';
        try {
            this.previewData = await previewMetadata({ storyId: this._storyId, keys: this.selectedKeys });
            this.view = 'preview';
        } catch (error) {
            this.metaError = this.apexMessage(error);
        } finally {
            this.busy = false;
        }
    }

    handleBack() {
        this.metaError = '';
        this.view = 'result';
    }

    async handleInsert() {
        if (this.busy || !this.previewData || !this.previewData.newCount) {
            return;
        }
        this.busy = true;
        this.metaError = '';
        try {
            this.createData = await createMetadata({ storyId: this._storyId, keys: this.selectedKeys });
            this.selected = {};
            this.view = 'done';
        } catch (error) {
            this.metaError = this.apexMessage(error);
        } finally {
            this.busy = false;
        }
    }

    get previewStoryLabel() {
        const data = this.previewData;
        return data ? data.storyName + (data.storyTitle ? ' (' + data.storyTitle + ')' : '') : '';
    }

    // What Insert would create, grouped by metadata type.
    get previewSections() {
        const data = this.previewData;
        if (!data) {
            return [];
        }
        const sections = [];
        const byLabel = {};
        (data.lines || []).forEach((line, index) => {
            const label = line.typeLabel || line.type;
            if (!byLabel[label]) {
                byLabel[label] = { key: 'preview-type-' + label, typeLabel: label, lines: [] };
                sections.push(byLabel[label]);
            }
            byLabel[label].lines.push({
                key: 'preview-line-' + index,
                name: line.name,
                action: line.action,
                actionClass: line.action === 'Delete' ? 'action-badge action-delete' : 'action-badge action-add',
                path: line.path || '',
                exists: !!line.exists,
                conflict: line.conflict || '',
                note: line.note || '',
                cssClass: line.exists ? 'preview-line preview-exists' : line.conflict ? 'preview-line preview-conflict' : 'preview-line'
            });
        });
        return sections;
    }

    get previewSummary() {
        const data = this.previewData;
        if (!data) {
            return '';
        }
        let text = data.newCount + (data.newCount === 1 ? ' record' : ' records') + ' will be created.';
        if (data.existingCount) {
            text += ' ' + data.existingCount + ' already registered and skipped.';
        }
        if (data.conflictCount) {
            text += ' ' + data.conflictCount + ' cannot be created: a record with the same unique ID but another type already exists.';
        }
        if (data.unsupported && data.unsupported.length) {
            text += ' Not offered (type not supported yet): ' + data.unsupported.join(', ') + '.';
        }
        return text;
    }

    get insertLabel() {
        return 'Insert' + (this.previewData && this.previewData.newCount ? ' (' + this.previewData.newCount + ')' : '');
    }

    get insertDisabled() {
        return this.busy || !this.previewData || !this.previewData.newCount;
    }

    get doneSummary() {
        const data = this.createData;
        if (!data) {
            return '';
        }
        let text = 'Created ' + data.created + (data.created === 1 ? ' record' : ' records') + ' under User Story Metadata of ' + this.previewStoryLabel + '.';
        if (data.skipped) {
            text += ' ' + data.skipped + ' already existed and were skipped.';
        }
        return text;
    }

    get doneErrors() {
        return ((this.createData && this.createData.errors) || []).map((text, index) => ({ key: 'done-error-' + index, text }));
    }

    handleGroupToggle(event) {
        const key = event.currentTarget.dataset.groupKey;
        // The button says whether the list is open now, so flip that.
        const open = event.currentTarget.getAttribute('aria-expanded') === 'true';
        this.openGroups = { ...this.openGroups, [key]: !open };
    }

    // ---- view state ----

    get showIntro() {
        return !this.runStarted;
    }

    get showRun() {
        return this.runStarted && this.view === 'result';
    }

    get showPreview() {
        return this.view === 'preview' && !!this.previewData;
    }

    get showDone() {
        return this.view === 'done' && !!this.createData;
    }

    get introText() {
        return this.storyName ? 'Verify ' + this.storyName + ' for' : 'Verify this story for';
    }

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
        return this.runStarted && this.view !== 'preview' && (this.isFinished || !!this.errorText);
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
            // Copado's own text before it has started the Function ("Accepted by Backend. Scheduling."): say whose wait it is.
            if (/accepted by backend|scheduling/i.test(progress)) {
                return (
                    'Waiting for Copado to start the job (' +
                    progress.replace(/\.$/, '') +
                    ') — ' +
                    formatDuration(Date.now() - this._startedAt)
                );
            }
            return progress;
        }
        if (jobStatus === 'In Progress') {
            return 'Verification job running in Copado…';
        }
        return 'Checks computed in Salesforce — job queued in Copado';
    }

    get steps() {
        const findings = (this.snapshot && this.snapshot.findings) || [];
        const grouped = {};
        const ungrouped = [];
        findings.forEach((finding, index) => {
            // The Apex field is exposed as groupKey (see StoryVerificationController.Finding); group is accepted too.
            const group = finding.groupKey || finding.group;
            if (group && GROUP_TITLES[group]) {
                grouped[group] = grouped[group] || [];
                grouped[group].push(finding);
            } else {
                ungrouped.push({ finding, index });
            }
        });

        // One fixed order, the same as the confirmation screen.
        const list = [
            this.gitRow('unregistered-commits'),
            this.gitRow('metadata-coverage'),
            this.groupRow('pull-request', grouped['pull-request'] || []),
            this.groupRow('pending-tests', grouped['pending-tests'] || []),
            this.groupRow('parent-dependencies', grouped['parent-dependencies'] || []),
            this.gitRow('org-branch-merge')
        ];
        // The job row is technical: shown while the job runs and when a run Failed, hidden once a finished run has a verdict
        // (the verdict and the check rows already say the job completed).
        if (!(this.isFinished && this.status !== 'Failed')) {
            list.push(this.jobStep());
        }
        ungrouped.forEach(({ finding, index }) => {
            const isIssue = finding.severity === 'issue';
            const isWarn = finding.severity === 'warn';
            list.push({
                key: 'finding-' + index,
                isSpinner: false,
                iconName: isIssue ? 'utility:close' : isWarn ? 'utility:warning' : 'utility:check',
                iconVariant: isIssue ? 'error' : isWarn ? 'warning' : 'success',
                altText: isIssue ? 'Issue' : isWarn ? 'Warning' : 'OK',
                text: finding.message,
                textClass: isIssue ? 'slds-text-color_error' : ''
            });
        });
        // Any extra check the Function reported that this popup does not know about.
        const results = (this.snapshot && this.snapshot.checks) || [];
        results
            .filter((r) => !GIT_CHECKS.some((check) => check.id === r.id))
            .forEach((r) => list.push(this.checkRow({ id: r.id, title: r.title || r.id, result: r })));
        // While the run is going the order is fixed (rows do not jump as they resolve); once finished, passed checks come
        // first, then warnings and skipped checks, then the failures.
        const ordered = this.isFinished ? this.passedFirst(list) : list;
        return ordered.map((row) => ({ ...row, ...keyValue(row.text), itemClass: timelineClass(row) }));
    }

    passedFirst(list) {
        const rank = (row) => {
            if (row.iconName === 'utility:check') return 0;
            if (row.iconName === 'utility:close') return 3;
            if (row.iconName === 'utility:dash') return 2;
            return 1;
        };
        return list
            .map((row, index) => ({ row, index }))
            .sort((a, b) => rank(a.row) - rank(b.row) || a.index - b.index)
            .map((entry) => entry.row);
    }

    gitRow(id) {
        const check = GIT_CHECKS.find((c) => c.id === id);
        const results = (this.snapshot && this.snapshot.checks) || [];
        return this.checkRow({ id, title: check.title, result: results.find((r) => r.id === id) });
    }

    // One row per group. A single finding is a plain "Title: message" row; several findings get a summary row whose
    // individual messages sit behind the details toggle.
    groupRow(group, findings) {
        const title = GROUP_TITLES[group];
        const checkId = 'group-' + group;
        const row = {
            key: checkId,
            checkId,
            isSpinner: false,
            hasLines: false,
            expanded: false,
            ariaExpanded: 'false',
            toggleLabel: 'Show details',
            lines: [],
            textClass: ''
        };
        if (findings.length === 0) {
            if (this.isFinished) {
                return { ...row, ...CHECK_VISUALS.skipped, text: title + ': no result was reported' };
            }
            return { ...row, iconName: 'utility:clock', iconVariant: undefined, altText: 'Pending', text: title + ': pending' };
        }
        const issueCount = findings.filter((f) => f.severity === 'issue').length;
        const warnCount = findings.filter((f) => f.severity === 'warn').length;
        const visual = issueCount > 0 ? CHECK_VISUALS.fail : warnCount > 0 ? CHECK_VISUALS.warn : CHECK_VISUALS.pass;
        let text;
        if (findings.length === 1) {
            const message = String(findings[0].message || '');
            // Avoid "Pending tests: Pending tests: 0." when the message already starts with the title.
            text = message.startsWith(title + ':') ? message : title + ': ' + message;
        } else {
            const words = GROUP_WORDS[group] || DEFAULT_GROUP_WORDS;
            text =
                issueCount > 0
                    ? title + ': ' + findings.length + ' ' + words.noun + ' — ' + issueCount + ' need attention'
                    : title + ': ' + findings.length + ' ' + words.noun + ', ' + words.allOk;
        }
        const hasLines = findings.length > 1;
        const expanded = hasLines && this.isExpanded(checkId, issueCount > 0 ? 'fail' : 'pass');
        return {
            ...row,
            ...visual,
            text,
            hasLines,
            lines: findings.map((f, index) => ({ key: checkId + '-' + index, text: f.message, isText: true })),
            expanded,
            ariaExpanded: String(expanded),
            toggleLabel: expanded ? 'Hide details' : 'Show details'
        };
    }

    isExpanded(checkId, status) {
        if (Object.prototype.hasOwnProperty.call(this.expandedByUser, checkId)) {
            return this.expandedByUser[checkId];
        }
        return status === 'fail' || status === 'warn';
    }

    // The detail rows of one finished check. The Function sends structured rows (rowsJson) so that parts can be coloured and
    // lists collapsed; without them the plain text lines are shown, as before.
    detailItems(id, result) {
        let rows = [];
        try {
            const parsed = result.rowsJson ? JSON.parse(result.rowsJson) : [];
            rows = Array.isArray(parsed) ? parsed : [];
        } catch (e) {
            rows = [];
        }
        if (rows.length === 0) {
            return (result.lines || []).map((text, index) => ({
                key: 'check-' + id + '-' + index,
                text,
                isText: true,
                cssClass: /^Not registered:/.test(text) ? 'component-names' : ''
            }));
        }
        const items = rows.map((row, index) => this.detailItem('check-' + id + '-' + index, row || {}));
        // The Create Selected Metadata button sits on the "won't deploy" line, once something is ticked.
        if (items.some((item) => item.isSelect) && this.selectedKeys.length > 0) {
            const warning = items.find((item) => item.isDanger);
            if (warning) {
                warning.hasAction = true;
            }
        }
        return items;
    }

    // The commit's page in the Git host: the repository's commit address plus the full id. Only https addresses and plain
    // hexadecimal ids are used; without both there is no link.
    commitHref(fullSha) {
        const base = this.snapshot && this.snapshot.commitBaseUrl;
        if (!base || !/^https:\/\//.test(base) || !/^[0-9a-f]{7,64}$/i.test(String(fullSha || ''))) {
            return '';
        }
        return base + (base.endsWith('/') ? '' : '/') + fullSha;
    }

    // The "Not registered" list: a toggle with a "Select all" box, a box per metadata type and a box per component, each
    // component with the action it needs (ADD / DELETE). Without the permission the boxes are not shown, only the actions.
    selectItem(key, row) {
        const open = !!this.openGroups[key];
        const canSelect = this.canSelectMetadata;
        const entries = [];
        let selectable = 0;
        let ticked = 0;
        (Array.isArray(row.groups) ? row.groups : []).forEach((group, gi) => {
            const items = Array.isArray(group.items) ? group.items : [];
            const supported = this.isSupportedKind(group.kind);
            const keys = items.map((item) => group.kind + '|' + item.name);
            const groupTicked = supported ? keys.filter((k) => this.selected[k]).length : 0;
            entries.push({
                key: key + '-g' + gi,
                isHeading: true,
                text: String(group.type || 'Other'),
                cssClass: 'type-heading',
                showBox: canSelect,
                scope: 'group',
                kind: group.kind,
                checked: supported && keys.length > 0 && groupTicked === keys.length,
                indeterminate: String(groupTicked > 0 && groupTicked < keys.length),
                disabled: !supported,
                title: supported ? '' : 'This type cannot be registered from here yet',
                ariaLabel: 'Select all ' + String(group.type || '')
            });
            items.forEach((item, i) => {
                const itemKey = group.kind + '|' + item.name;
                const isTicked = supported && !!this.selected[itemKey];
                if (supported) {
                    selectable += 1;
                    ticked += isTicked ? 1 : 0;
                }
                entries.push({
                    key: key + '-g' + gi + '-i' + i,
                    isHeading: false,
                    text: String(item.name),
                    cssClass: 'component-name',
                    showBox: canSelect,
                    scope: 'item',
                    itemKey,
                    checked: isTicked,
                    indeterminate: 'false',
                    disabled: !supported,
                    title: supported ? '' : 'This type cannot be registered from here yet',
                    ariaLabel: 'Select ' + String(item.name),
                    action: item.action === 'Delete' ? 'DELETE' : 'ADD',
                    actionClass: item.action === 'Delete' ? 'action-badge action-delete' : 'action-badge action-add'
                });
            });
        });
        return {
            key,
            isSelect: true,
            groupKey: key,
            label: (row.label || 'Components') + ': ' + (row.count === undefined ? selectable : row.count),
            labelClass: 'tone-warn',
            open,
            ariaExpanded: String(open),
            chevron: open ? 'utility:chevrondown' : 'utility:chevronright',
            toggleTitle: open ? 'Hide the list' : 'Show the list',
            showAll: canSelect && selectable > 0,
            allChecked: selectable > 0 && ticked === selectable,
            allIndeterminate: String(ticked > 0 && ticked < selectable),
            entries
        };
    }

    detailItem(key, row) {
        const more = (n) => (n > 0 ? ' (+' + n + ' more)' : '');
        if (row.t === 'commit') {
            // Only the id, the person and the message: the uncovered components are listed under Metadata Coverage.
            const href = this.commitHref(row.full);
            return {
                key,
                isCommit: true,
                cssClass: 'commit-line',
                href,
                hasLink: !!href,
                linkTitle: 'Open this commit in your Git host (opens in a new tab)',
                sha: String(row.sha || ''),
                author: String(row.author || ''),
                subject: String(row.subject || ''),
                hasNote: !!row.note,
                note: row.note ? '(' + row.note + ')' : ''
            };
        }
        if (row.t === 'names') {
            const items = Array.isArray(row.items) ? row.items : [];
            return { key, isText: true, cssClass: 'component-names', text: (row.label || 'Components') + ': ' + items.join(', ') + more(row.more) };
        }
        if (row.t === 'danger') {
            return { key, isDanger: true, cssClass: 'danger-line', text: String(row.text || '') };
        }
        if (row.t === 'select') {
            return this.selectItem(key, row);
        }
        if (row.t === 'group') {
            // Lists start closed; after that the user's last choice is kept.
            const open = !!this.openGroups[key];
            // The list is a flat sequence of entries: a heading per metadata type, then that type's components one per line.
            // Results stored without types (a flat "items" list) show just the components.
            const entries = [];
            if (Array.isArray(row.groups)) {
                row.groups.forEach((group, gi) => {
                    entries.push({ key: key + '-t' + gi, isHeading: true, text: String(group.type || 'Other'), cssClass: 'type-heading' });
                    (Array.isArray(group.items) ? group.items : []).forEach((name, i) => {
                        entries.push({ key: key + '-t' + gi + '-i' + i, isHeading: false, text: String(name), cssClass: 'component-name' });
                    });
                });
            } else {
                (Array.isArray(row.items) ? row.items : []).forEach((name, i) => {
                    entries.push({ key: key + '-i' + i, isHeading: false, text: String(name), cssClass: 'component-name' });
                });
            }
            const count = entries.filter((e) => !e.isHeading).length;
            return {
                key,
                isGroup: true,
                cssClass: row.tone === 'warn' ? '' : 'group-line',
                labelClass: row.tone === 'warn' ? 'tone-warn' : '',
                groupKey: key,
                label: (row.label || 'Components') + ': ' + (row.count === undefined ? count : row.count),
                open,
                ariaExpanded: String(open),
                chevron: open ? 'utility:chevrondown' : 'utility:chevronright',
                toggleTitle: open ? 'Hide the list' : 'Show the list',
                entries
            };
        }
        return { key, isText: true, text: String(row.text === undefined || row.text === null ? '' : row.text) };
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
            const lines = this.detailItems(id, result);
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

    // "Time taken: 17 s" or "Time taken: 2 min 23 s"; empty until the run has finished.
    get timeTakenText() {
        if (!this.isFinished || this.durationMs === undefined) {
            return '';
        }
        const total = 'Time taken: ' + formatDuration(this.durationMs);
        // When the Function reported its own run time, split the total into Copado's queue time and the checks themselves.
        const script = this.snapshot && this.snapshot.scriptSeconds;
        if (typeof script === 'number' && script >= 0) {
            const queueMs = this.durationMs - script * 1000;
            if (queueMs >= 15000) {
                return total + ' (Copado queue ' + formatDuration(queueMs) + ' + checks ' + formatDuration(script * 1000) + ')';
            }
        }
        return total;
    }

    get failureText() {
        if (!this.isFinished || this.status !== 'Failed') {
            return '';
        }
        const jobError = this.snapshot.jobError;
        if (jobError) {
            return jobError;
        }
        const details = (this.snapshot.details || []).filter((line) => line.trim() !== '');
        // The reason is carried by the NOTE lines (why the git checks could not run); showing the whole details text would
        // repeat every check result in one block.
        const notes = details.filter((line) => /^NOTE:/i.test(line)).map((line) => line.replace(/^NOTE:\s*/i, ''));
        return (notes.length > 0 ? notes : details).join('\n');
    }

    jobStep() {
        const step = {
            key: 'job',
            isSpinner: false,
            iconVariant: undefined,
            textClass: '',
            text: 'Copado job'
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

    get stateClass() {
        return 'slds-text-heading_small';
    }

    // A finished run reads "VERIFICATION FINISHED: <verdict>": the key is dark and the verdict is coloured (green for Clean,
    // red for Issues and Failed). Every other state is one plain piece of text.
    get showsVerdict() {
        return !this.errorText && !this.timedOut && !this.superseded && this.isFinished;
    }

    get stateKey() {
        return this.showsVerdict ? 'Verification Finished' : '';
    }

    get stateColon() {
        return this.showsVerdict ? ': ' : '';
    }

    get stateValue() {
        return this.showsVerdict ? String(this.snapshot.status) : this.stateText;
    }

    get stateValueClass() {
        if (!this.showsVerdict) {
            return '';
        }
        return this.status === 'Clean' ? 'slds-text-color_success' : 'slds-text-color_error';
    }
}
