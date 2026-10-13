@IsTest
private class StoryVerificationServiceTest {
    private static final String STORY_TITLE = 'SV Test Story';
    private static final String PARENT_TITLE = 'SV Test Parent Story';
    private static final String COMMIT_SHA = 'ABCDEF1234567890ABCDEF1234567890ABCDEF12';
    private static final String NO_PIPELINE_FINDING = 'issue|Story has no pipeline; git checks could not run.';
    private static final String NO_PARENTS_FINDING = 'info|None.';

    /** Stub for the managed copado.CreateExecution, which cannot be mocked. */
    private class CapturingStarter implements StoryVerificationService.JobStarter {
        public List<copado.CreateExecution.Request> requests = new List<copado.CreateExecution.Request>();
        public void start(copado.CreateExecution.Request req) {
            requests.add(req);
        }
    }

    private class FailingStarter implements StoryVerificationService.JobStarter {
        public void start(copado.CreateExecution.Request req) {
            throw new StoryVerificationException('boom');
        }
    }

    // Some orgs make Jira_Key__c mandatory on the story; fill it when the field exists (set by name so this compiles everywhere).
    private static copado__User_Story__c withJira(copado__User_Story__c story) {
        if (Schema.SObjectType.copado__User_Story__c.fields.getMap().containsKey('Jira_Key__c')) {
            story.put('Jira_Key__c', 'SV-1');
        }
        return story;
    }

    @TestSetup
    static void setup() {
        insert new List<copado__User_Story__c>{
            withJira(
                new copado__User_Story__c(
                    copado__User_Story_Title__c = STORY_TITLE,
                    copado__Pending_Tests__c = 0,
                    copado__Pull_Requests_Approved__c = true
                )
            ),
            withJira(
                new copado__User_Story__c(
                    copado__User_Story_Title__c = PARENT_TITLE,
                    copado__Pending_Tests__c = 0,
                    copado__Pull_Requests_Approved__c = true
                )
            )
        };
    }

