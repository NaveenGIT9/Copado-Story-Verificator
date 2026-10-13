@IsTest
private class StoryVerificationStartTest {
    /** Stub for the managed copado.CreateExecution, which cannot be mocked. */
    private class CapturingStarter implements StoryVerificationService.JobStarter {
        public List<copado.CreateExecution.Request> requests = new List<copado.CreateExecution.Request>();
        public void start(copado.CreateExecution.Request req) {
            requests.add(req);
        }
    }

    @TestSetup
    static void setup() {
        insert new List<copado__User_Story__c>{
            new copado__User_Story__c(copado__User_Story_Title__c = 'SVS Story 1'),
            new copado__User_Story__c(copado__User_Story_Title__c = 'SVS Story 2')
        };
    }

    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svstart',
            Email = 'svstart@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVStart',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svstart.' + suffix + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    private static StoryVerificationStart.Request request(Id storyId) {
        StoryVerificationStart.Request req = new StoryVerificationStart.Request();
        req.storyId = storyId;
        return req;
    }

    @IsTest
    static void startsOneJobPerRequest() {
        User admin = newAdmin();
        System.runAs(admin) {
            List<copado__User_Story__c> stories = [
                SELECT Id
                FROM copado__User_Story__c
                WHERE copado__User_Story_Title__c LIKE 'SVS Story %'
            ];
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationStart.start(
                new List<StoryVerificationStart.Request>{ request(stories[0].Id), request(stories[1].Id) }
            );

            System.assertEquals(2, stub.requests.size(), 'Each request must start its own job');
            for (copado__User_Story__c s : [
                SELECT Verification_Status__c, Verification_Run_Id__c
                FROM copado__User_Story__c
                WHERE copado__User_Story_Title__c LIKE 'SVS Story %'
            ]) {
                System.assertEquals('Running', s.Verification_Status__c);
                System.assertNotEquals(null, s.Verification_Run_Id__c);
            }
        }
    }

    @IsTest
    static void propagatesDoubleRunError() {
        User admin = newAdmin();
        System.runAs(admin) {
            Id storyId = [SELECT Id FROM copado__User_Story__c WHERE copado__User_Story_Title__c = 'SVS Story 1'].Id;
            StoryVerificationService.starter = new CapturingStarter();
            StoryVerificationStart.start(new List<StoryVerificationStart.Request>{ request(storyId) });

            try {
                StoryVerificationStart.start(new List<StoryVerificationStart.Request>{ request(storyId) });
                System.assert(false, 'Second start must throw');
            } catch (StoryVerificationException e) {
                System.assertEquals('Verification is already running', e.getMessage());
            }
        }
    }

    @IsTest
    static void nullRequestListIsNoOp() {
        User admin = newAdmin();
        System.runAs(admin) {
            CapturingStarter stub = new CapturingStarter();
            StoryVerificationService.starter = stub;

            StoryVerificationStart.start(null);
            StoryVerificationStart.start(new List<StoryVerificationStart.Request>());

            System.assertEquals(0, stub.requests.size());
        }
    }
}
