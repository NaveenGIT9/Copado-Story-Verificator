/**
 * Server side of the storyVerificationPopup LWC: starts a verification and reports live progress.
 * Everything runs with sharing; only the Copado job reads (JobReader) run without it, after the
 * caller has been proven able to read the story.
 */
public with sharing class StoryVerificationController {
    // Name of the Job Template as shown on the Job Execution (copado__Template__r.Name).
    private static final String TEMPLATE_NAME = 'Story_Verification';
    private static final String JOB_QUEUED = 'Queued';
    private static final Set<String> KNOWN_JOB_STATUSES = new Set<String>{
        'Queued',
        'In Progress',
        'Successful',
        'Failed',
        'Error',
        'Cancelled',
        'Canceled'
    };
    private static final Set<String> FINISHED_STATUSES = new Set<String>{ 'Clean', 'Issues', 'Failed' };
    private static final Set<String> CHECK_STATUSES = new Set<String>{ 'pass', 'fail', 'warn', 'skipped' };
    private static final Integer MAX_EXECUTIONS_SCANNED = 20;
    private static final Integer MAX_RESULTS_SCANNED = 20;

    public class Finding {
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public String message;
        // The finding's "group" key (pull-request | pending-tests | parent-dependencies), blank for ungrouped findings.
        // Named groupKey (not group) because group is a SOQL keyword and may not be usable as an Apex identifier; the popup reads groupKey.
        @AuraEnabled
        public String groupKey;
        // Parent story findings only: the parts of the sentence (kind: ahead | not-ahead | no-env | not-promoted | promoted), so the
        // popup can link the parent story and colour the environments. Blank on every other finding.
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String parentId;
        @AuraEnabled
        public String parentName;
        @AuraEnabled
        public String via;
        @AuraEnabled
        public String parentEnv;
        @AuraEnabled
        public String childEnv;
    }

    /** Result of one git check as reported by the Function (state: pass | fail | warn | skipped). */
    public class CheckResult {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public List<String> lines = new List<String>();
        // Structured detail rows (coloured commit parts, component names, collapsible lists) as JSON text for the popup to parse;
        // blank when the Function sent none, in which case the popup shows the plain lines.
        @AuraEnabled
        public String rowsJson;
    }

    /** One live "promotion readiness" line, e.g. Pending tests: 3 (state issue). */
    public class Fact {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String state; // ok | issue
    }

    public class ProgressSnapshot {
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String runId;
        @AuraEnabled
        public Boolean isFinished = false;
        @AuraEnabled
        public Boolean isCurrentRun = true;
        @AuraEnabled
        public Boolean cancelled = false;
        @AuraEnabled
        public Boolean alreadyRunning = false;
        @AuraEnabled
        public List<String> details = new List<String>();
        @AuraEnabled
        public List<Finding> findings = new List<Finding>();
        @AuraEnabled
        public String jobStatus;
        @AuraEnabled
        public String jobError;
        @AuraEnabled
        public String progressText;
        @AuraEnabled
        public String errorMessage;
        @AuraEnabled
        public List<Fact> facts = new List<Fact>();
        @AuraEnabled
        public List<CheckResult> checks = new List<CheckResult>();
        // How long the Function script itself ran (seconds); the rest of the wait was Copado starting the job.
        @AuraEnabled
        public Integer scriptSeconds;
        // The branch the story was cut from (the story's Base Branch field), shown under the popup title.
        @AuraEnabled
        public String baseBranch;
        // The repository's commit address up to the commit id (https://github.com/org/repo/commit/); blank when unknown.
        @AuraEnabled
        public String commitBaseUrl;
        // Whether this user is offered Create Selected Metadata, and the folders that can be registered (finished runs only).
        @AuraEnabled
        public Boolean canCreateMetadata = false;
        @AuraEnabled
        public List<String> supportedKinds = new List<String>();
    }

    /** Reduced view of the Copado job for one run. */
    private class JobInfo {
        public List<Finding> findings = new List<Finding>();
        public String status = JOB_QUEUED;
        public String error;
        public String progressText;
    }

    /**
     * Read-only access to Copado job records, which normal users may not be permitted to read. It only
     * returns status text for a story whose readability the caller has already been checked for
     * (with sharing, USER_MODE) in loadStory, and it never writes.
     */
    private without sharing class JobReader {
        // Set by readChecks from the same stored JSON (no extra query).
        public Integer scriptSeconds;
        // The findings as the Function finished them (it may turn the "No commits" finding into a warning); empty when none.
        public List<Finding> finalFindings = new List<Finding>();

        /**
         * The commit base address of the Git repository of the story's pipeline, so the popup can link each commit.
         * Field names of the managed package are read at run time, so a org that names them differently (or has no value)
         * simply gets no links instead of an error.
         */
        public String readCommitBaseUrl(Id storyId) {
            try {
                List<SObject> stories = Database.query(
                    'SELECT copado__Project__r.copado__Deployment_Flow__r.copado__Git_Repository__c FROM copado__User_Story__c WHERE Id = :storyId LIMIT 1'
                );
                SObject project = stories.isEmpty() ? null : stories[0].getSObject('copado__Project__r');
                SObject pipeline = project == null ? null : project.getSObject('copado__Deployment_Flow__r');
                Object repoValue = pipeline == null ? null : pipeline.get('copado__Git_Repository__c');
                if (repoValue == null) {
                    return null;
                }
                Map<String, Schema.SObjectField> fields = Schema.describeSObjects(new List<String>{ 'copado__Git_Repository__c' })[0]
                    .fields.getMap();
                Boolean hasBase = fields.containsKey('copado__commit_base_url__c');
                Boolean hasUri = fields.containsKey('copado__uri__c');
                List<String> wanted = new List<String>();
                if (hasBase) {
                    wanted.add('copado__Commit_Base_URL__c');
                }
                if (hasUri) {
                    wanted.add('copado__URI__c');
                }
                if (wanted.isEmpty()) {
                    return null;
                }
                Id repoId = (Id) repoValue;
                List<SObject> repos = Database.query('SELECT ' + String.join(wanted, ', ') + ' FROM copado__Git_Repository__c WHERE Id = :repoId LIMIT 1');
                if (repos.isEmpty()) {
                    return null;
                }
                return commitBaseFrom(
                    hasBase ? (String) repos[0].get('copado__Commit_Base_URL__c') : null,
                    hasUri ? (String) repos[0].get('copado__URI__c') : null
                );
            } catch (Exception e) {
                return null;
            }
        }

        public JobInfo read(Id storyId, String runId) {
            JobInfo info = new JobInfo();
            if (String.isBlank(runId)) {
                return info;
            }
            String parentKey = String.valueOf(storyId);
            copado__JobExecution__c match;
            Map<String, Object> matchData;
            for (copado__JobExecution__c je : [
                SELECT Id, copado__Status__c, copado__ErrorMessage__c, copado__DataJson__c
                FROM copado__JobExecution__c
                WHERE copado__ParentRecord_Id__c = :parentKey AND copado__Template__r.Name = :TEMPLATE_NAME
                ORDER BY CreatedDate DESC
                LIMIT :MAX_EXECUTIONS_SCANNED
            ]) {
                Map<String, Object> data = parseMap(je.copado__DataJson__c);
                if (data != null && data.get('runId') != null && String.valueOf(data.get('runId')) == runId) {
                    match = je;
                    matchData = data;
                    break;
                }
            }
            if (match == null) {
                return info;
            }
            info.findings = parseFindings(matchData.get('findings'));
            info.status = KNOWN_JOB_STATUSES.contains(match.copado__Status__c) ? match.copado__Status__c : JOB_QUEUED;
            info.error = match.copado__ErrorMessage__c;
            info.progressText = latestProgress(match.Id);
            return info;
        }

        /**
         * Reads the two Copado promotion-readiness fields without sharing/FLS on purpose: it is read-only,
         * only called for a story the caller was already proven able to read (loadStory), and the fields
         * belong to the managed package, so a profile/FLS gap there must not break the whole popup.
         */
        public List<Fact> readFacts(Id storyId) {
            List<Fact> facts = new List<Fact>();
            List<copado__User_Story__c> rows = [
                SELECT copado__Pending_Tests__c, copado__Pull_Requests_Approved__c
                FROM copado__User_Story__c
                WHERE Id = :storyId
                LIMIT 1
            ];
            if (rows.isEmpty()) {
                return facts;
            }
            Decimal pending = rows[0].copado__Pending_Tests__c == null ? 0 : rows[0].copado__Pending_Tests__c;
            Fact pendingFact = new Fact();
            pendingFact.label = 'Pending tests';
            pendingFact.value = pending.stripTrailingZeros().toPlainString();
            pendingFact.state = pending > 0 ? 'issue' : 'ok';
            facts.add(pendingFact);

            Boolean approved = StoryVerificationService.isPullRequestApproved(rows[0].copado__Pull_Requests_Approved__c);
            Fact prFact = new Fact();
            prFact.label = 'Pull request approved';
            prFact.value = approved ? 'Yes' : 'No';
            prFact.state = approved ? 'ok' : 'issue';
            facts.add(prFact);
            return facts;
        }

        /**
         * Reads the stored git check results (Verification_Checks__c) without FLS on purpose, like readFacts: read-only and
         * only for a story the caller was already proven able to read.
         */
        public List<CheckResult> readChecks(Id storyId) {
            List<copado__User_Story__c> rows = [
                SELECT Verification_Checks__c
                FROM copado__User_Story__c
                WHERE Id = :storyId
                LIMIT 1
            ];
            if (rows.isEmpty()) {
                return new List<CheckResult>();
            }
            scriptSeconds = parseScriptSeconds(rows[0].Verification_Checks__c);
            Map<String, Object> stored = parseMap(rows[0].Verification_Checks__c);
            finalFindings = stored == null ? new List<Finding>() : parseFindings(stored.get('salesforceFindings'));
            return parseChecks(rows[0].Verification_Checks__c);
        }

        private String latestProgress(Id jobExecutionId) {
            Map<Id, copado__JobStep__c> steps = new Map<Id, copado__JobStep__c>([
                SELECT Id
                FROM copado__JobStep__c
                WHERE copado__JobExecution__c = :jobExecutionId
            ]);
            if (steps.isEmpty()) {
                return null;
            }
            Set<Id> stepIds = steps.keySet();
            for (copado__Result__c result : [
                SELECT Id, copado__Progress_Status__c
                FROM copado__Result__c
                WHERE copado__JobStep__c IN :stepIds
                ORDER BY CreatedDate DESC
                LIMIT :MAX_RESULTS_SCANNED
            ]) {
                if (String.isNotBlank(result.copado__Progress_Status__c)) {
                    return result.copado__Progress_Status__c;
                }
            }
            return null;
        }
    }

    @AuraEnabled
    public static ProgressSnapshot start(Id storyId) {
        try {
            loadStory(storyId);
            String runId = StoryVerificationService.startVerification(storyId);
            return buildSnapshot(storyId, runId);
        } catch (StoryVerificationException e) {
            ProgressSnapshot snapshot = new ProgressSnapshot();
            snapshot.errorMessage = e.getMessage();
            // Hand back the run that blocked this start, so the popup can offer to cancel it.
            copado__User_Story__c story = loadStory(storyId);
            if (story.Verification_Status__c == 'Running' && String.isNotBlank(story.Verification_Run_Id__c)) {
                snapshot.alreadyRunning = true;
                snapshot.runId = story.Verification_Run_Id__c;
            }
            return snapshot;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    // When the run had already finished or been replaced, the snapshot (cancelled = false) shows that state instead.
    @AuraEnabled
    public static ProgressSnapshot cancel(Id storyId, String runId) {
        try {
            loadStory(storyId);
            Boolean cancelled = StoryVerificationService.cancelVerification(storyId, runId);
            ProgressSnapshot snapshot = buildSnapshot(storyId, runId);
            snapshot.cancelled = cancelled;
            return snapshot;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    @AuraEnabled
    public static ProgressSnapshot getProgress(Id storyId, String runId) {
        try {
            return buildSnapshot(storyId, runId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    private static ProgressSnapshot buildSnapshot(Id storyId, String runId) {
        copado__User_Story__c story = loadStory(storyId);
        ProgressSnapshot snapshot = new ProgressSnapshot();
        snapshot.status = story.Verification_Status__c;
        snapshot.runId = story.Verification_Run_Id__c;
        snapshot.isFinished = FINISHED_STATUSES.contains(story.Verification_Status__c);
        snapshot.isCurrentRun = snapshot.runId == runId;
        snapshot.details = splitLines(story.Verification_Details__c);
        snapshot.baseBranch = baseBranchOf(story.Id);

        JobReader reader = new JobReader();
        snapshot.facts = reader.readFacts(story.Id);
        snapshot.checks = reader.readChecks(story.Id);
        snapshot.scriptSeconds = reader.scriptSeconds;
        if (snapshot.isFinished) {
            snapshot.commitBaseUrl = reader.readCommitBaseUrl(story.Id);
            snapshot.canCreateMetadata = StoryVerificationMetadataController.isAllowed();
            snapshot.supportedKinds = StoryVerificationMetadataController.supportedKinds();
        }
        JobInfo info = reader.read(story.Id, snapshot.runId);
        snapshot.findings = snapshot.isFinished && !reader.finalFindings.isEmpty() ? reader.finalFindings : info.findings;
        snapshot.jobStatus = info.status;
        snapshot.jobError = info.error;
        snapshot.progressText = info.progressText;
        return snapshot;
    }

    // Read apart from loadStory (which has already checked the user may open the story), so a user who cannot read the Base Branch
    // field still gets the popup; the header then simply has no base branch line.
    private static String baseBranchOf(Id storyId) {
        try {
            List<copado__User_Story__c> rows = [SELECT copado__Base_Branch__c FROM copado__User_Story__c WHERE Id = :storyId LIMIT 1];
            return rows.isEmpty() || String.isBlank(rows[0].copado__Base_Branch__c) ? null : rows[0].copado__Base_Branch__c.trim();
        } catch (Exception e) {
            return null;
        }
    }

    // USER_MODE enforces object/field read access in addition to sharing, so a user without access gets an error.
    private static copado__User_Story__c loadStory(Id storyId) {
        if (storyId == null) {
            throw auraError('Story Id is required');
        }
        List<copado__User_Story__c> stories;
        try {
            stories = [
                SELECT Id, Verification_Status__c, Verification_Run_Id__c, Verification_Details__c
                FROM copado__User_Story__c
                WHERE Id = :storyId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            throw auraError('You do not have access to this story.');
        }
        if (stories.isEmpty()) {
            throw auraError('You do not have access to this story.');
        }
        return stories[0];
    }

    private static List<String> splitLines(String text) {
        List<String> lines = new List<String>();
        if (String.isBlank(text)) {
            return lines;
        }
        lines.addAll(text.replace('\r\n', '\n').replace('\r', '\n').split('\n'));
        return lines;
    }

    private static String textOf(Object value) {
        return value == null || String.isBlank(String.valueOf(value)) ? null : String.valueOf(value).trim();
    }

    @TestVisible
    private static List<Finding> parseFindings(Object raw) {
        List<Finding> findings = new List<Finding>();
        if (!(raw instanceof List<Object>)) {
            return findings;
        }
        for (Object item : (List<Object>) raw) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> map1 = (Map<String, Object>) item;
            Finding finding = new Finding();
            String severityText = String.valueOf(map1.get('severity'));
            finding.severity = 'issue' == severityText || 'warn' == severityText ? severityText : 'info';
            finding.message = map1.get('message') == null ? '' : String.valueOf(map1.get('message'));
            String groupText = map1.get('group') == null ? '' : String.valueOf(map1.get('group')).trim();
            finding.groupKey = String.isBlank(groupText) ? null : groupText;
            finding.kind = textOf(map1.get('kind'));
            finding.parentId = textOf(map1.get('parentId'));
            finding.parentName = textOf(map1.get('parentName'));
            finding.via = textOf(map1.get('via'));
            finding.parentEnv = textOf(map1.get('parentEnv'));
            finding.childEnv = textOf(map1.get('childEnv'));
            findings.add(finding);
        }
        return findings;
    }

    // The address a commit id is appended to: Copado's own Commit Base URL when it is an https address, otherwise built from a
    // GitHub repository address. Anything else gives null (no links).
    @TestVisible
    private static String commitBaseFrom(String commitBaseUrl, String uri) {
        if (String.isNotBlank(commitBaseUrl)) {
            String base = commitBaseUrl.trim();
            return base.startsWith('https://') ? (base.endsWith('/') ? base : base + '/') : null;
        }
        if (String.isBlank(uri)) {
            return null;
        }
        String repo = uri.trim();
        if (repo.endsWith('.git')) {
            repo = repo.substring(0, repo.length() - 4);
        }
        if (!repo.startsWith('https://github.com/')) {
            return null;
        }
        return (repo.endsWith('/') ? repo : repo + '/') + 'commit/';
    }

    // How long the Function script ran (seconds), from the stored result; null when absent or unreadable.
    @TestVisible
    private static Integer parseScriptSeconds(String raw) {
        Map<String, Object> parsed = parseMap(raw);
        if (parsed == null || parsed.get('scriptSeconds') == null) {
            return null;
        }
        try {
            return Integer.valueOf(String.valueOf(parsed.get('scriptSeconds')));
        } catch (Exception e) {
            return null;
        }
    }

    // Accepts the stored {checks:[...], salesforceFindings:[...]}; anything unreadable gives no checks (the popup then
    // falls back to the details text).
    @TestVisible
    private static List<CheckResult> parseChecks(String raw) {
        List<CheckResult> checks = new List<CheckResult>();
        Map<String, Object> parsed = parseMap(raw);
        if (parsed == null || !(parsed.get('checks') instanceof List<Object>)) {
            return checks;
        }
        for (Object item : (List<Object>) parsed.get('checks')) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> map1 = (Map<String, Object>) item;
            CheckResult check = new CheckResult();
            check.id = asText(map1.get('id'));
            check.title = asText(map1.get('title'));
            String status = asText(map1.get('status')).toLowerCase();
            check.status = CHECK_STATUSES.contains(status) ? status : 'skipped';
            check.summary = asText(map1.get('summary'));
            if (map1.get('lines') instanceof List<Object>) {
                for (Object line : (List<Object>) map1.get('lines')) {
                    if (line != null) {
                        check.lines.add(String.valueOf(line));
                    }
                }
            }
            if (map1.get('rows') instanceof List<Object> && !((List<Object>) map1.get('rows')).isEmpty()) {
                check.rowsJson = JSON.serialize(map1.get('rows'));
            }
            checks.add(check);
        }
        return checks;
    }

    private static String asText(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    private static Map<String, Object> parseMap(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(raw);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
        } catch (JSONException e) {
            return null;
        }
        return null;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
