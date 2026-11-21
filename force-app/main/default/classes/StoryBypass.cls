// Bypass Verification bookkeeping on the User Story: stamps who checked it and when, and clears it once a verification
// comes back Clean or Blocked (Blocked can never be bypassed). However the bypass ends (Clean, Blocked, a new push or
// unchecked by hand), its reason, who and when are cleared too, so every bypass needs a fresh reason. A verification that
// finds Issues or Blocked also unchecks the promote boxes, since the validation rules only stop a box being checked, not one
// that already is. Failed (the run broke) changes nothing.
public with sharing class StoryBypass {
    public static void apply(List<copado__User_Story__c> stories, Map<Id, copado__User_Story__c> oldStories) {
        Boolean gateOn = !StoryVerificationSwitch.isDisabled();
        for (copado__User_Story__c story : stories) {
            copado__User_Story__c old = oldStories == null ? null : oldStories.get(story.Id);
            Boolean statusChanged = old != null && story.Verification_Status__c != old.Verification_Status__c;
            Boolean blocked = story.Verification_Status__c == 'Blocked';
            if (gateOn && statusChanged && (story.Verification_Status__c == 'Issues' || blocked)) {
                // A bypass covers Issues, so a bypassed story keeps Ready to Promote; Promote and Deploy is never allowed with Issues.
                story.copado__Promote_and_Deploy__c = false;
                if (blocked || !story.Bypass_Verification__c) {
                    story.copado__Promote_Change__c = false;
                }
            }
            if (statusChanged && (story.Verification_Status__c == 'Clean' || blocked) && story.Bypass_Verification__c) {
                story.Bypass_Verification__c = false;
            }
            if (!story.Bypass_Verification__c && old != null && old.Bypass_Verification__c) {
                story.Bypass_Reason__c = null;
                story.Bypassed_By__c = null;
                story.Bypassed_At__c = null;
                continue;
            }
            if (story.Bypass_Verification__c && (old == null || !old.Bypass_Verification__c)) {
                story.Bypassed_By__c = UserInfo.getUserId();
                story.Bypassed_At__c = System.now();
            }
        }
    }
}
