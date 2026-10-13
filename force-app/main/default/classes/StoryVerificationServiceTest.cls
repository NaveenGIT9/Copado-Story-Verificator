@IsTest
private class StoryVerificationServiceTest {
    private static final String STORY_TITLE = 'SV Test Story';
    private static final String PARENT_TITLE = 'SV Test Parent Story';

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

    @TestSetup
    static void setup() {
        insert new List<copado__User_Story__c>{
            new copado__User_Story__c(copado__User_Story_Title__c = STORY_TITLE),
            new copado__User_Story__c(copado__User_Story_Title__c = PARENT_TITLE)
        };
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
                Verification_Status__c,
                Verification_Details__c,
                Verification_Date__c,
                Verification_Run_Id__c
            FROM copado__User_Story__c
            WHERE copado__User_Story_Title__c = :title
            LIMIT 1
        ];
    }

    private static void addCommitAndMetadata(Id storyId) {
        // A commit needs a snapshot commit, which needs a credential (copado__Org__c)
        copado__Org__c credential = new copado__Org__c(Name = 'SV credential');
        insert credential;
        copado__Git_Org_Commit__c snapshot = new copado__Git_Org_Commit__c(copado__Org__c = credential.Id, copado__Status__c = 'Complete');
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
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c story = storyByTitle(STORY_TITLE);
            addCommitAndMetadata(story.Id);
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

            System.assertEquals(1, stub.requests.size());
            copado.CreateExecution.Request req = stub.requests[0];
            System.assertEquals('Story_Verification_1', req.templateName);
            System.assertEquals(String.valueOf(story.Id), String.valueOf(req.parentId));
            System.assertEquals(true, req.runAfterInstantiation);

            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(req.dataJson);
            System.assertEquals(String.valueOf(story.Id), String.valueOf(data.get('storyId')));
            System.assertEquals(story.Name, String.valueOf(data.get('storyName')));
            System.assertEquals(after.Verification_Run_Id__c, String.valueOf(data.get('runId')));
            List<String> lines = findingLines(req);
            System.assertEquals(1, lines.size());
            System.assertEquals('info|Registered commits: 1, selected metadata items: 1.', lines[0]);
        }
    }

    @IsTest
    static void startReportsMissingCommitsAndMetadata() {
        User admin = newAdmin();
        System.runAs(admin) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationService.startVerification(storyByTitle(STORY_TITLE).Id);

            List<String> lines = findingLines(stub.requests[0]);
            System.assertEquals(3, lines.size());
            System.assertEquals('issue|No commits are registered in Copado for this story.', lines[0]);
            System.assertEquals('issue|No metadata is selected on this story.', lines[1]);
            System.assertEquals('info|Registered commits: 0, selected metadata items: 0.', lines[2]);
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
            System.assert(
                lines.contains(
                    'issue|Base branch is the feature branch of ' + parent.Name + ', which has not been promoted yet.'
                ),
                'Unpromoted parent must be an issue: ' + lines
            );
        }
    }

    @IsTest
    static void startAcceptsCompletedParent() {
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
            System.assertEquals(1, lines.size(), 'Only the info line expected: ' + lines);
            System.assert(lines[0].startsWith('info|Registered commits'));
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
            System.assertEquals(2, lines.size());
            System.assert(lines[0].startsWith('info|Base branch feature/US-NOPE-1'), lines[0]);
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

            System.assertEquals(1, findingLines(stub.requests[0]).size());
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

            copado__User_Story__c doomed = new copado__User_Story__c(copado__User_Story_Title__c = 'SV doomed');
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

            // Clean: only info findings
            markRunning(story.Id, 'run-fb1');
            StoryVerificationService.JobOutcome clean = outcome(story.Id, 'run-fb1', 'Successful', null);
            clean.dataJson = JSON.serialize(new Map<String, Object>{
                'runId' => 'run-fb1',
                'findings' => new List<Object>{
                    new Map<String, Object>{ 'severity' => 'info', 'message' => 'Registered commits: 1' }
                }
            });
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ clean });
            copado__User_Story__c afterClean = storyByTitle(STORY_TITLE);
            System.assertEquals('Clean', afterClean.Verification_Status__c);
            System.assert(afterClean.Verification_Details__c.contains('INFO: Registered commits: 1'), afterClean.Verification_Details__c);
            System.assert(afterClean.Verification_Details__c.contains('NOT RUN: git checks'), afterClean.Verification_Details__c);

            // Issues: one issue finding
            markRunning(story.Id, 'run-fb2');
            StoryVerificationService.JobOutcome issues = outcome(story.Id, 'run-fb2', 'Successful', 'not json');
            issues.dataJson = JSON.serialize(new Map<String, Object>{
                'runId' => 'run-fb2',
                'findings' => new List<Object>{
                    new Map<String, Object>{ 'severity' => 'issue', 'message' => 'No commits are registered in Copado for this story.' }
                }
            });
            StoryVerificationService.applyOutcomes(new List<StoryVerificationService.JobOutcome>{ issues });
            copado__User_Story__c afterIssues = storyByTitle(STORY_TITLE);
            System.assertEquals('Issues', afterIssues.Verification_Status__c);
            System.assert(afterIssues.Verification_Details__c.contains('ISSUE: No commits are registered'), afterIssues.Verification_Details__c);
        }
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
                    new copado__User_Story__c(
                        copado__User_Story_Title__c = 'SV bulk ' + i,
                        Verification_Status__c = 'Running',
                        Verification_Run_Id__c = 'bulk-run-' + i,
                        Verification_Date__c = System.now()
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
