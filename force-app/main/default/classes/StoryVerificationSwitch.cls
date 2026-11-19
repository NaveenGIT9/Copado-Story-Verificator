// Reads the Story_Verification_Control__c on/off switch for the running user (hierarchy: user, then profile, then org default).
public with sharing class StoryVerificationSwitch {
    public static Boolean isDisabled() {
        Story_Verification_Control__c control = Story_Verification_Control__c.getInstance();
        return control != null && control.Disable_Story_Verification__c == true;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isGateDisabled() {
        return isDisabled();
    }
}
