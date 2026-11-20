@IsTest
private class StoryBypassTest {
    private static final String REASON = 'Hotfix for production outage';

    private static User newUser(Boolean releaseEngineer) {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svbypass',
            Email = 'svbypass@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = releaseEngineer ? 'SVReleaseEngineer' : 'SVDeveloper',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svbypass.' + suffix + '@example.com.invalid'
        );
        insert u;
        if (releaseEngineer) {
            insert new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Copado_Story_Verification_Bypass' LIMIT 1].Id
            );
        }
        return u;
    }

    // Some orgs make Jira_Key__c mandatory on the story; fill it when the field exists (set by name so this compiles everywhere).
    private static copado__User_Story__c newStory() {
        copado__User_Story__c story = new copado__User_Story__c(copado__User_Story_Title__c = 'SV bypass');
        if (Schema.SObjectType.copado__User_Story__c.fields.getMap().containsKey('Jira_Key__c')) {
            story.put('Jira_Key__c', 'SV-1');
        }
        insert story;
        // No commits means no pull request is expected, so the PR rule stays out of the promote tests.
        update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Issues', Verification_No_Commits__c = true);
        return story;
    }

    private static void bypass(Id storyId) {
        update new copado__User_Story__c(Id = storyId, Bypass_Verification__c = true, Bypass_Reason__c = REASON);
    }

    private static copado__User_Story__c reload(Id storyId) {
        return [
            SELECT Bypass_Verification__c, Bypass_Reason__c, Bypassed_By__c, Bypassed_At__c
            FROM copado__User_Story__c
            WHERE Id = :storyId
        ];
    }

    private static String errorsOf(Database.SaveResult result) {
        List<String> messages = new List<String>();
        for (Database.Error e : result.getErrors()) {
            messages.add(e.getMessage());
        }
        return String.join(messages, ' | ');
    }

    @IsTest
    static void aReleaseEngineerBypassIsStampedWithWhoAndWhen() {
        User releaseEngineer = newUser(true);
        System.runAs(releaseEngineer) {
            copado__User_Story__c story = newStory();

            bypass(story.Id);

            copado__User_Story__c saved = reload(story.Id);
            System.assertEquals(true, saved.Bypass_Verification__c);
            System.assertEquals(releaseEngineer.Id, saved.Bypassed_By__c);
            System.assertNotEquals(null, saved.Bypassed_At__c);
        }
    }

    @IsTest
    static void aCleanVerificationClearsTheBypassAndKeepsTheReason() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = newStory();
            bypass(story.Id);

            update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Clean');

            copado__User_Story__c saved = reload(story.Id);
            System.assertEquals(false, saved.Bypass_Verification__c, 'Clean ends the bypass');
            System.assertEquals(REASON, saved.Bypass_Reason__c, 'The reason stays as a record of the last bypass');
        }
    }

    @IsTest
    static void runningAndFailedKeepTheBypass() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = newStory();
            bypass(story.Id);

            update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Running');
            System.assertEquals(true, reload(story.Id).Bypass_Verification__c, 'A new run keeps the bypass');

            update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Failed');
            System.assertEquals(true, reload(story.Id).Bypass_Verification__c, 'A failed run keeps the bypass');
        }
    }

    @IsTest
    static void aDeveloperCannotCheckBypassVerification() {
        System.runAs(newUser(false)) {
            copado__User_Story__c story = newStory();

            Database.SaveResult result = Database.update(
                new copado__User_Story__c(Id = story.Id, Bypass_Verification__c = true, Bypass_Reason__c = REASON),
                false
            );

            System.assertEquals(false, result.isSuccess());
            System.assert(errorsOf(result).contains('Only a release engineer can check Bypass Verification'), errorsOf(result));
        }
    }

    @IsTest
    static void bypassNeedsIssuesAndAReason() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = newStory();

            Database.SaveResult noReason = Database.update(new copado__User_Story__c(Id = story.Id, Bypass_Verification__c = true), false);
            System.assert(errorsOf(noReason).contains('Enter a Bypass Reason'), errorsOf(noReason));

            update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Clean');
            Database.SaveResult clean = Database.update(
                new copado__User_Story__c(Id = story.Id, Bypass_Verification__c = true, Bypass_Reason__c = REASON),
                false
            );
            System.assert(errorsOf(clean).contains('only needed when the last verification found issues'), errorsOf(clean));
        }
    }

    @IsTest
    static void onlyAReleaseEngineerCanCheckReadyToPromoteOnABypassedStory() {
        User releaseEngineer = newUser(true);
        User developer = newUser(false);
        copado__User_Story__c story;
        System.runAs(releaseEngineer) {
            story = newStory();
            bypass(story.Id);
        }

        System.runAs(developer) {
            Database.SaveResult result = Database.update(new copado__User_Story__c(Id = story.Id, copado__Promote_Change__c = true), false);
            System.assertEquals(false, result.isSuccess());
            System.assert(errorsOf(result).contains('Only a release engineer can check Ready to Promote'), errorsOf(result));
        }

        System.runAs(releaseEngineer) {
            // Copado or org rules outside this package may still refuse the save; none of the gate's messages may appear.
            String errors = errorsOf(Database.update(new copado__User_Story__c(Id = story.Id, copado__Promote_Change__c = true), false));
            System.assert(!errors.contains('Verification did not pass'), errors);
            System.assert(!errors.contains('Only a release engineer'), errors);
        }
    }

    @IsTest
    static void aStoryWithIssuesAndNoBypassStaysBlockedForAReleaseEngineer() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = newStory();

            Database.SaveResult result = Database.update(new copado__User_Story__c(Id = story.Id, copado__Promote_Change__c = true), false);

            System.assertEquals(false, result.isSuccess());
            System.assert(errorsOf(result).contains('Verification did not pass'), errorsOf(result));
        }
    }

    // Org rules outside this package (for example a base-branch check) can refuse Ready to Promote on a test story, so the uncheck
    // is exercised on in-memory records: a story that was Running with both boxes checked, and the same story with a new status.
    private static copado__User_Story__c statusChange(String newStatus, Boolean bypassed) {
        Id storyId = copado__User_Story__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        copado__User_Story__c old = new copado__User_Story__c(
            Id = storyId,
            Verification_Status__c = 'Running',
            Bypass_Verification__c = bypassed,
            copado__Promote_Change__c = true,
            copado__Promote_and_Deploy__c = true
        );
        copado__User_Story__c story = old.clone(true, true);
        story.Verification_Status__c = newStatus;
        StoryBypass.apply(new List<copado__User_Story__c>{ story }, new Map<Id, copado__User_Story__c>{ storyId => old });
        return story;
    }

    @IsTest
    static void issuesUnchecksBothBoxesOnAStoryThatIsNotBypassed() {
        System.runAs(newUser(false)) {
            copado__User_Story__c story = statusChange('Issues', false);

            System.assertEquals(false, story.copado__Promote_Change__c, 'A run that finds issues unchecks Ready to Promote');
            System.assertEquals(false, story.copado__Promote_and_Deploy__c, 'and Promote and Deploy');
        }
    }

    @IsTest
    static void aBypassedStoryKeepsReadyToPromoteOnIssues() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = statusChange('Issues', true);

            System.assertEquals(true, story.copado__Promote_Change__c, 'The bypass already accepted the issues');
            System.assertEquals(false, story.copado__Promote_and_Deploy__c, 'Promote and Deploy is never allowed with issues');
        }
    }

    @IsTest
    static void failedAndCleanLeaveTheBoxesAlone() {
        System.runAs(newUser(false)) {
            copado__User_Story__c failed = statusChange('Failed', false);
            System.assertEquals(true, failed.copado__Promote_Change__c, 'Failed means the run broke, not that the story has issues');
            System.assertEquals(true, failed.copado__Promote_and_Deploy__c);

            copado__User_Story__c clean = statusChange('Clean', false);
            System.assertEquals(true, clean.copado__Promote_Change__c);
        }
    }

    @IsTest
    static void theOrgWideSwitchLeavesTheBoxesChecked() {
        System.runAs(newUser(false)) {
            insert new Story_Verification_Control__c(SetupOwnerId = UserInfo.getOrganizationId(), Disable_Story_Verification__c = true);

            copado__User_Story__c story = statusChange('Issues', false);

            System.assertEquals(true, story.copado__Promote_Change__c, 'The gate is off org-wide');
        }
    }

    @IsTest
    static void promoteAndDeployIsNeverAllowedOnABypassedStory() {
        System.runAs(newUser(true)) {
            copado__User_Story__c story = newStory();
            bypass(story.Id);

            Database.SaveResult result = Database.update(new copado__User_Story__c(Id = story.Id, copado__Promote_and_Deploy__c = true), false);

            System.assertEquals(false, result.isSuccess());
            System.assert(errorsOf(result).contains('Promote and Deploy is not allowed'), errorsOf(result));
        }
    }
}
