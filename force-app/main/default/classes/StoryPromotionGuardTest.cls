@IsTest
private class StoryPromotionGuardTest {
    private static User newUser(Boolean releaseEngineer) {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svguard',
            Email = 'svguard@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = releaseEngineer ? 'SVGuardEngineer' : 'SVGuardDeveloper',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svguard.' + suffix + '@example.com.invalid'
        );
        // Separate runAs blocks keep the setup DML (user, assignment) apart from Copado's license records.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            if (releaseEngineer) {
                insert new PermissionSetAssignment(
                    AssigneeId = u.Id,
                    PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Copado_Story_Verification_Bypass' LIMIT 1].Id
                );
            }
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            grantCopadoLicense(u.Id);
        }
        return u;
    }

    // Copado refuses promotion DML from a user without a Copado license.
    private static void grantCopadoLicense(Id userId) {
        List<PackageLicense> packages = [SELECT Id FROM PackageLicense WHERE NamespacePrefix = 'copado' LIMIT 1];
        if (!packages.isEmpty()) {
            insert new UserPackageLicense(UserId = userId, PackageLicenseId = packages[0].Id);
        }
        copado.GlobalAPI.UserLicense license = new copado.GlobalAPI.UserLicense();
        license.userId = userId;
        license.isCopadoEnabled = true;
        license.isCCMenabled = true;
        new copado.GlobalAPI().upsertCopadoLicense(license);
    }

    // Some orgs make Jira_Key__c mandatory on the story; fill it when the field exists (set by name so this compiles everywhere).
    private static copado__User_Story__c newStory(String title) {
        copado__User_Story__c story = new copado__User_Story__c(copado__User_Story_Title__c = title);
        if (Schema.SObjectType.copado__User_Story__c.fields.getMap().containsKey('Jira_Key__c')) {
            story.put('Jira_Key__c', 'SV-1');
        }
        return story;
    }

    private class Fixture {
        copado__Promotion__c promotion;
        copado__User_Story__c clean;
        copado__User_Story__c issues;
        copado__User_Story__c bypassed;
    }

    // Built by a release engineer, who is the only one who may check Bypass Verification. The promotion has no environments:
    // Copado refuses one with a destination environment unless the user holds a credential for it, and the guard ignores them.
    private static Fixture build() {
        Fixture f = new Fixture();
        f.clean = newStory('SV guard clean');
        f.issues = newStory('SV guard issues');
        f.bypassed = newStory('SV guard bypassed');
        insert new List<copado__User_Story__c>{ f.clean, f.issues, f.bypassed };
        update new List<copado__User_Story__c>{
            new copado__User_Story__c(Id = f.clean.Id, Verification_Status__c = 'Clean'),
            new copado__User_Story__c(Id = f.issues.Id, Verification_Status__c = 'Issues'),
            new copado__User_Story__c(
                Id = f.bypassed.Id,
                Verification_Status__c = 'Issues',
                Bypass_Verification__c = true,
                Bypass_Reason__c = 'Hotfix'
            )
        };
        Map<Id, copado__User_Story__c> names = new Map<Id, copado__User_Story__c>(
            [SELECT Id, Name FROM copado__User_Story__c WHERE Id IN (:f.issues.Id, :f.bypassed.Id)]
        );
        f.issues = names.get(f.issues.Id);
        f.bypassed = names.get(f.bypassed.Id);
        f.promotion = new copado__Promotion__c(copado__Status__c = 'Draft');
        insert f.promotion;
        return f;
    }

    private static copado__Promoted_User_Story__c link(Fixture f, Id storyId) {
        return new copado__Promoted_User_Story__c(copado__Promotion__c = f.promotion.Id, copado__User_Story__c = storyId);
    }

    private static String errorsOf(Database.SaveResult result) {
        List<String> messages = new List<String>();
        for (Database.Error e : result.getErrors()) {
            messages.add(e.getMessage());
        }
        return String.join(messages, ' | ');
    }

    @IsTest
    static void aStoryWithIssuesIsRefusedEvenForAReleaseEngineer() {
        System.runAs(newUser(true)) {
            Fixture f = build();

            Database.SaveResult result = Database.insert(link(f, f.issues.Id), false);

            System.assertEquals(false, result.isSuccess(), 'Issues without a bypass is refused for everyone');
            System.assert(errorsOf(result).contains(f.issues.Name), errorsOf(result));
            System.assert(errorsOf(result).contains('click Verify'), errorsOf(result));
        }
    }

    @IsTest
    static void aCleanStoryIsAddedAndOnlyTheStoryWithIssuesIsRefused() {
        System.runAs(newUser(true)) {
            Fixture f = build();

            List<Database.SaveResult> results = Database.insert(
                new List<copado__Promoted_User_Story__c>{ link(f, f.clean.Id), link(f, f.issues.Id) },
                false
            );

            System.assertEquals(true, results[0].isSuccess(), 'The clean story is added: ' + errorsOf(results[0]));
            System.assertEquals(false, results[1].isSuccess(), 'The story with issues is refused');
        }
    }

    @IsTest
    static void aBypassedStoryCanBeAddedOnlyByAReleaseEngineer() {
        User releaseEngineer = newUser(true);
        User developer = newUser(false);
        Fixture f;
        System.runAs(releaseEngineer) {
            f = build();
        }

        System.runAs(developer) {
            Database.SaveResult result = Database.insert(link(f, f.bypassed.Id), false);
            System.assertEquals(false, result.isSuccess(), 'A developer cannot add a bypassed story');
            System.assert(errorsOf(result).contains('Only a release engineer can add it to a promotion'), errorsOf(result));
        }

        System.runAs(releaseEngineer) {
            Database.SaveResult result = Database.insert(link(f, f.bypassed.Id), false);
            System.assertEquals(true, result.isSuccess(), 'A release engineer adds the bypassed story: ' + errorsOf(result));
        }
    }

    @IsTest
    static void theOrgWideSwitchLetsTheStoryThrough() {
        System.runAs(newUser(true)) {
            insert new Story_Verification_Control__c(SetupOwnerId = UserInfo.getOrganizationId(), Disable_Story_Verification__c = true);
            Fixture f = build();

            Database.SaveResult result = Database.insert(link(f, f.issues.Id), false);

            System.assertEquals(true, result.isSuccess(), 'The gate is off org-wide: ' + errorsOf(result));
        }
    }

    @IsTest
    static void thePromotionBannerListsOnlyBypassedStories() {
        System.runAs(newUser(true)) {
            Fixture f = build();
            insert new List<copado__Promoted_User_Story__c>{ link(f, f.clean.Id), link(f, f.bypassed.Id) };

            List<StoryBypassController.BypassedStory> stories = StoryBypassController.getBypassedStories(f.promotion.Id);

            System.assertEquals(1, stories.size());
            System.assertEquals(f.bypassed.Name, stories[0].name);
            System.assertEquals('Hotfix', stories[0].reason);
            System.assertEquals(0, StoryBypassController.getBypassedStories(null).size());
        }
    }
}