    private static void setReadiness(Id storyId, Decimal pendingTests, Boolean prApproved) {
        update new copado__User_Story__c(
            Id = storyId,
            copado__Pending_Tests__c = pendingTests,
            copado__Pull_Requests_Approved__c = prApproved
        );
    }

    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svtest',
            Email = 'svtest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVTest',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svtest.' + suffix + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    private static copado__User_Story__c storyByTitle(String title) {
        return [
            SELECT
                Id,
                Name,
                copado__Base_Branch__c,
                Verification_Status__c,
                Verification_Details__c,
                Verification_Date__c,
                Verification_Run_Id__c,
                Verification_Checks__c
            FROM copado__User_Story__c
            WHERE copado__User_Story_Title__c = :title
            LIMIT 1
        ];
    }

    private static void addCommitAndMetadata(Id storyId) {
        // A commit needs a snapshot commit, which needs a credential (copado__Org__c)
        copado__Org__c credential = new copado__Org__c(Name = 'SV credential');
        insert credential;
        copado__Git_Org_Commit__c snapshot = new copado__Git_Org_Commit__c(
            copado__Org__c = credential.Id,
            copado__Status__c = 'Complete',
            copado__Commit_Id__c = COMMIT_SHA
        );
        insert snapshot;
        insert new copado__User_Story_Commit__c(Name = 'SV commit', copado__User_Story__c = storyId, copado__Snapshot_Commit__c = snapshot.Id);
        insert new copado__User_Story_Metadata__c(
            Name = 'SV metadata',
            copado__User_Story__c = storyId,
            copado__Metadata_API_Name__c = 'Account',
            copado__Type__c = 'CustomObject'
        );
    }

    private static List<String> findingLines(copado.CreateExecution.Request req) {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(req.dataJson);
        List<String> lines = new List<String>();
        for (Object o : (List<Object>) data.get('findings')) {
            Map<String, Object> f = (Map<String, Object>) o;
            lines.add(String.valueOf(f.get('severity')) + '|' + String.valueOf(f.get('message')));
        }
        return lines;
    }

    private static StoryVerificationService.JobOutcome outcome(
        Id storyId,
        String runId,
        String status,
        String resultJson
    ) {
        StoryVerificationService.JobOutcome o = new StoryVerificationService.JobOutcome();
        o.storyId = storyId;
        o.templateName = StoryVerificationService.TEMPLATE_NAME;
        o.status = status;
        o.dataJson = JSON.serialize(new Map<String, Object>{ 'runId' => runId });
        o.resultJson = resultJson;
        return o;
    }

    private static void markRunning(Id storyId, String runId) {
        update new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = 'Running',
            Verification_Run_Id__c = runId,
            Verification_Date__c = System.now()
        );
    }

    @IsTest
    static void startMarksRunningAndStartsJob() {
        StoryVerificationService.pullRequestApprovedOverride = true; // Copado recomputes the real field, so the test sets the hook
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            addCommitAndMetadata(story.Id);
            update new copado__User_Story__c(Id = story.Id, Verification_Checks__c = '{"checks":[]}');
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            Test.startTest();
            StoryVerificationService.startVerification(story.Id);
            Test.stopTest();

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Running', after.Verification_Status__c);
            System.assertEquals(32, after.Verification_Run_Id__c.length());
            System.assertNotEquals(null, after.Verification_Date__c);
            System.assertEquals(null, after.Verification_Details__c);
            System.assertEquals(null, after.Verification_Checks__c, 'Checks of the previous run must be cleared at start');

            System.assertEquals(1, stub.requests.size());
            copado.CreateExecution.Request req = stub.requests[0];
            System.assertEquals('Story_Verification_1', req.templateName);
            System.assertEquals(String.valueOf(story.Id), String.valueOf(req.parentId));
            System.assertEquals(true, req.runAfterInstantiation);

            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(req.dataJson);
            System.assertEquals(String.valueOf(story.Id), String.valueOf(data.get('storyId')));
            System.assertEquals(story.Name, String.valueOf(data.get('storyName')));
            System.assertEquals(after.Verification_Run_Id__c, String.valueOf(data.get('runId')));
            System.assertEquals('feature/' + story.Name, String.valueOf(data.get('featureBranch')));
            List<String> lines = findingLines(req);
            System.assertEquals(5, lines.size(), String.valueOf(lines));
            System.assertEquals(NO_PARENTS_FINDING, lines[0]);
            System.assertEquals('info|None pending.', lines[1]);
            System.assertEquals('info|Approved.', lines[2]);
            System.assertEquals('info|Registered commits: 1, metadata items: 1.', lines[3]);
            System.assertEquals(NO_PIPELINE_FINDING, lines[4]);
        }
    }

    @IsTest
    static void startSendsGitInputsAsJsonTextInTheDataJson() {
        StoryVerificationService.pullRequestApprovedOverride = true;
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(stub.requests[0].dataJson);
            for (String key : new List<String>{
                'envBranchesJson',
                'registeredCommitsJson',
                'nonCompleteCommitsJson',
                'registeredMetadataJson',
                'hasCustomLabelMetadata'
            }) {
                System.assert(data.get(key) instanceof String, key + ' must be a string, not a nested value');
            }
            System.assertEquals('[]', (String) data.get('envBranchesJson'));
            System.assertEquals('false', (String) data.get('hasCustomLabelMetadata'));
            List<Object> metadata = (List<Object>) JSON.deserializeUntyped((String) data.get('registeredMetadataJson'));
            System.assertEquals(1, metadata.size());
            System.assertEquals('Account', metadata[0], 'The exact spelling is kept');
            // Copado may derive the commit status from the snapshot, so accept either bucket, but the SHA must be in exactly one.
            List<Object> registered = (List<Object>) JSON.deserializeUntyped((String) data.get('registeredCommitsJson'));
            List<Object> nonComplete = (List<Object>) JSON.deserializeUntyped((String) data.get('nonCompleteCommitsJson'));
            System.assertEquals(1, registered.size() + nonComplete.size());
            String shown = registered.isEmpty()
                ? String.valueOf(((Map<String, Object>) nonComplete[0]).get('sha'))
                : String.valueOf(registered[0]);
            System.assertEquals(COMMIT_SHA.toLowerCase(), shown);
        }
    }

    @IsTest
    static void startFlagsStoryWithoutPipelineAndLeavesPipelineUnset() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            System.assertEquals(1, stub.requests.size(), 'The job must still start so the result path works');
            System.assertEquals(null, stub.requests[0].pipelineId);
            System.assertEquals(null, stub.requests[0].sourceId);
            System.assert(findingLines(stub.requests[0]).contains(NO_PIPELINE_FINDING), String.valueOf(findingLines(stub.requests[0])));
        }
    }

    // The required fields of these managed Copado objects were not confirmed by describe; if DML fails here a
    // managed-package required field, validation or trigger is the likely cause.
    @IsTest
    static void startSetsPipelineSourceAndEnvironmentBranchesOnTheRequest() {
        StoryVerificationService.pullRequestApprovedOverride = true;
        User admin = newAdmin();
        System.runAs(admin) {
            copado__Environment__c sourceEnv = new copado__Environment__c(Name = 'SV source env');
            copado__Environment__c destinationEnv = new copado__Environment__c(Name = 'SV destination env');
            insert new List<copado__Environment__c>{ sourceEnv, destinationEnv };
            copado__Deployment_Flow__c pipeline = new copado__Deployment_Flow__c(Name = 'SV pipeline');
            insert pipeline;
            copado__Project__c project = new copado__Project__c(Name = 'SV project', copado__Deployment_Flow__c = pipeline.Id);
            insert project;
            insert new copado__Deployment_Flow_Step__c(
                copado__Deployment_Flow__c = pipeline.Id,
                copado__Source_Environment__c = sourceEnv.Id,
                copado__Destination_Environment__c = destinationEnv.Id,
                copado__Branch__c = 'SV-Qa',
                copado__Destination_Branch__c = 'sv-main'
            );
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(
                Id = story.Id,
                copado__Project__c = project.Id,
                copado__Environment__c = sourceEnv.Id
            );
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            copado.CreateExecution.Request req = stub.requests[0];
            System.assertEquals(String.valueOf(pipeline.Id), String.valueOf(req.pipelineId));
            System.assertEquals(String.valueOf(sourceEnv.Id), String.valueOf(req.sourceId));
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(req.dataJson);
            Set<String> branches = new Set<String>();
            for (Object branch : (List<Object>) JSON.deserializeUntyped((String) data.get('envBranchesJson'))) {
                branches.add(String.valueOf(branch));
            }
            System.assertEquals(new Set<String>{ 'SV-Qa', 'sv-main' }, branches);
            System.assert(!findingLines(req).contains(NO_PIPELINE_FINDING), 'A story with a pipeline must not get the finding');
        }
    }

    @IsTest
    static void buildDataSerialisesTheListsAsJsonText() {
        copado__User_Story__c story = storyByTitle(STORY_TITLE);
        StoryVerificationService.GitInputs inputs = new StoryVerificationService.GitInputs();
        Set<String> seen = new Set<String>();
        StoryVerificationService.addCommit(inputs, seen, 'Complete', ' ABC1234567 ');
        StoryVerificationService.addCommit(inputs, seen, 'Complete', 'abc1234567');
        StoryVerificationService.addCommit(inputs, seen, 'Commit not in branch', 'DEF7654321');
        StoryVerificationService.addCommit(inputs, seen, null, 'fed0000000');
        StoryVerificationService.addCommit(inputs, seen, 'Complete', '  ');
        inputs.registeredMetadata.add('account');
        inputs.envBranches.add('qa');
        inputs.envBranches.add('Main');
        inputs.hasCustomLabelMetadata = true;

        Map<String, Object> data = StoryVerificationService.buildData(
            story,
            'run-x',
            inputs,
            new List<Map<String, String>>()
        );
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(data));

        System.assertEquals('["abc1234567"]', (String) sent.get('registeredCommitsJson'));
        System.assertEquals('["account"]', (String) sent.get('registeredMetadataJson'));
        System.assertEquals('["qa","Main"]', (String) sent.get('envBranchesJson'));
        System.assertEquals('true', (String) sent.get('hasCustomLabelMetadata'));
        List<Object> nonComplete = (List<Object>) JSON.deserializeUntyped((String) sent.get('nonCompleteCommitsJson'));
        System.assertEquals(2, nonComplete.size());
        Map<String, Object> first = (Map<String, Object>) nonComplete[0];
        System.assertEquals('def7654321', first.get('sha'));
        System.assertEquals('Commit not in branch', first.get('status'));
        Map<String, Object> second = (Map<String, Object>) nonComplete[1];
        System.assertEquals('fed0000000', second.get('sha'));
        System.assertEquals('Unknown', second.get('status'));
        System.assertEquals('feature/' + story.Name, sent.get('featureBranch'));
    }

    @IsTest
    static void limitToCapsEveryListAndRemembersTheTruncation() {
        StoryVerificationService.GitInputs inputs = new StoryVerificationService.GitInputs();
        for (Integer i = 0; i < 2500; i++) {
            inputs.registeredCommits.add('sha' + i);
            inputs.registeredMetadata.add('meta' + i);
        }
        inputs.limitTo(2000);
        System.assertEquals(2000, inputs.registeredCommits.size());
        System.assertEquals(2000, inputs.registeredMetadata.size());
        System.assertEquals(true, inputs.truncated);

        StoryVerificationService.GitInputs small = new StoryVerificationService.GitInputs();
        small.registeredCommits.add('only');
        small.limitTo(2000);
        System.assertEquals(1, small.registeredCommits.size());
        System.assertEquals(false, small.truncated);
        small.limitTo(0);
        System.assertEquals(0, small.registeredCommits.size());
        System.assertEquals(true, small.truncated);
    }

    @IsTest
    static void shrinkToFitKeepsTheDataJsonUnderTheSizeLimit() {
        copado__User_Story__c story = storyByTitle(STORY_TITLE);
        StoryVerificationService.GitInputs inputs = new StoryVerificationService.GitInputs();
        for (Integer i = 0; i < 2000; i++) {
            inputs.registeredCommits.add(String.valueOf(i).leftPad(40, '0'));
            inputs.registeredMetadata.add('Some_Long_Component_Name_For_Size_Test_' + i);
        }

        StoryVerificationService.shrinkToFit(story, 'run-big', inputs);

        String dataText = JSON.serialize(
            StoryVerificationService.buildData(story, 'run-big', inputs, new List<Map<String, String>>())
        );
        System.assert(dataText.length() <= 90000, 'DataJson is ' + dataText.length() + ' characters');
        System.assertEquals(true, inputs.truncated);
        System.assert(inputs.registeredCommits.size() < 2000);
    }

    @IsTest
    static void startReportsMissingCommitsAndMetadata() {
        StoryVerificationService.pullRequestApprovedOverride = true; // Copado recomputes the real field, so the test sets the hook
        User admin = newAdmin();
        System.runAs(admin) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(storyByTitle(STORY_TITLE).Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assertEquals(7, lines.size(), String.valueOf(lines));
            System.assertEquals('issue|No registered commits.', lines[0]);
            System.assertEquals('issue|No metadata selected on this story.', lines[1]);
            System.assertEquals(NO_PARENTS_FINDING, lines[2]);
            System.assertEquals('info|None pending.', lines[3]);
            System.assertEquals('info|Approved.', lines[4]);
            System.assertEquals('info|Registered commits: 0, metadata items: 0.', lines[5]);
            System.assertEquals(NO_PIPELINE_FINDING, lines[6]);
        }
    }

    @IsTest
    static void startFlagsUnpromotedParentFeatureBranch() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c parent = storyByTitle(PARENT_TITLE);
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(Id = parent.Id, copado__Status__c = 'In Progress');
            update new copado__User_Story__c(Id = story.Id, copado__Base_Branch__c = 'feature/' + parent.Name);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            // The parent has no environment, so it cannot have been promoted.
            System.assert(
                lines.contains(
                    'issue|' + parent.Name + ' (base branch) has no environment yet; promote it first.'
                ),
                'Unpromoted parent must be an issue: ' + lines
            );
            System.assert(!lines.contains(NO_PARENTS_FINDING), 'A parent was found: ' + lines);
        }
    }

    @IsTest
    static void startAcceptsCompletedParent() {
        StoryVerificationService.pullRequestApprovedOverride = true; // Copado recomputes the real field, so the test sets the hook
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c parent = storyByTitle(PARENT_TITLE);
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(Id = parent.Id, copado__Status__c = 'Completed');
            update new copado__User_Story__c(Id = story.Id, copado__Base_Branch__c = 'feature/' + parent.Name);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assertEquals(5, lines.size(), 'Only info lines (plus the no-pipeline issue) expected: ' + lines);
            for (String line : lines) {
                if (line != NO_PIPELINE_FINDING) {
                    System.assert(line.startsWith('info|'), 'Completed parent must not raise an issue: ' + line);
                }
            }
            System.assertEquals(
                'info|' + parent.Name + ' (base branch) is in no environment - ahead of no environment.',
                lines[0]
            );
            System.assert(lines[3].startsWith('info|Registered commits'));
        }
    }

    @IsTest
    static void startNotesUnknownParentAsInfo() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(Id = story.Id, copado__Base_Branch__c = 'feature/US-NOPE-1');
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assertEquals(5, lines.size(), String.valueOf(lines));
            System.assertEquals('info|Base branch feature/US-NOPE-1 names no story (US-NOPE-1 not found).', lines[0]);
        }
    }

    @IsTest
    static void startIgnoresNonFeatureBaseBranch() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(Id = story.Id, copado__Base_Branch__c = 'main');
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assertEquals(5, lines.size(), String.valueOf(lines));
            System.assertEquals(NO_PARENTS_FINDING, lines[0]);
        }
    }

    // ---- parent story dependencies ----

    private static Id fakeId(Integer n) {
        return Id.valueOf('001' + String.valueOf(n).leftPad(12, '0'));
    }

    private static StoryVerificationService.StepEdge edge(Integer sourceNumber, Integer destinationNumber) {
        return new StoryVerificationService.StepEdge(fakeId(sourceNumber), fakeId(destinationNumber));
    }

    private static Map<String, Object> findingWithMessage(copado.CreateExecution.Request req, String messagePrefix) {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(req.dataJson);
        for (Object o : (List<Object>) data.get('findings')) {
            Map<String, Object> f = (Map<String, Object>) o;
            if (String.valueOf(f.get('message')).startsWith(messagePrefix)) {
                return f;
            }
        }
        return null;
    }

    @IsTest
    static void computeLevelsHandlesAChain() {
        // 1 -> 2 -> 3 -> 4
        Map<Id, Integer> levels = StoryVerificationService.computeLevels(
            new List<StoryVerificationService.StepEdge>{ edge(3, 4), edge(1, 2), edge(2, 3) }
        );
        System.assertEquals(4, levels.size());
        System.assertEquals(0, levels.get(fakeId(1)));
        System.assertEquals(1, levels.get(fakeId(2)));
        System.assertEquals(2, levels.get(fakeId(3)));
        System.assertEquals(3, levels.get(fakeId(4)));
    }

    @IsTest
    static void computeLevelsHandlesTwoRootsAndALongestPath() {
        // Dev1 (1) and Dev2 (2) -> INT (3) -> UAT (4) -> Prod (5); Hotfix (6) -> Prod (5)
        Map<Id, Integer> levels = StoryVerificationService.computeLevels(
            new List<StoryVerificationService.StepEdge>{
                edge(1, 3),
                edge(2, 3),
                edge(3, 4),
                edge(4, 5),
                edge(6, 5)
            }
        );
        System.assertEquals(0, levels.get(fakeId(1)));
        System.assertEquals(0, levels.get(fakeId(2)));
        System.assertEquals(1, levels.get(fakeId(3)));
        System.assertEquals(2, levels.get(fakeId(4)));
        System.assertEquals(0, levels.get(fakeId(6)));
        System.assertEquals(3, levels.get(fakeId(5)), 'Production takes the longest path, not the Hotfix shortcut');
    }

    @IsTest
    static void computeLevelsSurvivesCycles() {
        // A pure cycle has no root, so nothing gets a level (and nothing loops forever).
        Map<Id, Integer> pureCycle = StoryVerificationService.computeLevels(
            new List<StoryVerificationService.StepEdge>{ edge(1, 2), edge(2, 1) }
        );
        System.assertEquals(0, pureCycle.size());

        // A cycle behind a root terminates and keeps the root at 0.
        Map<Id, Integer> reachable = StoryVerificationService.computeLevels(
            new List<StoryVerificationService.StepEdge>{ edge(1, 2), edge(2, 3), edge(3, 2) }
        );
        System.assertEquals(0, reachable.get(fakeId(1)));
        System.assert(reachable.containsKey(fakeId(2)));
        System.assert(reachable.containsKey(fakeId(3)));
    }

    @IsTest
    static void computeLevelsHandlesEmptyAndIncompleteInput() {
        System.assertEquals(0, StoryVerificationService.computeLevels(null).size());
        System.assertEquals(0, StoryVerificationService.computeLevels(new List<StoryVerificationService.StepEdge>()).size());
        Map<Id, Integer> levels = StoryVerificationService.computeLevels(
            new List<StoryVerificationService.StepEdge>{
                new StoryVerificationService.StepEdge(),
                new StoryVerificationService.StepEdge(fakeId(1), null),
                null,
                edge(2, 3)
            }
        );
        System.assertEquals(2, levels.size(), 'Only the complete edge counts');
        System.assertEquals(0, levels.get(fakeId(2)));
        System.assertEquals(1, levels.get(fakeId(3)));
    }

    @IsTest
    static void parentVerdictCoversAheadNotAheadCompletedAndUnknown() {
        System.assertEquals('ahead', StoryVerificationService.parentVerdict(0, 2, false));
        System.assertEquals('not-ahead', StoryVerificationService.parentVerdict(2, 1, false));
        System.assertEquals('not-ahead', StoryVerificationService.parentVerdict(1, 1, false), 'Same environment is not ahead');
        System.assertEquals('ahead', StoryVerificationService.parentVerdict(3, 0, true), 'Completed always counts as ahead');
        System.assertEquals('ahead', StoryVerificationService.parentVerdict(null, null, true));
        System.assertEquals('unknown', StoryVerificationService.parentVerdict(null, 1, false));
        System.assertEquals('unknown', StoryVerificationService.parentVerdict(1, null, false));
        System.assertEquals('ahead', StoryVerificationService.parentVerdict(1, 2, null), 'A null Completed flag counts as not completed');
    }

    @IsTest
    static void parentFindingWordingForEveryCase() {
        Id devEnv = fakeId(1);
        Id intEnv = fakeId(2);
        Id otherEnv = fakeId(9);
        Map<Id, Integer> levels = new Map<Id, Integer>{ devEnv => 0, intEnv => 1 };

        Map<String, String> ahead = StoryVerificationService.parentFinding(
            'US-1', 'base branch', 'In Progress', intEnv, 'INT-SFP', null, devEnv, 'Dev1-SFP', levels
        );
        System.assertEquals('info', ahead.get('severity'));
        System.assertEquals('US-1 (base branch) is in INT-SFP - ahead of Dev1-SFP.', ahead.get('message'));
        System.assertEquals('parent-dependencies', ahead.get('group'));

        Map<String, String> notAhead = StoryVerificationService.parentFinding(
            'US-2', 'dependency', 'In Progress', devEnv, 'Dev2-SFP', null, intEnv, 'INT-SFP', levels
        );
        System.assertEquals('issue', notAhead.get('severity'));
        System.assertEquals('US-2 (dependency) is in Dev2-SFP - not ahead of INT-SFP; promote it first.', notAhead.get('message'));

        Map<String, String> completed = StoryVerificationService.parentFinding(
            'US-3', 'base branch + dependency', 'Completed', devEnv, 'Dev1-SFP', null, intEnv, 'INT-SFP', levels
        );
        System.assertEquals('info', completed.get('severity'));
        System.assertEquals('US-3 (base branch + dependency) is in Dev1-SFP - ahead of INT-SFP.', completed.get('message'));

        Map<String, String> noEnvironment = StoryVerificationService.parentFinding(
            'US-4', 'base branch', 'In Progress', null, null, null, intEnv, 'INT-SFP', levels
        );
        System.assertEquals('issue', noEnvironment.get('severity'));
        System.assertEquals('US-4 (base branch) has no environment yet; promote it first.', noEnvironment.get('message'));

        // An environment missing from the pipeline steps: fall back to the promotion date.
        Map<String, String> fallbackOk = StoryVerificationService.parentFinding(
            'US-5', 'base branch', 'In Progress', otherEnv, 'Elsewhere', System.now(), devEnv, 'Dev1-SFP', levels
        );
        System.assertEquals('info', fallbackOk.get('severity'));
        System.assertEquals('US-5 (base branch) is in Elsewhere, already promoted.', fallbackOk.get('message'));

        Map<String, String> fallbackIssue = StoryVerificationService.parentFinding(
            'US-6', 'base branch', 'In Progress', otherEnv, 'Elsewhere', null, null, null, new Map<Id, Integer>()
        );
        System.assertEquals('issue', fallbackIssue.get('severity'));
        System.assertEquals('US-6 (base branch) is in Elsewhere, not promoted yet; promote it first.', fallbackIssue.get('message'));
    }

    @IsTest
    static void startFlagsACopadoDependencyParentWithoutPipelineUsingTheFallbackRule() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__Environment__c parentEnv = new copado__Environment__c(Name = 'SV parent env');
            insert parentEnv;
            copado__User_Story__c parent = storyByTitle(PARENT_TITLE);
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(Id = parent.Id, copado__Status__c = 'In Progress', copado__Environment__c = parentEnv.Id);
            // The via label is 'dependency' whatever relationship type Copado fills in.
            insert new copado__Team_Dependency__c(
                copado__Dependent_User_Story__c = story.Id,
                copado__Provider_User_Story__c = parent.Id
            );
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            Map<String, Object> found = findingWithMessage(stub.requests[0], parent.Name + ' (');
            System.assertNotEquals(null, found, String.valueOf(findingLines(stub.requests[0])));
            String message = String.valueOf(found.get('message'));
            System.assertEquals('issue', found.get('severity'), message);
            System.assertEquals('parent-dependencies', found.get('group'));
            System.assertEquals(parent.Name + ' (dependency) is in SV parent env, not promoted yet; promote it first.', message);
            System.assert(!findingLines(stub.requests[0]).contains(NO_PARENTS_FINDING));
        }
    }

    @IsTest
    static void startListsAParentReachedByBaseBranchAndDependencyOnce() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c parent = storyByTitle(PARENT_TITLE);
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            // Not Completed: Copado treats a dependency on a Completed parent as skipped (read-only copado__Skip_Dependency__c).
            update new copado__User_Story__c(Id = parent.Id, copado__Status__c = 'In Progress');
            update new copado__User_Story__c(Id = story.Id, copado__Base_Branch__c = 'feature/' + parent.Name);
            insert new copado__Team_Dependency__c(
                copado__Dependent_User_Story__c = story.Id,
                copado__Provider_User_Story__c = parent.Id
            );
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            Integer parentLines = 0;
            String parentMessage;
            for (String line : findingLines(stub.requests[0])) {
                if (line.contains(parent.Name + ' (')) {
                    parentLines++;
                    parentMessage = line;
                }
            }
            System.assertEquals(1, parentLines, String.valueOf(findingLines(stub.requests[0])));
            System.assert(parentMessage.contains('(base branch + dependency)'), parentMessage);
            System.assert(parentMessage.startsWith('issue|'), parentMessage); // no environment and no pipeline: fallback rule, not promoted
        }
    }

    @IsTest
    static void startReportsNoParentDependenciesWhenThereAreNone() {
        User admin = newAdmin();
        System.runAs(admin) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(storyByTitle(STORY_TITLE).Id);

            Map<String, Object> found = findingWithMessage(stub.requests[0], 'None.');
            System.assertNotEquals(null, found);
            System.assertEquals('info', found.get('severity'));
            System.assertEquals('parent-dependencies', found.get('group'));
        }
    }

    @IsTest
    static void startMarksGroupedFindingsWithTheirGroup() {
        StoryVerificationService.pullRequestApprovedOverride = true;
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            copado.CreateExecution.Request req = stub.requests[0];
            System.assertEquals('pull-request', findingWithMessage(req, 'Approved.').get('group'));
            System.assertEquals('pending-tests', findingWithMessage(req, 'None pending.').get('group'));
            System.assertEquals('parent-dependencies', findingWithMessage(req, 'None.').get('group'));
            Map<String, Object> ungrouped = findingWithMessage(req, 'Registered commits');
            System.assertEquals(false, ungrouped.containsKey('group'), 'Ungrouped findings carry no group key');
        }
    }

    @IsTest
    static void startFlagsPendingTestsWithTheNumber() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            setReadiness(story.Id, 3, true);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assert(
                lines.contains('issue|3 pending - must be 0.'),
                String.valueOf(lines)
            );
            System.assert(!lines.contains('info|None pending.'), String.valueOf(lines));
        }
    }

    @IsTest
    static void startTreatsNullPendingTestsAsZero() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            setReadiness(story.Id, null, true);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assert(lines.contains('info|None pending.'), String.valueOf(lines));
        }
    }

    @IsTest
    static void startFlagsUnapprovedPullRequest() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            setReadiness(story.Id, 0, false);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assert(lines.contains('issue|Not approved yet.'), String.valueOf(lines));
            System.assert(!lines.contains('info|Approved.'), String.valueOf(lines));
        }
    }

    @IsTest
    static void startReportsTwoInfoFindingsWhenReadinessIsFine() {
        StoryVerificationService.pullRequestApprovedOverride = true; // Copado recomputes the real field, so the test sets the hook
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assert(lines.contains('info|None pending.'), String.valueOf(lines));
            System.assert(lines.contains('info|Approved.'), String.valueOf(lines));
            for (String line : lines) {
                if (line != NO_PIPELINE_FINDING) {
                    System.assert(line.startsWith('info|'), 'No issue expected: ' + line);
                }
            }
        }
    }

    @IsTest
    static void fallbackVerdictIsIssuesWhenPullRequestNotApproved() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            setReadiness(story.Id, 0, false);
            addCommitAndMetadata(story.Id);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;
            StoryVerificationService.startVerification(story.Id);
            copado__User_Story__c running = storyByTitle(STORY_TITLE);

            // The job succeeded but returned no readable result: the verdict is rebuilt from the job's own input.
            StoryVerificationService.JobOutcome o = outcome(story.Id, running.Verification_Run_Id__c, 'Successful', null);
            o.dataJson = stub.requests[0].dataJson;
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ o });

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', after.Verification_Status__c);
            System.assert(
                after.Verification_Details__c.contains('ISSUE: Not approved yet.'),
                after.Verification_Details__c
            );
            System.assert(
                after.Verification_Details__c.contains('Git checks did not report a result - see the Job Execution logs.'),
                after.Verification_Details__c
            );
            System.assertEquals(null, after.Verification_Checks__c);
        }
    }

    @IsTest
    static void startRejectsDoubleRun() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;
            StoryVerificationService.startVerification(story.Id);

            try {
                StoryVerificationService.startVerification(story.Id);
                System.assert(false, 'Second start within 30 minutes must throw');
            } catch (StoryVerificationException e) {
                System.assertEquals('Verification is already running', e.getMessage());
            }
            System.assertEquals(1, stub.requests.size(), 'No second job may be started');
        }
    }

    @IsTest
    static void startRestartsStaleRunningVerification() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            update new copado__User_Story__c(
                Id = story.Id,
                Verification_Status__c = 'Running',
                Verification_Run_Id__c = 'old-run',
                Verification_Date__c = System.now().addMinutes(-31)
            );
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(story.Id);

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals(1, stub.requests.size());
            System.assertNotEquals('old-run', after.Verification_Run_Id__c);
            System.assert(after.Verification_Date__c > System.now().addMinutes(-5));
        }
    }

    @IsTest
    static void startRecordsFailureWhenJobCannotStart() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            StoryVerificationService.starter = new FailingStarter();

            try {
                StoryVerificationService.startVerification(story.Id);
                System.assert(false, 'Start failure must be rethrown');
            } catch (StoryVerificationException e) {
                System.assertEquals('boom', e.getMessage());
            }
            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assert(after.Verification_Details__c.contains('boom'), after.Verification_Details__c);
        }
    }

    @IsTest
    static void startRejectsNullAndMissingStory() {
        User admin = newAdmin();
        System.runAs(admin) {
            StoryVerificationService.starter = new CapturingStarter();
            try {
                StoryVerificationService.startVerification(null);
                System.assert(false, 'Null Id must throw');
            } catch (StoryVerificationException e) {
                System.assertEquals('Story Id is required', e.getMessage());
            }

            copado__User_Story__c doomed = withJira(
                new copado__User_Story__c(
                    copado__User_Story_Title__c = 'SV doomed',
                    copado__Pending_Tests__c = 0,
                    copado__Pull_Requests_Approved__c = true
                )
            );
            insert doomed;
            delete doomed;
            try {
                StoryVerificationService.startVerification(doomed.Id);
                System.assert(false, 'Deleted story must throw');
            } catch (StoryVerificationException e) {
                System.assertEquals('Story not found', e.getMessage());
            }
        }
    }

    @IsTest
    static void defaultStarterIsInstalledByDefault() {
        System.assert(
            StoryVerificationService.starter instanceof StoryVerificationService.DefaultJobStarter,
            'Production code must use the real Copado starter unless a test injects a stub'
        );
    }

    @IsTest
    static void completeWritesCleanResult() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-1');
            String result = '{"runId":"run-1","status":"Clean","details":"INFO: all good"}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-1', 'Successful', result) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Clean', after.Verification_Status__c);
            System.assertEquals('INFO: all good', after.Verification_Details__c);
        }
    }

    @IsTest
    static void completeWritesIssuesResult() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-2');
            String result = '{"runId":"run-2","status":"Issues","details":"ISSUE: one"}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-2', 'Successful', result) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', after.Verification_Status__c);
            System.assertEquals('ISSUE: one', after.Verification_Details__c);
        }
    }

    @IsTest
    static void completeIgnoresStaleRunId() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'current-run');
            String result = '{"runId":"old-run","status":"Clean","details":"late"}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'old-run', 'Successful', result) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Running', after.Verification_Status__c);
            System.assertEquals('current-run', after.Verification_Run_Id__c);
        }
    }

    @IsTest
    static void completeIgnoresOtherTemplateAndMissingRunId() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-3');
            StoryVerificationService.JobOutcome otherTemplate = outcome(story.Id, 'run-3', 'Failed', null);
            otherTemplate.templateName = 'Something_Else';
            StoryVerificationService.JobOutcome noRunId = outcome(story.Id, 'run-3', 'Failed', null);
            noRunId.dataJson = null;
            StoryVerificationService.JobOutcome inProgress = outcome(story.Id, 'run-3', 'In Progress', null);

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ otherTemplate, noRunId, inProgress }
            );

            System.assertEquals('Running', storyByTitle(STORY_TITLE).Verification_Status__c);
        }
    }

    @IsTest
    static void completeRecordsFailedJob() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-4');
            StoryVerificationService.JobOutcome failed = outcome(story.Id, 'run-4', 'Failed', null);
            failed.errorMessage = 'kaboom';

            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ failed });

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assert(after.Verification_Details__c.contains('kaboom'), after.Verification_Details__c);
        }
    }

    @IsTest
    static void completeRecordsErrorJobWithoutMessage() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-5');

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-5', 'Error', null) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assert(after.Verification_Details__c.contains('no error message'), after.Verification_Details__c);
        }
    }

    @IsTest
    static void completeFailsWhenResultUnreadable() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            List<String> badResults = new List<String>{
                null,
                'not json at all',
                '[1,2]',
                '{"runId":"run-6","status":"Weird","details":"x"}',
                '{"runId":"other","status":"Clean","details":"x"}'
            };
            for (String bad : badResults) {
                markRunning(story.Id, 'run-6');
                StoryVerificationService.applyOutcomes(
                    new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-6', 'Successful', bad) }
                );
                copado__User_Story__c after = storyByTitle(STORY_TITLE);
                System.assertEquals('Failed', after.Verification_Status__c, 'Result: ' + bad);
                System.assertEquals('Result could not be read', after.Verification_Details__c, 'Result: ' + bad);
            }
        }
    }

    @IsTest
    static void completeRebuildsVerdictFromFindingsWhenResultMissing() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);

            // Only info findings: nothing was verified from git, so this must NOT be Clean.
            markRunning(story.Id, 'run-fb1');
            StoryVerificationService.JobOutcome noGitResult = outcome(story.Id, 'run-fb1', 'Successful', null);
            noGitResult.dataJson = JSON.serialize(new Map<String, Object>{
                'runId' => 'run-fb1',
                'findings' => new List<Object>{
                    new Map<String, Object>{ 'severity' => 'info', 'message' => 'Registered commits: 1' }
                }
            });
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ noGitResult });
            copado__User_Story__c afterNoGit = storyByTitle(STORY_TITLE);
            System.assertEquals('Failed', afterNoGit.Verification_Status__c);
            System.assertEquals(StoryVerificationService.NO_GIT_RESULT_DETAILS, afterNoGit.Verification_Details__c);
            System.assertEquals(null, afterNoGit.Verification_Checks__c);

            // Issues: one issue finding
            markRunning(story.Id, 'run-fb2');
            StoryVerificationService.JobOutcome issues = outcome(story.Id, 'run-fb2', 'Successful', 'not json');
            issues.dataJson = JSON.serialize(new Map<String, Object>{
                'runId' => 'run-fb2',
                'findings' => new List<Object>{
                    new Map<String, Object>{ 'severity' => 'issue', 'message' => 'No registered commits.' }
                }
            });
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ issues });
            copado__User_Story__c afterIssues = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', afterIssues.Verification_Status__c);
            System.assert(afterIssues.Verification_Details__c.contains('ISSUE: No registered commits.'), afterIssues.Verification_Details__c);
            System.assert(
                afterIssues.Verification_Details__c.endsWith('Git checks did not report a result - see the Job Execution logs.'),
                afterIssues.Verification_Details__c
            );
            System.assertEquals(null, afterIssues.Verification_Checks__c);
        }
    }

    @IsTest
    static void completeStoresTheChecksWithTheResult() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-ck1');
            String result =
                '{"runId":"run-ck1","status":"Issues","details":"ISSUE: x",' +
                '"checks":[{"id":"unregistered-commits","title":"Unregistered commits","status":"fail","summary":"s","lines":["l1"]}],' +
                '"salesforceFindings":[{"severity":"info","message":"m"}]}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-ck1', 'Successful', result) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', after.Verification_Status__c);
            System.assertEquals('ISSUE: x', after.Verification_Details__c);
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(after.Verification_Checks__c);
            List<Object> checks = (List<Object>) stored.get('checks');
            System.assertEquals(1, checks.size());
            System.assertEquals('fail', ((Map<String, Object>) checks[0]).get('status'));
            System.assertEquals(1, ((List<Object>) stored.get('salesforceFindings')).size());
        }
    }

    @IsTest
    static void completeStoresNoChecksWhenTheResultHasNone() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-ck2');
            update new copado__User_Story__c(Id = story.Id, Verification_Checks__c = '{"checks":[1]}');
            String result = '{"runId":"run-ck2","status":"Clean","details":"INFO: x","checks":[]}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-ck2', 'Successful', result) }
            );

            System.assertEquals(null, storyByTitle(STORY_TITLE).Verification_Checks__c);
        }
    }

    @IsTest
    static void completeAcceptsAFailedResultFromTheFunction() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-ck3');
            String result =
                '{"runId":"run-ck3","status":"Failed","details":"NOTE: Could not clone the repository",' +
                '"checks":[{"id":"metadata-coverage","title":"Metadata coverage","status":"skipped","summary":"Not run","lines":[]}]}';

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-ck3', 'Successful', result) }
            );

            copado__User_Story__c after = storyByTitle(STORY_TITLE);
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assertEquals('NOTE: Could not clone the repository', after.Verification_Details__c);
            System.assertNotEquals(null, after.Verification_Checks__c);
        }
    }

    @IsTest
    static void completeClearsStoredChecksWhenTheJobFails() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-ck4');
            update new copado__User_Story__c(Id = story.Id, Verification_Checks__c = '{"checks":[{"id":"x"}]}');
            StoryVerificationService.JobOutcome failed = outcome(story.Id, 'run-ck4', 'Failed', null);
            failed.errorMessage = 'kaboom';

            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ failed });

            System.assertEquals(null, storyByTitle(STORY_TITLE).Verification_Checks__c);
        }
    }

    @IsTest
    static void completeKeepsChecksOnlyWhenTheyFitTheField() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);

            // Checks fit alone but not together with the Salesforce findings: the findings are dropped.
            markRunning(story.Id, 'run-ck5');
            String result = JSON.serialize(
                new Map<String, Object>{
                    'runId' => 'run-ck5',
                    'status' => 'Issues',
                    'details' => 'x',
                    'checks' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'a', 'status' => 'fail', 'lines' => new List<Object>{ 'y'.repeat(99900) } }
                    },
                    'salesforceFindings' => new List<Object>{
                        new Map<String, Object>{ 'severity' => 'info', 'message' => 'z'.repeat(500) }
                    }
                }
            );
            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-ck5', 'Successful', result) }
            );
            copado__User_Story__c shortened = storyByTitle(STORY_TITLE);
            System.assertNotEquals(null, shortened.Verification_Checks__c);
            System.assert(shortened.Verification_Checks__c.length() <= 100000);
            Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(shortened.Verification_Checks__c);
            System.assertEquals(false, stored.containsKey('salesforceFindings'));

            // Checks that cannot fit at all are not stored; the status and details still are.
            markRunning(story.Id, 'run-ck6');
            result = JSON.serialize(
                new Map<String, Object>{
                    'runId' => 'run-ck6',
                    'status' => 'Issues',
                    'details' => 'x',
                    'checks' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'a', 'status' => 'fail', 'lines' => new List<Object>{ 'y'.repeat(100500) } }
                    }
                }
            );
            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-ck6', 'Successful', result) }
            );
            copado__User_Story__c dropped = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', dropped.Verification_Status__c);
            System.assertEquals(null, dropped.Verification_Checks__c);
        }
    }

    @IsTest
    static void commitWordingIsShort() {
        System.assertEquals('Registered commits: 1, metadata items: 2.', StoryVerificationService.commitSummary(1, 2));
        System.assertEquals('Registered commits: 0, metadata items: 0.', StoryVerificationService.commitSummary(0, 0));
        System.assertEquals('No registered commits.', StoryVerificationService.noCommitsMessage());
    }

    @IsTest
    static void completeIsIdempotent() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-7');
            String result = '{"runId":"run-7","status":"Issues","details":"ISSUE: x"}';
            List<StoryVerificationService.JobOutcome> outcomes = new List<StoryVerificationService.JobOutcome>{
                outcome(story.Id, 'run-7', 'Successful', result)
            };

            StoryVerificationService.applyOutcomes(outcomes);
            copado__User_Story__c first = storyByTitle(STORY_TITLE);
            StoryVerificationService.applyOutcomes(outcomes);
            copado__User_Story__c second = storyByTitle(STORY_TITLE);

            System.assertEquals(first.Verification_Status__c, second.Verification_Status__c);
            System.assertEquals(first.Verification_Details__c, second.Verification_Details__c);
            System.assertEquals('Issues', second.Verification_Status__c);
        }
    }

    @IsTest
    static void completeTruncatesOversizedDetails() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            markRunning(story.Id, 'run-8');
            String result = JSON.serialize(
                new Map<String, Object>{
                    'runId' => 'run-8',
                    'status' => 'Issues',
                    'details' => 'x'.repeat(33000)
                }
            );

            StoryVerificationService.applyOutcomes(
                new List<StoryVerificationService.JobOutcome>{ outcome(story.Id, 'run-8', 'Successful', result) }
            );

            System.assertEquals(32000, storyByTitle(STORY_TITLE).Verification_Details__c.length());
        }
    }

    @IsTest
    static void completeHandlesEmptyInput() {
        User admin = newAdmin();
        System.runAs(admin) {
            StoryVerificationService.completeVerifications(null);
            StoryVerificationService.completeVerifications(new List<Id>());
            StoryVerificationService.completeVerification(null);
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>());
            System.assertEquals(0, StoryVerificationService.saveErrors.size());
        }
    }

    @IsTest
    static void completeIsBulkSafeFor200Stories() {
        User admin = newAdmin();
        System.runAs(admin) {
            List<copado__User_Story__c> stories = new List<copado__User_Story__c>();
            for (Integer i = 0; i < 200; i++) {
                stories.add(
                    withJira(
                        new copado__User_Story__c(
                            copado__User_Story_Title__c = 'SV bulk ' + i,
                            copado__Pending_Tests__c = 0,
                            copado__Pull_Requests_Approved__c = true,
                            Verification_Status__c = 'Running',
                            Verification_Run_Id__c = 'bulk-run-' + i,
                            Verification_Date__c = System.now()
                        )
                    )
                );
            }
            insert stories;

            List<StoryVerificationService.JobOutcome> outcomes = new List<StoryVerificationService.JobOutcome>();
            for (Integer i = 0; i < 200; i++) {
                String runId = 'bulk-run-' + i;
                if (Math.mod(i, 3) == 0) {
                    outcomes.add(
                        outcome(
                            stories[i].Id,
                            runId,
                            'Successful',
                            '{"runId":"' + runId + '","status":"Clean","details":"ok"}'
                        )
                    );
                } else if (Math.mod(i, 3) == 1) {
                    outcomes.add(
                        outcome(
                            stories[i].Id,
                            runId,
                            'Successful',
                            '{"runId":"' + runId + '","status":"Issues","details":"bad"}'
                        )
                    );
                } else {
                    outcomes.add(outcome(stories[i].Id, runId, 'Failed', null));
                }
            }

            Integer queriesBefore = Limits.getQueries();
            Integer dmlBefore = Limits.getDmlStatements();
            StoryVerificationService.applyOutcomes(outcomes);
            // Generous ceilings: Copado triggers/flows on the story update count too, but a per-record
            // implementation would need 200+ of each.
            System.assert(Limits.getQueries() - queriesBefore < 100, 'Completion must not query per record');
            System.assert(Limits.getDmlStatements() - dmlBefore < 100, 'Completion must not run DML per record');

            Map<String, Integer> counts = new Map<String, Integer>();
            for (copado__User_Story__c s : [
                SELECT Verification_Status__c
                FROM copado__User_Story__c
                WHERE copado__User_Story_Title__c LIKE 'SV bulk %'
            ]) {
                Integer current = counts.containsKey(s.Verification_Status__c) ? counts.get(s.Verification_Status__c) : 0;
                counts.put(s.Verification_Status__c, current + 1);
            }
            System.assertEquals(67, counts.get('Clean'));
            System.assertEquals(67, counts.get('Issues'));
            System.assertEquals(66, counts.get('Failed'));
        }
    }
}
