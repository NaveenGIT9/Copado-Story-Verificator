/**
 * Logic for the Story Verification Gate. Invocable entry points live in StoryVerificationStart /
 * StoryVerificationComplete so each @InvocableMethod stays alone in its class.
 *
 * Record reads/writes run in system mode on purpose (with sharing still applies): normal users have
 * NO edit access to the Verification_* fields, and the completion path runs as whichever user/system
 * context updates the Copado Job Execution, so USER_MODE would make the gate unable to write results.
 */
public with sharing class StoryVerificationService {
    public interface JobStarter {
        void start(copado.CreateExecution.Request req);
    }

    /** Production starter. copado.CreateExecution is managed and cannot be mocked, hence the interface. */
    public class DefaultJobStarter implements JobStarter {
        public void start(copado.CreateExecution.Request req) {
            // The managed API throws when given more than one request, so always exactly one.
            copado.CreateExecution.execute(new List<copado.CreateExecution.Request>{ req });
        }
    }

    @TestVisible
    private static JobStarter starter = new DefaultJobStarter();

    /** Collects save failures from the completion path, which must not throw (see applyOutcomes). */
    @TestVisible
    private static List<String> saveErrors = new List<String>();

    private enum VerificationStatus {
        Running,
        Clean,
        Issues,
        Failed
    }

    // Name of the Job Template as shown on the Job Execution (copado__Template__r.Name).
    @TestVisible
    private static final String TEMPLATE_NAME = 'Story_Verification';
    // copado.CreateExecution.Request.templateName takes the template API name, which Copado versions
    // as <Name>_<version> (see UAM_User_Provisioning_1 in the reference implementation).
    @TestVisible
    private static final String TEMPLATE_API_NAME = 'Story_Verification_1';
    private static final Integer RUNNING_WINDOW_MINUTES = 30;
    private static final Integer MAX_DETAILS_LENGTH = 32000;
    private static final String FEATURE_PREFIX = 'feature/';
    private static final String SEVERITY_ISSUE = 'issue';
    private static final String SEVERITY_INFO = 'info';

    /** One Job Execution reduced to what the completion logic needs. */
    public class JobOutcome {
        public Id storyId;
        public String templateName;
        public String status;
        public String errorMessage;
        public String dataJson;
        public String resultJson;
    }

    public static void startVerification(Id storyId) {
        if (storyId == null) {
            throw new StoryVerificationException('Story Id is required');
        }
        List<copado__User_Story__c> stories = [
            SELECT Id, Name, copado__Base_Branch__c, Verification_Status__c, Verification_Date__c
            FROM copado__User_Story__c
            WHERE Id = :storyId
            LIMIT 1
        ];
        if (stories.isEmpty()) {
            throw new StoryVerificationException('Story not found');
        }
        copado__User_Story__c story = stories[0];
        Datetime startedAt = System.now();

        if (
            story.Verification_Status__c == VerificationStatus.Running.name() &&
            story.Verification_Date__c != null &&
            story.Verification_Date__c > startedAt.addMinutes(-RUNNING_WINDOW_MINUTES)
        ) {
            throw new StoryVerificationException('Verification is already running');
        }

        String runId = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        List<Map<String, String>> findings = buildFindings(story);

        update new copado__User_Story__c(
            Id = story.Id,
            Verification_Status__c = VerificationStatus.Running.name(),
            Verification_Date__c = startedAt,
            Verification_Run_Id__c = runId,
            Verification_Details__c = null
        );

        Map<String, Object> data = new Map<String, Object>{
            'storyId' => story.Id,
            'storyName' => story.Name,
            'runId' => runId,
            'baseBranch' => story.copado__Base_Branch__c,
            'findings' => findings
        };
        copado.CreateExecution.Request req = new copado.CreateExecution.Request();
        req.templateName = TEMPLATE_API_NAME;
        req.parentId = story.Id;
        req.dataJson = JSON.serialize(data);
        req.runAfterInstantiation = true;

        try {
            starter.start(req);
        } catch (Exception e) {
            // When this propagates out of an Apex action the whole transaction rolls back, so the story
            // reverts to its previous state; the Failed write only persists if the caller catches.
            update new copado__User_Story__c(
                Id = story.Id,
                Verification_Status__c = VerificationStatus.Failed.name(),
                Verification_Details__c = truncate('Verification could not be started: ' + e.getMessage())
            );
            throw e;
        }
    }

    public static void completeVerification(Id jobExecutionId) {
        if (jobExecutionId == null) {
            return;
        }
        completeVerifications(new List<Id>{ jobExecutionId });
    }

    public static void completeVerifications(List<Id> jobExecutionIds) {
        if (jobExecutionIds == null || jobExecutionIds.isEmpty()) {
            return;
        }
        applyOutcomes(loadOutcomes(new Set<Id>(jobExecutionIds)));
    }

    private static List<Map<String, String>> buildFindings(copado__User_Story__c story) {
        List<Map<String, String>> findings = new List<Map<String, String>>();

        Integer commitCount = [
            SELECT COUNT()
            FROM copado__User_Story_Commit__c
            WHERE copado__User_Story__c = :story.Id
        ];
        Integer metadataCount = [
            SELECT COUNT()
            FROM copado__User_Story_Metadata__c
            WHERE copado__User_Story__c = :story.Id
        ];

        if (commitCount == 0) {
            findings.add(finding(SEVERITY_ISSUE, 'No commits are registered in Copado for this story.'));
        }
        if (metadataCount == 0) {
            findings.add(finding(SEVERITY_ISSUE, 'No metadata is selected on this story.'));
        }
        addParentFinding(story, findings);
        findings.add(
            finding(
                SEVERITY_INFO,
                'Registered commits: ' + commitCount + ', selected metadata items: ' + metadataCount + '.'
            )
        );
        return findings;
    }

    private static void addParentFinding(copado__User_Story__c story, List<Map<String, String>> findings) {
        String baseBranch = story.copado__Base_Branch__c;
        if (String.isBlank(baseBranch) || !baseBranch.startsWith(FEATURE_PREFIX)) {
            return;
        }
        String parentName = baseBranch.substring(FEATURE_PREFIX.length()).trim();
        if (String.isBlank(parentName)) {
            return;
        }
        List<copado__User_Story__c> parents = [
            SELECT Id, Name, copado__Status__c, copado__Last_Promotion_Date__c
            FROM copado__User_Story__c
            WHERE Name = :parentName
            LIMIT 1
        ];
        if (parents.isEmpty()) {
            findings.add(
                finding(
                    SEVERITY_INFO,
                    'Base branch ' + baseBranch + ' looks like a feature branch but no story named ' + parentName + ' was found.'
                )
            );
            return;
        }
        copado__User_Story__c parent = parents[0];
        if (parent.copado__Status__c != 'Completed' && parent.copado__Last_Promotion_Date__c == null) {
            findings.add(
                finding(
                    SEVERITY_ISSUE,
                    'Base branch is the feature branch of ' + parent.Name + ', which has not been promoted yet.'
                )
            );
        }
    }

    private static Map<String, String> finding(String severity, String message) {
        return new Map<String, String>{ 'severity' => severity, 'message' => message };
    }

    private static List<JobOutcome> loadOutcomes(Set<Id> jobExecutionIds) {
        List<JobOutcome> outcomes = new List<JobOutcome>();
        Set<Id> successfulIds = new Set<Id>();
        List<copado__JobExecution__c> executions = [
            SELECT
                Id,
                copado__ParentRecord_Id__c,
                copado__Status__c,
                copado__ErrorMessage__c,
                copado__DataJson__c,
                copado__Template__r.Name
            FROM copado__JobExecution__c
            WHERE Id IN :jobExecutionIds
        ];
        Map<Id, JobOutcome> outcomeByExecution = new Map<Id, JobOutcome>();
        for (copado__JobExecution__c je : executions) {
            String templateName = je.copado__Template__r?.Name;
            if (templateName != TEMPLATE_NAME) {
                continue;
            }
            JobOutcome outcome = new JobOutcome();
            outcome.storyId = toId(je.copado__ParentRecord_Id__c);
            outcome.templateName = templateName;
            outcome.status = je.copado__Status__c;
            outcome.errorMessage = je.copado__ErrorMessage__c;
            outcome.dataJson = je.copado__DataJson__c;
            outcomes.add(outcome);
            outcomeByExecution.put(je.Id, outcome);
            if (je.copado__Status__c == 'Successful') {
                successfulIds.add(je.Id);
            }
        }
        Map<Id, String> resultByExecution = loadResults(successfulIds);
        for (Id jeId : resultByExecution.keySet()) {
            outcomeByExecution.get(jeId).resultJson = resultByExecution.get(jeId);
        }
        return outcomes;
    }

    // Lookup order: JobStep.copado__ResultDataJson__c first, then copado__Result__c for steps without one.
    private static Map<Id, String> loadResults(Set<Id> executionIds) {
        Map<Id, String> resultByExecution = new Map<Id, String>();
        if (executionIds.isEmpty()) {
            return resultByExecution;
        }
        Map<Id, Id> executionByStep = new Map<Id, Id>();
        Set<Id> stepsWithoutResult = new Set<Id>();
        for (copado__JobStep__c step : [
            SELECT Id, copado__JobExecution__c, copado__ResultDataJson__c
            FROM copado__JobStep__c
            WHERE copado__JobExecution__c IN :executionIds
        ]) {
            executionByStep.put(step.Id, step.copado__JobExecution__c);
            if (String.isNotBlank(step.copado__ResultDataJson__c)) {
                if (!resultByExecution.containsKey(step.copado__JobExecution__c)) {
                    resultByExecution.put(step.copado__JobExecution__c, step.copado__ResultDataJson__c);
                }
            } else {
                stepsWithoutResult.add(step.Id);
            }
        }
        if (stepsWithoutResult.isEmpty()) {
            return resultByExecution;
        }
        for (copado__Result__c result : [
            SELECT Id, copado__JobStep__c, copado__Result_Data__c
            FROM copado__Result__c
            WHERE copado__JobStep__c IN :stepsWithoutResult
            ORDER BY CreatedDate DESC
        ]) {
            Id executionId = executionByStep.get(result.copado__JobStep__c);
            if (String.isNotBlank(result.copado__Result_Data__c) && !resultByExecution.containsKey(executionId)) {
                resultByExecution.put(executionId, result.copado__Result_Data__c);
            }
        }
        return resultByExecution;
    }

    @TestVisible
    private static void applyOutcomes(List<JobOutcome> outcomes) {
        Set<Id> storyIds = new Set<Id>();
        for (JobOutcome outcome : outcomes) {
            if (outcome.storyId != null && outcome.templateName == TEMPLATE_NAME) {
                storyIds.add(outcome.storyId);
            }
        }
        if (storyIds.isEmpty()) {
            return;
        }
        Map<Id, copado__User_Story__c> stories = new Map<Id, copado__User_Story__c>([
            SELECT Id, Verification_Run_Id__c
            FROM copado__User_Story__c
            WHERE Id IN :storyIds
        ]);

        Map<Id, copado__User_Story__c> updates = new Map<Id, copado__User_Story__c>();
        for (JobOutcome outcome : outcomes) {
            copado__User_Story__c story = stories.get(outcome.storyId);
            if (story == null || outcome.templateName != TEMPLATE_NAME) {
                continue;
            }
            String runId = extractRunId(outcome.dataJson);
            // A late or superseded run must not overwrite the current run's state.
            if (String.isBlank(runId) || runId != story.Verification_Run_Id__c) {
                continue;
            }
            copado__User_Story__c storyUpdate = buildUpdate(story.Id, runId, outcome);
            if (storyUpdate != null) {
                updates.put(story.Id, storyUpdate);
            }
        }
        saveUpdates(updates.values());
    }

    private static copado__User_Story__c buildUpdate(Id storyId, String runId, JobOutcome outcome) {
        if (outcome.status == 'Failed' || outcome.status == 'Error') {
            String message = String.isBlank(outcome.errorMessage)
                ? 'The verification job ended with status ' + outcome.status + ' (no error message).'
                : outcome.errorMessage;
            return failed(storyId, 'Verification job failed: ' + message);
        }
        if (outcome.status != 'Successful') {
            return null;
        }
        Map<String, Object> result = parseResult(outcome.resultJson);
        if (result == null) {
            return failed(storyId, 'Result could not be read');
        }
        String resultStatus = String.valueOf(result.get('status'));
        String resultRunId = result.containsKey('runId') ? String.valueOf(result.get('runId')) : runId;
        boolean validStatus =
            resultStatus == VerificationStatus.Clean.name() || resultStatus == VerificationStatus.Issues.name();
        if (!validStatus || resultRunId != runId) {
            return failed(storyId, 'Result could not be read');
        }
        Object details = result.get('details');
        return new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = resultStatus,
            Verification_Details__c = truncate(details == null ? '' : String.valueOf(details))
        );
    }

    private static copado__User_Story__c failed(Id storyId, String details) {
        return new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = VerificationStatus.Failed.name(),
            Verification_Details__c = truncate(details)
        );
    }

    // Must not throw: this runs inside a record-triggered flow on the Job Execution, and an exception
    // would roll back Copado's own status save. Failures are retried once as Failed, then recorded.
    private static void saveUpdates(List<copado__User_Story__c> toSave) {
        if (toSave.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(toSave, false);
        List<copado__User_Story__c> retry = new List<copado__User_Story__c>();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                retry.add(failed(toSave[i].Id, 'Result could not be saved: ' + firstError(results[i])));
            }
        }
        if (retry.isEmpty()) {
            return;
        }
        results = Database.update(retry, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                saveErrors.add(retry[i].Id + ': ' + firstError(results[i]));
            }
        }
    }

    private static String firstError(Database.SaveResult saveResult) {
        List<Database.Error> errors = saveResult.getErrors();
        return errors.isEmpty() ? 'unknown error' : errors[0].getMessage();
    }

    private static Map<String, Object> parseResult(String raw) {
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

    private static String extractRunId(String json) {
        Map<String, Object> parsed = parseResult(json);
        if (parsed == null || parsed.get('runId') == null) {
            return null;
        }
        return String.valueOf(parsed.get('runId'));
    }

    private static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (StringException e) {
            return null;
        }
    }

    private static String truncate(String value) {
        if (value == null) {
            return null;
        }
        return value.length() > MAX_DETAILS_LENGTH ? value.substring(0, MAX_DETAILS_LENGTH) : value;
    }
}
