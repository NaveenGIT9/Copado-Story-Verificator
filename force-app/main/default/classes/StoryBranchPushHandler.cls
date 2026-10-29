// Applies Story_Branch_Push__e events to the stories: the newest push per story becomes Branch_Head_SHA__c. Deliveries can arrive
// out of order, so a push older than the one already stored (or than the last verification start) is ignored.
public without sharing class StoryBranchPushHandler {
    public static void apply(List<Story_Branch_Push__e> events) {
        Map<String, Story_Branch_Push__e> latestByStory = new Map<String, Story_Branch_Push__e>();
        for (Story_Branch_Push__e e : events) {
            if (String.isBlank(e.Story_Name__c) || String.isBlank(e.Head_SHA__c) || e.Pushed_At__c == null) {
                continue;
            }
            Story_Branch_Push__e current = latestByStory.get(e.Story_Name__c);
            if (current == null || e.Pushed_At__c >= current.Pushed_At__c) {
                latestByStory.put(e.Story_Name__c, e);
            }
        }
        if (latestByStory.isEmpty()) {
            return;
        }
        List<copado__User_Story__c> updates = new List<copado__User_Story__c>();
        for (copado__User_Story__c story : [
            SELECT Id, Name, Branch_Head_SHA__c, Branch_Head_Pushed_At__c
            FROM copado__User_Story__c
            WHERE Name IN :latestByStory.keySet()
        ]) {
            Story_Branch_Push__e push = latestByStory.get(story.Name);
            Boolean newer = story.Branch_Head_Pushed_At__c == null || push.Pushed_At__c >= story.Branch_Head_Pushed_At__c;
            if (newer && push.Head_SHA__c != story.Branch_Head_SHA__c) {
                updates.add(
                    new copado__User_Story__c(
                        Id = story.Id,
                        Branch_Head_SHA__c = push.Head_SHA__c,
                        Branch_Head_Pushed_At__c = push.Pushed_At__c
                    )
                );
            }
        }
        List<Database.SaveResult> results = Database.update(updates, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Story branch head not saved for ' + updates[i].Id + ': ' + results[i].getErrors()[0].getMessage()
                );
            }
        }
    }
}
