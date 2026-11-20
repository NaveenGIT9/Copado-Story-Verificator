// Feeds the storyBypassBanner on the Promotion page: the stories in the promotion whose verification found issues and was bypassed.
public with sharing class StoryBypassController {
    public class BypassedStory {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String reason;
        @AuraEnabled
        public String bypassedBy;
    }

    @AuraEnabled
    public static List<BypassedStory> getBypassedStories(Id promotionId) {
        List<BypassedStory> result = new List<BypassedStory>();
        if (promotionId == null) {
            return result;
        }
        for (copado__Promoted_User_Story__c row : [
            SELECT copado__User_Story__c, copado__User_Story__r.Name, copado__User_Story__r.Bypass_Reason__c, copado__User_Story__r.Bypassed_By__r.Name
            FROM copado__Promoted_User_Story__c
            WHERE
                copado__Promotion__c = :promotionId
                AND copado__User_Story__r.Verification_Status__c = 'Issues'
                AND copado__User_Story__r.Bypass_Verification__c = TRUE
            ORDER BY copado__User_Story__r.Name
        ]) {
            BypassedStory story = new BypassedStory();
            story.id = row.copado__User_Story__c;
            story.name = row.copado__User_Story__r.Name;
            story.reason = row.copado__User_Story__r.Bypass_Reason__c;
            story.bypassedBy = row.copado__User_Story__r.Bypassed_By__r?.Name;
            result.add(story);
        }
        return result;
    }
}
