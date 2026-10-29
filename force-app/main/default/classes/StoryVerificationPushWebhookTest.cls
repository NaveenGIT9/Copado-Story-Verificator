@IsTest
private class StoryVerificationPushWebhookTest {
    private static final String SECRET = 'test-webhook-secret';
    private static final String STORY_TITLE = 'Push webhook story';
    private static final String SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    private static final String SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

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

    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svpush',
            Email = 'svpush@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVPush',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svpush.' + suffix + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    private static copado__User_Story__c story() {
        return [
            SELECT Id, Name, Branch_Head_SHA__c, Branch_Head_Pushed_At__c
            FROM copado__User_Story__c
            WHERE copado__User_Story_Title__c = :STORY_TITLE
            LIMIT 1
        ];
    }

    private static String pushBody(String ref, String after, Long pushedAtSeconds) {
        return JSON.serialize(
            new Map<String, Object>{
                'ref' => ref,
                'before' => SHA_A,
                'after' => after,
                'repository' => new Map<String, Object>{ 'name' => 'repo', 'pushed_at' => pushedAtSeconds }
            }
        );
    }

    private static String sign(String body, String key) {
        return 'sha256=' + EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(key)));
    }

    private static RestResponse call(String eventName, String body, String signature) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/storyverification/push';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.addHeader('X-GitHub-Event', eventName);
        if (signature != null) {
            req.addHeader('X-Hub-Signature-256', signature);
        }
        RestContext.request = req;
        RestContext.response = new RestResponse();
        StoryVerificationPushWebhook.receive();
        return RestContext.response;
    }

    private static Long nowSeconds() {
        return System.now().getTime() / 1000;
    }

    @IsTest
    static void signedPushToTheStoryBranchRecordsTheBranchHead() {
        StoryVerificationPushWebhook.secretOverride = SECRET;
        System.runAs(newAdmin()) {
            copado__User_Story__c s = story();
            Long pushedAt = nowSeconds();
            String body = pushBody('refs/heads/feature/' + s.Name, SHA_B.toUpperCase(), pushedAt);

            Test.startTest();
            RestResponse res = call('push', body, sign(body, SECRET));
            Test.stopTest();

            System.assertEquals(200, res.statusCode, res.responseBody.toString());
            copado__User_Story__c after = story();
            System.assertEquals(SHA_B, after.Branch_Head_SHA__c);
            System.assertEquals(pushedAt * 1000, after.Branch_Head_Pushed_At__c.getTime());
        }
    }

    @IsTest
    static void wrongSignatureIsRejected() {
        StoryVerificationPushWebhook.secretOverride = SECRET;
        System.runAs(newAdmin()) {
            copado__User_Story__c s = story();
            String body = pushBody('refs/heads/feature/' + s.Name, SHA_B, nowSeconds());

            Test.startTest();
            RestResponse wrongKey = call('push', body, sign(body, 'another-secret'));
            RestResponse missing = call('push', body, null);
            Test.stopTest();

            System.assertEquals(401, wrongKey.statusCode);
            System.assertEquals(401, missing.statusCode);
            System.assertEquals(null, story().Branch_Head_SHA__c);
        }
    }

    @IsTest
    static void missingSecretIsReportedAsNotConfigured() {
        StoryVerificationPushWebhook.secretOverride = '';
        System.runAs(newAdmin()) {
            String body = pushBody('refs/heads/feature/' + story().Name, SHA_B, nowSeconds());
            RestResponse res = call('push', body, sign(body, SECRET));
            System.assertEquals(500, res.statusCode);
        }
    }

    @IsTest
    static void pingAndOtherEventsAreAcknowledged() {
        StoryVerificationPushWebhook.secretOverride = SECRET;
        System.runAs(newAdmin()) {
            String body = '{"zen":"Keep it logically awesome."}';
            RestResponse ping = call('ping', body, sign(body, SECRET));
            RestResponse other = call('issues', body, sign(body, SECRET));
            System.assertEquals(200, ping.statusCode);
            System.assert(ping.responseBody.toString().contains('pong'), ping.responseBody.toString());
            System.assertEquals(200, other.statusCode);
            System.assert(other.responseBody.toString().contains('Ignored'), other.responseBody.toString());
        }
    }

    @IsTest
    static void otherBranchesDeletionsAndBadBodiesAreIgnored() {
        StoryVerificationPushWebhook.secretOverride = SECRET;
        System.runAs(newAdmin()) {
            copado__User_Story__c s = story();
            String master = pushBody('refs/heads/master', SHA_B, nowSeconds());
            String deleted = pushBody('refs/heads/feature/' + s.Name, '0000000000000000000000000000000000000000', nowSeconds());
            String nested = pushBody('refs/heads/feature/' + s.Name + '/extra', SHA_B, nowSeconds());
            String notJson = 'not json';

            Test.startTest();
            RestResponse r1 = call('push', master, sign(master, SECRET));
            RestResponse r2 = call('push', deleted, sign(deleted, SECRET));
            RestResponse r3 = call('push', nested, sign(nested, SECRET));
            RestResponse r4 = call('push', notJson, sign(notJson, SECRET));
            Test.stopTest();

            System.assertEquals(200, r1.statusCode);
            System.assertEquals(200, r2.statusCode);
            System.assertEquals(200, r3.statusCode);
            System.assertEquals(400, r4.statusCode);
            System.assertEquals(null, story().Branch_Head_SHA__c);
        }
    }

    @IsTest
    static void handlerKeepsTheNewestPushOfABatch() {
        System.runAs(newAdmin()) {
            copado__User_Story__c s = story();
            Datetime base = System.now();
            StoryBranchPushHandler.apply(
                new List<Story_Branch_Push__e>{
                    new Story_Branch_Push__e(Story_Name__c = s.Name, Head_SHA__c = SHA_B, Pushed_At__c = base.addMinutes(1)),
                    new Story_Branch_Push__e(Story_Name__c = s.Name, Head_SHA__c = SHA_A, Pushed_At__c = base)
                }
            );
            System.assertEquals(SHA_B, story().Branch_Head_SHA__c);
        }
    }

    @IsTest
    static void handlerIgnoresADeliveryOlderThanTheStoredHead() {
        System.runAs(newAdmin()) {
            copado__User_Story__c s = story();
            Datetime stored = System.now();
            update new copado__User_Story__c(Id = s.Id, Branch_Head_SHA__c = SHA_B, Branch_Head_Pushed_At__c = stored);
            stored = story().Branch_Head_Pushed_At__c;

            StoryBranchPushHandler.apply(
                new List<Story_Branch_Push__e>{
                    new Story_Branch_Push__e(Story_Name__c = s.Name, Head_SHA__c = SHA_A, Pushed_At__c = stored.addMinutes(-1)),
                    new Story_Branch_Push__e(Story_Name__c = 'US-0', Head_SHA__c = SHA_A, Pushed_At__c = stored),
                    new Story_Branch_Push__e(Story_Name__c = s.Name, Head_SHA__c = null, Pushed_At__c = stored.addMinutes(1))
                }
            );

            copado__User_Story__c after = story();
            System.assertEquals(SHA_B, after.Branch_Head_SHA__c);
            System.assertEquals(stored, after.Branch_Head_Pushed_At__c);
        }
    }
}
