@IsTest
private class StoryVerificationSetupTest {
    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svsetup',
            Email = 'svsetup@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVSetup',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svsetup.' + suffix + '@example.com.invalid'
        );
        insert u;
        return u;
    }

    @IsTest
    static void runCreatesTheFunctionTemplateAndStepAndCanBeRepeated() {
        User admin = newAdmin();
        System.runAs(admin) {
            StoryVerificationSetup.run();
            StoryVerificationSetup.run();

            List<copado__Function__c> functions = [
                SELECT copado__Script__c, copado__Parameters__c, copado__Type__c
                FROM copado__Function__c
                WHERE copado__API_Name__c = 'Story_Verification'
            ];
            System.assertEquals(1, functions.size(), 'Running twice must not create a second Function');
            System.assertEquals('Custom', functions[0].copado__Type__c);
            System.assert(functions[0].copado__Script__c.startsWith('#!/usr/bin/env node'), 'The script must start with the node shebang');
            System.assertEquals(StoryVerificationSetup.functionScript(), functions[0].copado__Script__c);
            for (String parameter : new List<String>{ 'git_json', 'repositoryId', 'findings' }) {
                System.assert(functions[0].copado__Parameters__c.contains('"' + parameter + '"'), parameter + ' must be a Function parameter');
            }

            List<copado__JobTemplate__c> templates = [
                SELECT Id
                FROM copado__JobTemplate__c
                WHERE copado__ApiName__c = 'Story_Verification_1' AND Name = 'Story_Verification'
            ];
            System.assertEquals(1, templates.size());

            List<copado__JobStep__c> steps = [
                SELECT copado__ConfigJson__c
                FROM copado__JobStep__c
                WHERE copado__JobTemplate__c = :templates[0].Id
            ];
            System.assertEquals(1, steps.size());
            System.assert(steps[0].copado__ConfigJson__c.contains('"functionName":"Story_Verification"'));
        }
    }
}
