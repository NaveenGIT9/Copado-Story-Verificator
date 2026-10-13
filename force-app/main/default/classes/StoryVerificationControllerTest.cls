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

    @TestSetup
    static void setup() {
        insert new copado__User_Story__c(copado__User_Story_Title__c = STORY_TITLE);
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
                    new Map<String, Object>{ 'severity' => 'issue', 'message' => 'No commits are registered.' },
                    new Map<String, Object>{ 'severity' => 'info', 'message' => 'Registered commits: 0.' }
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
            System.assertEquals('No commits are registered.', snapshot.findings[0].message);
            System.assertEquals('info', snapshot.findings[1].severity);
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
