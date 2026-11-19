@IsTest
private class StoryVerificationSwitchTest {
    private static final String SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    private static final String SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

    private static User newAdmin() {
        Profile adminProfile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        return new User(
            Alias = 'svswitch',
            Email = 'svswitch@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVSwitch',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svswitch.' + suffix + '@example.com.invalid'
        );
    }

    private static void setOrgDefault(Boolean disabled) {
        insert new Story_Verification_Control__c(SetupOwnerId = UserInfo.getOrganizationId(), Disable_Story_Verification__c = disabled);
    }

    private static copado__User_Story__c promotedStory() {
        return new copado__User_Story__c(
            Branch_Head_SHA__c = SHA_A,
            Verified_Head_SHA__c = SHA_A,
            copado__Promote_Change__c = true,
            copado__Promote_and_Deploy__c = true
        );
    }

    @IsTest
    static void theGateIsOnWhenNothingIsConfigured() {
        System.runAs(newAdmin()) {
            System.assertEquals(false, StoryVerificationSwitch.isDisabled());
            System.assertEquals(false, StoryVerificationSwitch.isGateDisabled());
        }
    }

    @IsTest
    static void theOrgDefaultSwitchesTheGateOff() {
        setOrgDefault(true);
        System.runAs(newAdmin()) {
            System.assertEquals(true, StoryVerificationSwitch.isDisabled());
            System.assertEquals(true, StoryVerificationSwitch.isGateDisabled());
        }
    }

    @IsTest
    static void anUntickedOrgDefaultKeepsTheGateOn() {
        setOrgDefault(false);
        System.runAs(newAdmin()) {
            System.assertEquals(false, StoryVerificationSwitch.isDisabled());
        }
    }

    @IsTest
    static void aNewCommitKeepsThePromoteBoxesWhileTheGateIsOff() {
        setOrgDefault(true);
        System.runAs(newAdmin()) {
            copado__User_Story__c upd = StoryBranchPushHandler.headUpdate(
                promotedStory(),
                new Story_Branch_Push__e(Head_SHA__c = SHA_B, Pushed_At__c = System.now())
            );

            System.assertEquals(SHA_B, upd.Branch_Head_SHA__c, 'The branch head is still recorded');
            System.assertEquals(false, upd.isSet('copado__Promote_Change__c'));
            System.assertEquals(false, upd.isSet('copado__Promote_and_Deploy__c'));
        }
    }

    @IsTest
    static void aNewCommitUnchecksThePromoteBoxesWhileTheGateIsOn() {
        setOrgDefault(false);
        System.runAs(newAdmin()) {
            copado__User_Story__c upd = StoryBranchPushHandler.headUpdate(
                promotedStory(),
                new Story_Branch_Push__e(Head_SHA__c = SHA_B, Pushed_At__c = System.now())
            );

            System.assertEquals(false, upd.copado__Promote_Change__c);
            System.assertEquals(false, upd.copado__Promote_and_Deploy__c);
        }
    }
}
