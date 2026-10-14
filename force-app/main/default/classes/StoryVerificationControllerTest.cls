/**
 * Like StoryVerificationCompleteTest, these tests insert real Copado job records with standard
 * constructors; their required fields were not confirmed by describe. If DML fails here, a managed
 * package required field or trigger is the likely cause.
 */
@IsTest
private class StoryVerificationControllerTest {
    private static final String STORY_TITLE = 'SVCtl Story';

    /** Stub for the managed copado.CreateExecution, which cannot be mocked. */
    private class CapturingStarter implements StoryVerificationService.JobStarter {
        public List<copado.CreateExecution.Request> requests = new List<copado.CreateExecution.Request>();
        public void start(copado.CreateExecution.Request req) {
            requests.add(req);
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
        insert withJira(
            new copado__User_Story__c(
                copado__User_Story_Title__c = STORY_TITLE,
                copado__Pending_Tests__c = 0,
                copado__Pull_Requests_Approved__c = true
            )
        );
    }

    private static User newUser(String profileName, Boolean withVerificationAccess) {
        Profile profile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svctl',
            Email = 'svctl@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVController',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svctl.' + suffix + '@example.com.invalid'
        );
        insert u;
        if (withVerificationAccess) {
            // Deployed fields carry no profile FLS, and the controller reads them in USER_MODE.
            PermissionSet access = [
                SELECT Id
                FROM PermissionSet
                WHERE Name = 'Copado_Story_Verification_User'
                LIMIT 1
            ];
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = access.Id);
        }
        return u;
    }

    private static copado__User_Story__c story() {
        return [
            SELECT Id, Verification_Status__c, Verification_Run_Id__c
            FROM copado__User_Story__c
            WHERE copado__User_Story_Title__c = :STORY_TITLE
        ];
    }

    private static void setState(Id storyId, String status, String runId, String details) {
        update new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = status,
            Verification_Run_Id__c = runId,
            Verification_Date__c = System.now(),
            Verification_Details__c = details
        );
    }

    private static copado__JobTemplate__c template(String name) {
        copado__JobTemplate__c t = new copado__JobTemplate__c(
            Name = name,
            copado__ApiName__c = 'SVCtl_Test_' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 10)
        );
        insert t;
        return t;
    }

    private static copado__JobExecution__c jobExecution(Id templateId, Id storyId, String status, String dataJson) {
        copado__JobExecution__c je = new copado__JobExecution__c(
            copado__Template__c = templateId,
            copado__ParentRecord_Id__c = String.valueOf(storyId),
            copado__Status__c = status,
            copado__DataJson__c = dataJson
        );
        insert je;
        return je;
    }

    private static String dataJson(String runId) {
        return JSON.serialize(
            new Map<String, Object>{
                'runId' => runId,
                'findings' => new List<Object>{
                    new Map<String, Object>{ 'severity' => 'issue', 'message' => 'No registered commits.' },
                    new Map<String, Object>{
                        'severity' => 'info',
                        'message' => 'None.',
                        'group' => 'parent-dependencies'
                    }
                }
            }
        );
    }

    @IsTest
    static void startReturnsRunningSnapshot() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;
            Id storyId = story().Id;

            Test.startTest();
            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.start(storyId);
            Test.stopTest();

            System.assertEquals(null, snapshot.errorMessage);
            System.assertEquals('Running', snapshot.status);
            System.assertEquals(32, snapshot.runId.length());
            System.assertEquals(story().Verification_Run_Id__c, snapshot.runId);
            System.assertEquals(false, snapshot.isFinished);
            System.assertEquals(true, snapshot.isCurrentRun);
            System.assertEquals('Queued', snapshot.jobStatus);
            System.assertEquals(1, stub.requests.size());
        }
    }

    @IsTest
    static void startReturnsErrorMessageWhenAlreadyRunning() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;
            Id storyId = story().Id;
            StoryVerificationController.start(storyId);

            StoryVerificationController.ProgressSnapshot second = StoryVerificationController.start(storyId);

            System.assertEquals('Verification is already running', second.errorMessage);
            System.assertEquals(1, stub.requests.size(), 'No second job may be started');
        }
    }

    @IsTest
    static void getProgressWithoutJobExecutionIsQueued() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-a', null);

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'run-a'
            );

            System.assertEquals('Running', snapshot.status);
            System.assertEquals(false, snapshot.isFinished);
            System.assertEquals(true, snapshot.isCurrentRun);
            System.assertEquals('Queued', snapshot.jobStatus);
            System.assertEquals(0, snapshot.findings.size());
            System.assertEquals(0, snapshot.details.size());
            System.assertEquals(null, snapshot.progressText);
        }
    }

    @IsTest
    static void getProgressParsesFindingsAndMapsJobStatus() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-b', null);
            // An execution of the same template for an older run must be skipped.
            copado__JobTemplate__c verificationTemplate = template('Story_Verification'); // one template: names must be unique
            jobExecution(verificationTemplate.Id, storyId, 'Successful', dataJson('old-run'));
            copado__JobExecution__c je = jobExecution(
                verificationTemplate.Id,
                storyId,
                'Error',
                dataJson('run-b')
            );
            // The status does not change here, so the completion flow (status-change trigger) does not fire.
            je.copado__ErrorMessage__c = 'job exploded';
            update je;

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'run-b'
            );

            System.assertEquals(2, snapshot.findings.size());
            System.assertEquals('issue', snapshot.findings[0].severity);
            System.assertEquals('No registered commits.', snapshot.findings[0].message);
            System.assertEquals('info', snapshot.findings[1].severity);
            System.assertEquals(null, snapshot.findings[0].groupKey, 'A finding without a group has no groupKey');
            System.assertEquals('parent-dependencies', snapshot.findings[1].groupKey);
            System.assertEquals('Error', snapshot.jobStatus);
            System.assertEquals('job exploded', snapshot.jobError);
        }
    }

    @IsTest
    static void getProgressIgnoresOtherTemplates() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-c', null);
            jobExecution(template('Some_Other_Template').Id, storyId, 'Successful', dataJson('run-c'));

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'run-c'
            );

            System.assertEquals('Queued', snapshot.jobStatus);
            System.assertEquals(0, snapshot.findings.size());
        }
    }

    @IsTest
    static void getProgressReturnsLatestProgressText() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-d', null);
            copado__JobExecution__c je = jobExecution(
                template('Story_Verification').Id,
                storyId,
                'Successful',
                dataJson('run-d')
            );
            copado__JobStep__c step = new copado__JobStep__c(
                Name = 'Story_Verification',
                copado__JobExecution__c = je.Id,
                copado__Type__c = 'Function'
            );
            insert step;
            insert new copado__Result__c(
                copado__JobStep__c = step.Id,
                copado__Job_Type__c = 'Integration',
                copado__Progress_Status__c = 'Aggregating findings'
            );

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'run-d'
            );

            System.assertEquals('Aggregating findings', snapshot.progressText);
            System.assertEquals('Successful', snapshot.jobStatus);
        }
    }

    @IsTest
    static void getProgressFinishedStatesSplitDetails() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            for (String status : new List<String>{ 'Clean', 'Issues', 'Failed' }) {
                setState(storyId, status, 'run-e', 'ISSUE: first\r\nINFO: second\nthird');

                StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                    storyId,
                    'run-e'
                );

                System.assertEquals(status, snapshot.status);
                System.assertEquals(true, snapshot.isFinished, status);
                System.assertEquals(3, snapshot.details.size(), status);
                System.assertEquals('ISSUE: first', snapshot.details[0]);
                System.assertEquals('third', snapshot.details[2]);
            }
        }
    }

    @IsTest
    static void parseFindingsKeepsWarningsAndGroups() {
        List<StoryVerificationController.Finding> findings = StoryVerificationController.parseFindings(
            new List<Object>{
                new Map<String, Object>{ 'severity' => 'warn', 'message' => 'No commits', 'group' => 'pull-request', 'noCommits' => 'true' },
                new Map<String, Object>{ 'severity' => 'issue', 'message' => 'x' },
                new Map<String, Object>{ 'severity' => 'weird', 'message' => 'y' }
            }
        );
        System.assertEquals('warn', findings[0].severity);
        System.assertEquals('pull-request', findings[0].groupKey);
        System.assertEquals('issue', findings[1].severity);
        System.assertEquals('info', findings[2].severity, 'An unknown severity reads as info');
    }

    @IsTest
    static void aFinishedRunShowsTheFindingsTheFunctionFinishedWith() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Clean', 'run-w', 'WARN: No commits');
            update new copado__User_Story__c(
                Id = storyId,
                Verification_Checks__c = '{"checks":[{"id":"metadata-coverage","status":"pass","summary":"ok"}],' +
                    '"salesforceFindings":[{"severity":"warn","message":"No commits","group":"pull-request","noCommits":true}]}'
            );

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(storyId, 'run-w');

            System.assertEquals(1, snapshot.findings.size(), 'The stored findings replace the ones sent at the start');
            System.assertEquals('warn', snapshot.findings[0].severity);
            System.assertEquals('No commits', snapshot.findings[0].message);
            System.assertEquals('pull-request', snapshot.findings[0].groupKey);

            setState(storyId, 'Running', 'run-w2', null);
            System.assertEquals(0, StoryVerificationController.getProgress(storyId, 'run-w2').findings.size(), 'Only a finished run uses them');
        }
    }

    @IsTest
    static void getProgressParsesTheStoredChecks() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Issues', 'run-g', 'ISSUE: x');
            update new copado__User_Story__c(
                Id = storyId,
                Verification_Checks__c = '{"checks":[' +
                    '{"id":"unregistered-commits","title":"Unregistered commits","status":"fail","summary":"1 commit","lines":["a","b"]},' +
                    '{"id":"metadata-coverage","title":"Metadata coverage","status":"PASS","summary":"ok","lines":[]},' +
                    '{"id":"org-branch-merge","title":"Org/environment branch merge","status":"odd","summary":"?"}' +
                    '],"salesforceFindings":[]}'
            );

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'run-g'
            );

            System.assertEquals(3, snapshot.checks.size());
            System.assertEquals('unregistered-commits', snapshot.checks[0].id);
            System.assertEquals('Unregistered commits', snapshot.checks[0].title);
            System.assertEquals('fail', snapshot.checks[0].status);
            System.assertEquals('1 commit', snapshot.checks[0].summary);
            System.assertEquals(new List<String>{ 'a', 'b' }, snapshot.checks[0].lines);
            System.assertEquals('pass', snapshot.checks[1].status, 'Status is normalised to lower case');
            System.assertEquals(0, snapshot.checks[1].lines.size());
            System.assertEquals('skipped', snapshot.checks[2].status, 'An unknown status is shown as skipped');
            System.assertEquals(0, snapshot.checks[2].lines.size(), 'Missing lines are an empty list');
        }
    }

    @IsTest
    static void getProgressHasNoChecksWhileRunningOrWhenUnreadable() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-h', null);
            System.assertEquals(0, StoryVerificationController.getProgress(storyId, 'run-h').checks.size());

            update new copado__User_Story__c(Id = storyId, Verification_Checks__c = 'not json');
            System.assertEquals(0, StoryVerificationController.getProgress(storyId, 'run-h').checks.size());
        }
    }

    @IsTest
    static void commitBaseUrlPrefersCopadosAddressAndFallsBackToGitHub() {
        System.assertEquals(
            'https://github.com/o/r/commit/',
            StoryVerificationController.commitBaseFrom('https://github.com/o/r/commit/', 'https://gitlab.com/x/y.git')
        );
        System.assertEquals('https://host/o/r/commit/', StoryVerificationController.commitBaseFrom(' https://host/o/r/commit ', null));
        System.assertEquals(null, StoryVerificationController.commitBaseFrom('http://insecure/o/r/commit/', 'https://github.com/o/r.git'));
        System.assertEquals('https://github.com/o/r/commit/', StoryVerificationController.commitBaseFrom(null, 'https://github.com/o/r.git'));
        System.assertEquals('https://github.com/o/r/commit/', StoryVerificationController.commitBaseFrom('', 'https://github.com/o/r/'));
        System.assertEquals(null, StoryVerificationController.commitBaseFrom(null, 'https://gitlab.com/o/r.git'));
        System.assertEquals(null, StoryVerificationController.commitBaseFrom(null, null));
        System.assertEquals(null, StoryVerificationController.commitBaseFrom(' ', ' '));
    }

    @IsTest
    static void parseChecksPassesStructuredRowsThroughAsJson() {
        List<StoryVerificationController.CheckResult> checks = StoryVerificationController.parseChecks(
            '{"checks":[{"id":"metadata-coverage","status":"fail","lines":["a"],"rows":[{"t":"names","items":["Foo.cls"]}]},' +
            '{"id":"org-branch-merge","status":"pass","rows":[]},{"id":"unregistered-commits","status":"pass"}]}'
        );
        System.assertEquals(3, checks.size());
        System.assertNotEquals(null, checks[0].rowsJson);
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(checks[0].rowsJson);
        System.assertEquals(1, rows.size());
        System.assertEquals('names', ((Map<String, Object>) rows[0]).get('t'));
        System.assertEquals(null, checks[1].rowsJson);
        System.assertEquals(null, checks[2].rowsJson);
    }

    @IsTest
    static void parseChecksToleratesBadShapes() {
        System.assertEquals(0, StoryVerificationController.parseChecks(null).size());
        System.assertEquals(0, StoryVerificationController.parseChecks('[]').size());
        System.assertEquals(0, StoryVerificationController.parseChecks('{"checks":"x"}').size());
        List<StoryVerificationController.CheckResult> checks = StoryVerificationController.parseChecks(
            '{"checks":[1,{"id":"a","lines":[null,"kept",5]}]}'
        );
        System.assertEquals(1, checks.size());
        System.assertEquals('skipped', checks[0].status);
        System.assertEquals('', checks[0].title);
        System.assertEquals(new List<String>{ 'kept', '5' }, checks[0].lines);
    }

    @IsTest
    static void startSnapshotHasNoChecksBecauseTheyAreClearedAtStart() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            update new copado__User_Story__c(Id = storyId, Verification_Checks__c = '{"checks":[{"id":"a","status":"pass"}]}');
            StoryVerificationService.starter = new CapturingStarter();

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.start(storyId);

            System.assertEquals(0, snapshot.checks.size());
        }
    }

    @IsTest
    static void getProgressFlagsSupersededRun() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'newer-run', null);

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.getProgress(
                storyId,
                'older-run'
            );

            System.assertEquals(false, snapshot.isCurrentRun);
            System.assertEquals('newer-run', snapshot.runId);
        }
    }

    @IsTest
    static void parseScriptSecondsReadsTheStoredDurationAndIgnoresJunk() {
        System.assertEquals(18, StoryVerificationController.parseScriptSeconds('{"checks":[],"scriptSeconds":18}'));
        System.assertEquals(7, StoryVerificationController.parseScriptSeconds('{"scriptSeconds":"7"}'));
        System.assertEquals(null, StoryVerificationController.parseScriptSeconds('{"checks":[]}'));
        System.assertEquals(null, StoryVerificationController.parseScriptSeconds('{"scriptSeconds":"soon"}'));
        System.assertEquals(null, StoryVerificationController.parseScriptSeconds('not json'));
        System.assertEquals(null, StoryVerificationController.parseScriptSeconds(null));
    }

    @IsTest
    static void getProgressFactsAreLiveFromTheStory() {
        StoryVerificationService.pullRequestApprovedOverride = true; // Copado recomputes the real field, so the test sets the hook
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            Id storyId = story().Id;
            setState(storyId, 'Running', 'run-f', null);

            StoryVerificationController.ProgressSnapshot first = StoryVerificationController.getProgress(
                storyId,
                'run-f'
            );

            System.assertEquals(2, first.facts.size());
            System.assertEquals('Pending tests', first.facts[0].label);
            System.assertEquals('0', first.facts[0].value);
            System.assertEquals('ok', first.facts[0].state);
            System.assertEquals('Pull request approved', first.facts[1].label);
            System.assertEquals('Yes', first.facts[1].value);
            System.assertEquals('ok', first.facts[1].state);

            StoryVerificationService.pullRequestApprovedOverride = false;
            update new copado__User_Story__c(
                Id = storyId,
                copado__Pending_Tests__c = 4,
                copado__Pull_Requests_Approved__c = false
            );
            StoryVerificationController.ProgressSnapshot second = StoryVerificationController.getProgress(
                storyId,
                'run-f'
            );

            System.assertEquals('4', second.facts[0].value);
            System.assertEquals('issue', second.facts[0].state);
            System.assertEquals('No', second.facts[1].value);
            System.assertEquals('issue', second.facts[1].state);

            update new copado__User_Story__c(Id = storyId, copado__Pending_Tests__c = null);
            StoryVerificationController.ProgressSnapshot third = StoryVerificationController.getProgress(
                storyId,
                'run-f'
            );
            System.assertEquals('0', third.facts[0].value, 'Null pending tests is shown as 0');
            System.assertEquals('ok', third.facts[0].state);
        }
    }

    @IsTest
    static void startSnapshotCarriesFacts() {
        User user = newUser('System Administrator', true);
        System.runAs(user) {
            StoryVerificationService.starter = new CapturingStarter();

            StoryVerificationController.ProgressSnapshot snapshot = StoryVerificationController.start(story().Id);

            System.assertEquals(2, snapshot.facts.size());
        }
    }

    @IsTest
    static void unreadableStoryThrows() {
        Id storyId = story().Id;
        // Standard User has no object access to Copado objects (granted only through permission sets).
        User user = newUser('Standard User', false);
        System.runAs(user) {
            try {
                StoryVerificationController.getProgress(storyId, 'x');
                System.assert(false, 'getProgress must throw for a story the user cannot read');
            } catch (AuraHandledException e) {
                System.assertEquals('You do not have access to this story.', e.getMessage());
            }
            try {
                StoryVerificationController.start(storyId);
                System.assert(false, 'start must throw for a story the user cannot read');
            } catch (AuraHandledException e) {
                System.assertEquals('You do not have access to this story.', e.getMessage());
            }
        }
        System.assertEquals(null, story().Verification_Status__c, 'start must not touch an unreadable story');
    }
}
