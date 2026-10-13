/**
 * Logic for the Story Verification Gate. The invocable entry point lives in StoryVerificationComplete so its
 * @InvocableMethod stays alone in its class.
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
    private static final Integer MAX_CHECKS_LENGTH = 100000;
    // Size guards for the DataJson sent to the Function: each list is cut to the first cap that makes the whole
    // DataJson fit (the lists travel as JSON text inside strings, which doubles the quotes).
    private static final List<Integer> LIST_CAPS = new List<Integer>{ 2000, 1000, 500, 250, 100, 0 };
    private static final Integer MAX_DATA_JSON_LENGTH = 90000;
    private static final Integer COMMIT_QUERY_LIMIT = 4001;
    private static final Integer METADATA_QUERY_LIMIT = 2001;
    private static final Integer STEP_QUERY_LIMIT = 2000;
    private static final Integer MAX_PARENTS = 50;
    private static final Integer PARENT_QUERY_LIMIT = 51;
    private static final String GROUP_PULL_REQUEST = 'pull-request';
    private static final String GROUP_PENDING_TESTS = 'pending-tests';
    private static final String GROUP_PARENTS = 'parent-dependencies';
    private static final String VERDICT_AHEAD = 'ahead';
    private static final String VERDICT_NOT_AHEAD = 'not-ahead';
    private static final String VERDICT_UNKNOWN = 'unknown';
    private static final String NO_ENVIRONMENT = 'no environment';
    private static final String VIA_BASE_BRANCH = 'base branch';
    private static final String VIA_DEPENDENCY = 'dependency';
    private static final String NO_GIT_RESULT_LINE = 'Git checks did not report a result - see the Job Execution logs.';
    @TestVisible
    private static final String NO_GIT_RESULT_DETAILS = 'The git checks did not report a result (nothing was verified from git). Open the Job Execution and its Function log.';

    /** One pipeline step reduced to its two environments (used to rank environments, no DML needed to test it). */
    public class StepEdge {
        public Id sourceId;
        public Id destinationId;

        public StepEdge() {
        }

        public StepEdge(Id sourceId, Id destinationId) {
            this.sourceId = sourceId;
            this.destinationId = destinationId;
        }
    }

    /** A parent story plus every way it was reached (base branch and/or Copado dependency). */
    public class ParentLink {
        public copado__User_Story__c story;
        public List<String> labels = new List<String>();
    }

    /** Everything the Function needs from Copado data to run the git checks (it has no Salesforce access). */
    public class GitInputs {
        // Not sent to the Function: only used by the parent story check.
        public List<StepEdge> pipelineEdges = new List<StepEdge>();
        public List<String> envBranches = new List<String>();
        public List<String> registeredCommits = new List<String>();
        public List<Map<String, String>> nonCompleteCommits = new List<Map<String, String>>();
        public List<String> registeredMetadata = new List<String>();
        public Boolean hasCustomLabelMetadata = false;
        public Boolean truncated = false;

        /** Cuts every list to at most cap entries and remembers that something was dropped. */
        public void limitTo(Integer cap) {
            if (envBranches.size() > cap || registeredCommits.size() > cap || nonCompleteCommits.size() > cap || registeredMetadata.size() > cap) {
                truncated = true;
            }
            envBranches = firstOf(envBranches, cap);
            registeredCommits = firstOf(registeredCommits, cap);
            registeredMetadata = firstOf(registeredMetadata, cap);
            List<Map<String, String>> keptCommits = new List<Map<String, String>>();
            for (Integer i = 0; i < nonCompleteCommits.size() && i < cap; i++) {
                keptCommits.add(nonCompleteCommits[i]);
            }
            nonCompleteCommits = keptCommits;
        }

        private List<String> firstOf(List<String> values, Integer cap) {
            List<String> kept = new List<String>();
            for (Integer i = 0; i < values.size() && i < cap; i++) {
                kept.add(values[i]);
            }
            return kept;
        }
    }

    /** One Job Execution reduced to what the completion logic needs. */
    public class JobOutcome {
        public Id storyId;
        public String templateName;
        public String status;
        public String errorMessage;
        public String dataJson;
        public String resultJson;
    }

    /** Returns the new run id so callers (the progress popup) can follow this specific run. */
    // Tests only: Copado's own automation recomputes copado__Pull_Requests_Approved__c whenever a story is saved, so a test
    // cannot set the real field. A test sets this override to control what the verification and the popup see.
    @TestVisible
    private static Boolean pullRequestApprovedOverride;

    public static Boolean isPullRequestApproved(Boolean fieldValue) {
        return pullRequestApprovedOverride != null ? pullRequestApprovedOverride : fieldValue == true;
    }

    public static String startVerification(Id storyId) {
        if (storyId == null) {
            throw new StoryVerificationException('Story Id is required');
        }
        List<copado__User_Story__c> stories = [
            SELECT
                Id,
                Name,
                copado__Base_Branch__c,
                copado__Environment__c,
                copado__Environment__r.Name,
                copado__Project__r.copado__Deployment_Flow__c,
                Verification_Status__c,
                Verification_Date__c,
                copado__Pending_Tests__c,
                copado__Pull_Requests_Approved__c
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
        Id pipelineId = story.copado__Project__r?.copado__Deployment_Flow__c;
        GitInputs inputs = loadGitInputs(story.Id, pipelineId);
        shrinkToFit(story, runId, inputs);
        List<Map<String, String>> findings = buildFindings(story, inputs, pipelineId);

        update new copado__User_Story__c(
            Id = story.Id,
            Verification_Status__c = VerificationStatus.Running.name(),
            Verification_Date__c = startedAt,
            Verification_Run_Id__c = runId,
            Verification_Details__c = null,
            Verification_Checks__c = null
        );

        Map<String, Object> data = buildData(story, runId, inputs, findings);
        copado.CreateExecution.Request req = new copado.CreateExecution.Request();
        req.templateName = TEMPLATE_API_NAME;
        req.parentId = story.Id;
        // Copado resolves {$Context.Repository...} (the git credential) from the pipeline and the source environment.
        if (pipelineId != null) {
            req.pipelineId = pipelineId;
        }
        if (story.copado__Environment__c != null) {
            req.sourceId = story.copado__Environment__c;
        }
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
        return runId;
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

    @TestVisible
    private static Map<String, Object> buildData(
        copado__User_Story__c story,
        String runId,
        GitInputs inputs,
        List<Map<String, String>> findings
    ) {
        // The lists are JSON TEXT inside strings so the Function receives them as plain environment variables.
        return new Map<String, Object>{
            'storyId' => story.Id,
            'storyName' => story.Name,
            'runId' => runId,
            'baseBranch' => story.copado__Base_Branch__c,
            'featureBranch' => FEATURE_PREFIX + story.Name,
            'envBranchesJson' => JSON.serialize(inputs.envBranches),
            'registeredCommitsJson' => JSON.serialize(inputs.registeredCommits),
            'nonCompleteCommitsJson' => JSON.serialize(inputs.nonCompleteCommits),
            'registeredMetadataJson' => JSON.serialize(inputs.registeredMetadata),
            'hasCustomLabelMetadata' => inputs.hasCustomLabelMetadata ? 'true' : 'false',
            'findings' => findings
        };
    }

    @TestVisible
    private static void shrinkToFit(copado__User_Story__c story, String runId, GitInputs inputs) {
        for (Integer cap : LIST_CAPS) {
            inputs.limitTo(cap);
            String dataText = JSON.serialize(buildData(story, runId, inputs, new List<Map<String, String>>()));
            if (dataText.length() <= MAX_DATA_JSON_LENGTH) {
                return;
            }
        }
    }

    // Never throws for missing optional data: no pipeline, no commits, no metadata all just give empty lists.
    private static GitInputs loadGitInputs(Id storyId, Id pipelineId) {
        GitInputs inputs = new GitInputs();

        Integer commitRows = 0;
        Set<String> seenShas = new Set<String>();
        for (copado__User_Story_Commit__c commitRecord : [
            SELECT copado__Status__c, copado__Snapshot_Commit__r.copado__Commit_Id__c
            FROM copado__User_Story_Commit__c
            WHERE copado__User_Story__c = :storyId
            ORDER BY CreatedDate DESC
            LIMIT :COMMIT_QUERY_LIMIT
        ]) {
            commitRows++;
            addCommit(
                inputs,
                seenShas,
                commitRecord.copado__Status__c,
                commitRecord.copado__Snapshot_Commit__r?.copado__Commit_Id__c
            );
        }
        if (commitRows >= COMMIT_QUERY_LIMIT) {
            inputs.truncated = true;
        }

        Integer metadataRows = 0;
        Set<String> seenNames = new Set<String>();
        for (copado__User_Story_Metadata__c metadataRecord : [
            SELECT copado__Metadata_API_Name__c, copado__Type__c
            FROM copado__User_Story_Metadata__c
            WHERE copado__User_Story__c = :storyId
            LIMIT :METADATA_QUERY_LIMIT
        ]) {
            metadataRows++;
            if ('CustomLabel'.equalsIgnoreCase(metadataRecord.copado__Type__c)) {
                inputs.hasCustomLabelMetadata = true;
            }
            // Keep the exact spelling for display (Account.Custom__c); duplicates are detected case-insensitively.
            String name = String.isBlank(metadataRecord.copado__Metadata_API_Name__c)
                ? null
                : metadataRecord.copado__Metadata_API_Name__c.trim();
            if (name != null && seenNames.add(name.toLowerCase())) {
                inputs.registeredMetadata.add(name);
            }
        }
        if (metadataRows >= METADATA_QUERY_LIMIT) {
            inputs.truncated = true;
        }

        if (pipelineId != null) {
            Set<String> seenBranches = new Set<String>();
            for (copado__Deployment_Flow_Step__c pipelineStep : [
                SELECT
                    copado__Branch__c,
                    copado__Destination_Branch__c,
                    copado__Source_Environment__c,
                    copado__Destination_Environment__c
                FROM copado__Deployment_Flow_Step__c
                WHERE copado__Deployment_Flow__c = :pipelineId
                LIMIT :STEP_QUERY_LIMIT
            ]) {
                addBranch(inputs, seenBranches, pipelineStep.copado__Branch__c);
                addBranch(inputs, seenBranches, pipelineStep.copado__Destination_Branch__c);
                inputs.pipelineEdges.add(
                    new StepEdge(pipelineStep.copado__Source_Environment__c, pipelineStep.copado__Destination_Environment__c)
                );
            }
        }
        return inputs;
    }

    // Complete commits are "registered"; every other status is kept with its status text (blank status = Unknown).
    @TestVisible
    private static void addCommit(GitInputs inputs, Set<String> seenShas, String status, String commitId) {
        if (String.isBlank(commitId)) {
            return;
        }
        String sha = commitId.trim().toLowerCase();
        if ('Complete'.equalsIgnoreCase(status)) {
            if (seenShas.add(sha)) {
                inputs.registeredCommits.add(sha);
            }
            return;
        }
        inputs.nonCompleteCommits.add(
            new Map<String, String>{ 'sha' => sha, 'status' => String.isBlank(status) ? 'Unknown' : status }
        );
    }

    // Branch names keep their case (git is case-sensitive); duplicates are detected case-insensitively.
    private static void addBranch(GitInputs inputs, Set<String> seenBranches, String branch) {
        if (String.isBlank(branch)) {
            return;
        }
        String trimmed = branch.trim();
        if (seenBranches.add(trimmed.toLowerCase())) {
            inputs.envBranches.add(trimmed);
        }
    }

    private static List<Map<String, String>> buildFindings(
        copado__User_Story__c story,
        GitInputs inputs,
        Id pipelineId
    ) {
        List<Map<String, String>> findings = new List<Map<String, String>>();

        // Only Complete commit records are registered; other statuses (for example "Commit not in branch") are not counted.
        Integer commitCount = [
            SELECT COUNT()
            FROM copado__User_Story_Commit__c
            WHERE copado__User_Story__c = :story.Id AND copado__Status__c = 'Complete'
        ];
        Integer metadataCount = [
            SELECT COUNT()
            FROM copado__User_Story_Metadata__c
            WHERE copado__User_Story__c = :story.Id
        ];

        if (commitCount == 0) {
            findings.add(finding(SEVERITY_ISSUE, noCommitsMessage()));
        }
        if (metadataCount == 0) {
            findings.add(finding(SEVERITY_ISSUE, 'No metadata selected on this story.'));
        }
        addParentFindings(story, inputs, findings);
        addPendingTestsFinding(story, findings);
        addPullRequestFinding(story, findings);
        findings.add(
            finding(SEVERITY_INFO, commitSummary(commitCount, metadataCount))
        );
        if (inputs.truncated) {
            findings.add(
                finding(
                    SEVERITY_INFO,
                    'Lists cut at ' + LIST_CAPS[0] + ' entries to fit the job size; git checks may be incomplete.'
                )
            );
        }
        if (pipelineId == null) {
            findings.add(finding(SEVERITY_ISSUE, 'Story has no pipeline; git checks could not run.'));
        }
        return findings;
    }

    @TestVisible
    private static String noCommitsMessage() {
        return 'No registered commits.';
    }

    @TestVisible
    private static String commitSummary(Integer completeCount, Integer metadataCount) {
        return 'Registered commits: ' + completeCount + ', metadata items: ' + metadataCount + '.';
    }

    // A null count (never set by Copado) is treated as 0 pending tests.
    private static void addPendingTestsFinding(copado__User_Story__c story, List<Map<String, String>> findings) {
        Decimal pending = story.copado__Pending_Tests__c == null ? 0 : story.copado__Pending_Tests__c;
        // stripTrailingZeros + toPlainString so 3.0 prints as 3 (and 100 as 100, not 1E+2).
        String shown = pending.stripTrailingZeros().toPlainString();
        if (pending > 0) {
            findings.add(
                finding(
                    SEVERITY_ISSUE,
                    shown + ' pending - must be 0.',
                    GROUP_PENDING_TESTS
                )
            );
            return;
        }
        findings.add(finding(SEVERITY_INFO, 'None pending.', GROUP_PENDING_TESTS));
    }

    private static void addPullRequestFinding(copado__User_Story__c story, List<Map<String, String>> findings) {
        if (isPullRequestApproved(story.copado__Pull_Requests_Approved__c)) {
            findings.add(finding(SEVERITY_INFO, 'Approved.', GROUP_PULL_REQUEST));
            return;
        }
        findings.add(finding(SEVERITY_ISSUE, 'Not approved yet.', GROUP_PULL_REQUEST));
    }

    // Parents are the base-branch story (feature/<Name>) and the Copado dependencies where this story is the child.
    // One finding per parent, all in the parent-dependencies group. Two SOQL statements, whatever the number of parents.
    private static void addParentFindings(
        copado__User_Story__c story,
        GitInputs inputs,
        List<Map<String, String>> findings
    ) {
        String baseBranch = story.copado__Base_Branch__c;
        String baseParentName = null;
        if (String.isNotBlank(baseBranch) && baseBranch.startsWith(FEATURE_PREFIX)) {
            String rest = baseBranch.substring(FEATURE_PREFIX.length()).trim();
            if (String.isNotBlank(rest)) {
                baseParentName = rest;
            }
        }

        List<copado__Team_Dependency__c> dependencies = [
            SELECT copado__Provider_User_Story__c
            FROM copado__Team_Dependency__c
            WHERE
                copado__Dependent_User_Story__c = :story.Id
                AND copado__Skip_Dependency__c = FALSE
                AND copado__Provider_User_Story__c != NULL
            ORDER BY CreatedDate
            LIMIT :MAX_PARENTS
        ];
        Set<Id> providerIds = new Set<Id>();
        for (copado__Team_Dependency__c dependency : dependencies) {
            providerIds.add(dependency.copado__Provider_User_Story__c);
        }

        List<copado__User_Story__c> found = new List<copado__User_Story__c>();
        if (baseParentName != null || !providerIds.isEmpty()) {
            found = [
                SELECT
                    Id,
                    Name,
                    copado__Status__c,
                    copado__Last_Promotion_Date__c,
                    copado__Environment__c,
                    copado__Environment__r.Name
                FROM copado__User_Story__c
                WHERE Id IN :providerIds OR Name = :baseParentName
                LIMIT :PARENT_QUERY_LIMIT
            ];
        }
        Map<Id, copado__User_Story__c> storiesById = new Map<Id, copado__User_Story__c>(found);
        Map<String, copado__User_Story__c> storiesByName = new Map<String, copado__User_Story__c>();
        for (copado__User_Story__c candidate : found) {
            storiesByName.put(candidate.Name.toLowerCase(), candidate);
        }

        List<ParentLink> links = new List<ParentLink>();
        Map<Id, ParentLink> linkByStory = new Map<Id, ParentLink>();
        Boolean baseParentMissing = false;
        if (baseParentName != null) {
            copado__User_Story__c baseParent = storiesByName.get(baseParentName.toLowerCase());
            if (baseParent == null) {
                baseParentMissing = true;
            } else {
                addLink(story, links, linkByStory, baseParent, VIA_BASE_BRANCH);
            }
        }
        for (copado__Team_Dependency__c dependency : dependencies) {
            addLink(story, links, linkByStory, storiesById.get(dependency.copado__Provider_User_Story__c), VIA_DEPENDENCY);
        }

        if (baseParentMissing) {
            findings.add(
                finding(
                    SEVERITY_INFO,
                    'Base branch ' + baseBranch + ' names no story (' + baseParentName + ' not found).',
                    GROUP_PARENTS
                )
            );
        }
        if (links.isEmpty()) {
            if (!baseParentMissing) {
                findings.add(finding(SEVERITY_INFO, 'None.', GROUP_PARENTS));
            }
            return;
        }

        Map<Id, Integer> levels = computeLevels(inputs.pipelineEdges);
        Integer childLevel = story.copado__Environment__c == null ? null : levels.get(story.copado__Environment__c);
        String childEnvironmentName = story.copado__Environment__r?.Name;
        for (ParentLink link : links) {
            copado__User_Story__c parent = link.story;
            findings.add(
                parentFinding(
                    parent.Name,
                    String.join(link.labels, ' + '),
                    parent.copado__Status__c,
                    parent.copado__Environment__c,
                    parent.copado__Environment__r?.Name,
                    parent.copado__Last_Promotion_Date__c,
                    story.copado__Environment__c,
                    childEnvironmentName,
                    levels
                )
            );
        }
    }

    // A parent reached more than one way is listed once with every label. A story is never its own parent.
    private static void addLink(
        copado__User_Story__c child,
        List<ParentLink> links,
        Map<Id, ParentLink> linkByStory,
        copado__User_Story__c parent,
        String label
    ) {
        if (parent == null || parent.Id == child.Id) {
            return;
        }
        ParentLink existing = linkByStory.get(parent.Id);
        if (existing == null) {
            if (links.size() >= MAX_PARENTS) {
                return;
            }
            existing = new ParentLink();
            existing.story = parent;
            links.add(existing);
            linkByStory.put(parent.Id, existing);
        }
        if (!existing.labels.contains(label)) {
            existing.labels.add(label);
        }
    }

    /**
     * Level of every environment of a pipeline: the longest distance from an environment that is never a destination
     * (a root, level 0). Iterative relaxation limited to the number of steps, so a cycle cannot loop forever. An
     * environment that is not reachable from a root (for example a pure cycle) gets no level.
     */
    @TestVisible
    private static Map<Id, Integer> computeLevels(List<StepEdge> edges) {
        Map<Id, Integer> levels = new Map<Id, Integer>();
        if (edges == null || edges.isEmpty()) {
            return levels;
        }
        List<StepEdge> usable = new List<StepEdge>();
        Set<Id> destinations = new Set<Id>();
        for (StepEdge edge : edges) {
            if (edge != null && edge.sourceId != null && edge.destinationId != null) {
                usable.add(edge);
                destinations.add(edge.destinationId);
            }
        }
        for (StepEdge edge : usable) {
            if (!destinations.contains(edge.sourceId)) {
                levels.put(edge.sourceId, 0);
            }
        }
        for (Integer pass = 0; pass < usable.size(); pass++) {
            Boolean changed = false;
            for (StepEdge edge : usable) {
                Integer sourceLevel = levels.get(edge.sourceId);
                if (sourceLevel == null) {
                    continue;
                }
                Integer known = levels.get(edge.destinationId);
                if (known == null || known < sourceLevel + 1) {
                    levels.put(edge.destinationId, sourceLevel + 1);
                    changed = true;
                }
            }
            if (!changed) {
                break;
            }
        }
        return levels;
    }

    /** ahead | not-ahead | unknown. A Completed parent is always ahead; without both levels the answer is unknown. */
    @TestVisible
    private static String parentVerdict(Integer childLevel, Integer parentLevel, Boolean parentCompleted) {
        if (parentCompleted == true) {
            return VERDICT_AHEAD;
        }
        if (childLevel == null || parentLevel == null) {
            return VERDICT_UNKNOWN;
        }
        return parentLevel > childLevel ? VERDICT_AHEAD : VERDICT_NOT_AHEAD;
    }

    // Pure (no SOQL/DML) so every wording can be unit-tested.
    @TestVisible
    private static Map<String, String> parentFinding(
        String parentName,
        String via,
        String parentStatus,
        Id parentEnvironmentId,
        String parentEnvironmentName,
        Datetime parentLastPromotion, // copado__Last_Promotion_Date__c is a date/time field
        Id childEnvironmentId,
        String childEnvironmentName,
        Map<Id, Integer> levels
    ) {
        String parentText = environmentText(parentEnvironmentId, parentEnvironmentName);
        String childText = environmentText(childEnvironmentId, childEnvironmentName);
        String prefix = parentName + ' (' + via + ')';
        Boolean completed = parentStatus == 'Completed';
        String ahead = prefix + ' is in ' + parentText + ' - ahead of ' + childText + '.';
        if (completed) {
            return finding(SEVERITY_INFO, ahead, GROUP_PARENTS);
        }
        if (parentEnvironmentId == null) {
            return finding(SEVERITY_ISSUE, prefix + ' has no environment yet; promote it first.', GROUP_PARENTS);
        }
        Integer childLevel = childEnvironmentId == null || levels == null ? null : levels.get(childEnvironmentId);
        Integer parentLevel = levels == null ? null : levels.get(parentEnvironmentId);
        String verdict = parentVerdict(childLevel, parentLevel, completed);
        if (verdict == VERDICT_AHEAD) {
            return finding(SEVERITY_INFO, ahead, GROUP_PARENTS);
        }
        if (verdict == VERDICT_NOT_AHEAD) {
            return finding(
                SEVERITY_ISSUE,
                prefix + ' is in ' + parentText + ' - not ahead of ' + childText + '; promote it first.',
                GROUP_PARENTS
            );
        }
        // No pipeline order available: fall back to "has the parent been promoted at all".
        if (parentLastPromotion != null) {
            return finding(SEVERITY_INFO, prefix + ' is in ' + parentText + ', already promoted.', GROUP_PARENTS);
        }
        return finding(
            SEVERITY_ISSUE,
            prefix + ' is in ' + parentText + ', not promoted yet; promote it first.',
            GROUP_PARENTS
        );
    }

    private static String environmentText(Id environmentId, String environmentName) {
        if (environmentId == null) {
            return NO_ENVIRONMENT;
        }
        return String.isBlank(environmentName) ? 'an unnamed environment' : environmentName;
    }

    private static Map<String, String> finding(String severity, String message) {
        return new Map<String, String>{ 'severity' => severity, 'message' => message };
    }

    private static Map<String, String> finding(String severity, String message, String groupName) {
        Map<String, String> result = finding(severity, message);
        result.put('group', groupName);
        return result;
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
        if (outcome.status == 'Failed' || outcome.status == 'Error' || outcome.status == 'Canceled') {
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
            return fallbackFromFindings(storyId, outcome);
        }
        String resultStatus = String.valueOf(result.get('status'));
        String resultRunId = result.containsKey('runId') ? String.valueOf(result.get('runId')) : runId;
        // The Function itself reports Failed when it could not clone/fetch (nothing was verified from git).
        boolean validStatus =
            resultStatus == VerificationStatus.Clean.name() ||
            resultStatus == VerificationStatus.Issues.name() ||
            resultStatus == VerificationStatus.Failed.name();
        if (!validStatus || resultRunId != runId) {
            return fallbackFromFindings(storyId, outcome);
        }
        Object details = result.get('details');
        return new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = resultStatus,
            Verification_Details__c = truncate(details == null ? '' : String.valueOf(details)),
            Verification_Checks__c = serializeChecks(result)
        );
    }

    // Stores {checks, salesforceFindings} for the popup, or null when the result has no checks or would not fit the field.
    private static String serializeChecks(Map<String, Object> result) {
        Object checks = result.get('checks');
        if (!(checks instanceof List<Object>) || ((List<Object>) checks).isEmpty()) {
            return null;
        }
        Map<String, Object> payload = new Map<String, Object>{ 'checks' => checks };
        Object findings = result.get('salesforceFindings');
        if (findings instanceof List<Object>) {
            payload.put('salesforceFindings', findings);
        } else {
            payload.put('salesforceFindings', new List<Object>());
        }
        if (result.get('scriptSeconds') != null) {
            payload.put('scriptSeconds', result.get('scriptSeconds'));
        }
        String checksText = JSON.serialize(payload);
        if (checksText.length() <= MAX_CHECKS_LENGTH) {
            return checksText;
        }
        checksText = JSON.serialize(new Map<String, Object>{ 'checks' => checks });
        return checksText.length() <= MAX_CHECKS_LENGTH ? checksText : null;
    }

    // The Function's result is not reliably returned through Copado, but a Clean verdict must never be produced without the
    // git checks having run. When the job succeeded but returned no readable result the Apex findings (sent to the Function as
    // input) are all that is left: with an Apex issue the run is Issues, otherwise it is Failed. Without the input there is
    // nothing to rebuild from, so the run is marked Failed.
    private static copado__User_Story__c fallbackFromFindings(Id storyId, JobOutcome outcome) {
        Map<String, Object> input = parseResult(outcome.dataJson);
        Object raw = input == null ? null : input.get('findings');
        if (!(raw instanceof List<Object>)) {
            return failed(storyId, 'Result could not be read');
        }
        Boolean hasIssue = false;
        List<String> lines = new List<String>();
        for (Object o : (List<Object>) raw) {
            if (o instanceof Map<String, Object>) {
                Map<String, Object> f = (Map<String, Object>) o;
                Boolean isIssue = 'issue' == String.valueOf(f.get('severity'));
                hasIssue = hasIssue || isIssue;
                lines.add((isIssue ? 'ISSUE: ' : 'INFO: ') + String.valueOf(f.get('message')));
            }
        }
        if (!hasIssue) {
            return failed(storyId, NO_GIT_RESULT_DETAILS);
        }
        lines.add(NO_GIT_RESULT_LINE);
        return new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = VerificationStatus.Issues.name(),
            Verification_Details__c = truncate(String.join(lines, '\n')),
            Verification_Checks__c = null
        );
    }

    private static copado__User_Story__c failed(Id storyId, String details) {
        return new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = VerificationStatus.Failed.name(),
            Verification_Details__c = truncate(details),
            Verification_Checks__c = null
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

    private static String extractRunId(String jsonText) {
        Map<String, Object> parsed = parseResult(jsonText);
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
