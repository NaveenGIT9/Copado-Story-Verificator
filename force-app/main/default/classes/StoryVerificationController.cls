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
    private static final Integer MAX_EXECUTIONS_SCANNED = 20;
    private static final Integer MAX_RESULTS_SCANNED = 20;

    public class Finding {
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public String message;
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

        JobReader reader = new JobReader();
        snapshot.facts = reader.readFacts(story.Id);
        JobInfo info = reader.read(story.Id, snapshot.runId);
        snapshot.findings = info.findings;
        snapshot.jobStatus = info.status;
        snapshot.jobError = info.error;
        snapshot.progressText = info.progressText;
        return snapshot;
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
            finding.severity = 'issue' == String.valueOf(map1.get('severity')) ? 'issue' : 'info';
            finding.message = map1.get('message') == null ? '' : String.valueOf(map1.get('message'));
            findings.add(finding);
        }
        return findings;
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
