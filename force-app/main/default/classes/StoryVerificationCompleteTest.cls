/**
 * These tests insert real Copado job records (copado__JobTemplate__c / JobExecution__c / JobStep__c /
 * Result__c) with standard constructors. Their required fields were not confirmed by describe; if DML
 * fails here a managed-package required field or trigger is the likely cause.
 */
@IsTest
private class StoryVerificationCompleteTest {
    @TestSetup
    static void setup() {
        insert new copado__User_Story__c(copado__User_Story_Title__c = 'SVC Story');
    }

    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svcomp',
            Email = 'svcomp@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVComplete',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svcomp.' + suffix + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    private static copado__User_Story__c story() {
        return [
            SELECT Id, Verification_Status__c, Verification_Details__c
            FROM copado__User_Story__c
            WHERE copado__User_Story_Title__c = 'SVC Story'
        ];
    }

    private static void markRunning(Id storyId, String runId) {
        update new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = 'Running',
            Verification_Run_Id__c = runId,
            Verification_Date__c = System.now()
        );
    }

    private static copado__JobTemplate__c template(String name) {
        copado__JobTemplate__c t = new copado__JobTemplate__c(
            Name = name,
            copado__ApiName__c = 'SVC_Test_' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 10)
        );
        insert t;
        return t;
    }

    private static copado__JobExecution__c jobExecution(Id templateId, Id storyId, String status, String runId) {
        copado__JobExecution__c je = new copado__JobExecution__c(
            copado__Template__c = templateId,
            copado__ParentRecord_Id__c = String.valueOf(storyId),
            copado__Status__c = status,
            copado__DataJson__c = JSON.serialize(new Map<String, Object>{ 'runId' => runId })
        );
        insert je;
        return je;
    }

    private static StoryVerificationComplete.Request request(Id jobExecutionId) {
        StoryVerificationComplete.Request req = new StoryVerificationComplete.Request();
        req.jobExecutionId = jobExecutionId;
        return req;
    }

    @IsTest
    static void failedJobExecutionMarksStoryFailed() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-1');
            copado__JobExecution__c je = jobExecution(template('Story_Verification').Id, s.Id, 'Failed', 'je-run-1');
            je.copado__ErrorMessage__c = 'kaboom';
            update je;

            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>{ request(je.Id) });

            copado__User_Story__c after = story();
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assert(after.Verification_Details__c.contains('kaboom'), after.Verification_Details__c);
        }
    }

    @IsTest
    static void successfulJobReadsResultFromJobStep() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-2');
            copado__JobExecution__c je = jobExecution(template('Story_Verification').Id, s.Id, 'Successful', 'je-run-2');
            insert new copado__JobStep__c(
                Name = 'Story_Verification',
                copado__JobExecution__c = je.Id,
                copado__Type__c = 'Function',
                copado__ResultDataJson__c = '{"runId":"je-run-2","status":"Issues","details":"ISSUE: from step"}'
            );

            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>{ request(je.Id) });

            copado__User_Story__c after = story();
            System.assertEquals('Issues', after.Verification_Status__c);
            System.assertEquals('ISSUE: from step', after.Verification_Details__c);
        }
    }

    @IsTest
    static void successfulJobFallsBackToResultRecord() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-3');
            copado__JobExecution__c je = jobExecution(template('Story_Verification').Id, s.Id, 'Successful', 'je-run-3');
            copado__JobStep__c step = new copado__JobStep__c(
                Name = 'Story_Verification',
                copado__JobExecution__c = je.Id,
                copado__Type__c = 'Function'
            );
            insert step;
            insert new copado__Result__c(
                copado__JobStep__c = step.Id,
                copado__Job_Type__c = 'Integration',
                copado__Result_Data__c = '{"runId":"je-run-3","status":"Clean","details":"INFO: from result"}'
            );

            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>{ request(je.Id) });

            copado__User_Story__c after = story();
            System.assertEquals('Clean', after.Verification_Status__c);
            System.assertEquals('INFO: from result', after.Verification_Details__c);
        }
    }

    @IsTest
    static void successfulJobWithoutResultMarksStoryFailed() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-4');
            copado__JobExecution__c je = jobExecution(template('Story_Verification').Id, s.Id, 'Successful', 'je-run-4');

            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>{ request(je.Id) });

            copado__User_Story__c after = story();
            System.assertEquals('Failed', after.Verification_Status__c);
            System.assertEquals('Result could not be read', after.Verification_Details__c);
        }
    }

    @IsTest
    static void otherTemplateIsIgnored() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-5');
            copado__JobExecution__c je = jobExecution(template('Some_Other_Template').Id, s.Id, 'Failed', 'je-run-5');

            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>{ request(je.Id) });

            System.assertEquals('Running', story().Verification_Status__c);
        }
    }

    @IsTest
    static void emptyAndNullRequestsAreNoOps() {
        User admin = newAdmin();
        System.runAs(admin) {
            copado__User_Story__c s = story();
            markRunning(s.Id, 'je-run-6');

            StoryVerificationComplete.complete(null);
            StoryVerificationComplete.complete(new List<StoryVerificationComplete.Request>());

            System.assertEquals('Running', story().Verification_Status__c);
        }
    }
}
