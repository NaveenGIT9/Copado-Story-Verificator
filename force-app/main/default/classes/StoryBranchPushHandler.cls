// Applies Story_Branch_Push__e events to the stories: the newest push per story becomes Branch_Head_SHA__c. Deliveries can arrive
// out of order, so a push older than the one already stored (or than the last verification start) is ignored.
// A push of a commit other than the verified one also unchecks Ready to Promote and Promote and Deploy.
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
            SELECT
                Id,
                Name,
                Branch_Head_SHA__c,
                Branch_Head_Pushed_At__c,
                Verified_Head_SHA__c,
                copado__Promote_Change__c,
                copado__Promote_and_Deploy__c
            FROM copado__User_Story__c
            WHERE Name IN :latestByStory.keySet()
        ]) {
            copado__User_Story__c upd = headUpdate(story, latestByStory.get(story.Name));
            if (upd != null) {
                updates.add(upd);
            }
        }
        List<copado__User_Story__c> retries = new List<copado__User_Story__c>();
        List<Database.SaveResult> results = Database.update(updates, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            copado__User_Story__c failed = updates[i];
            logError(failed.Id, results[i]);
            // Another rule or trigger may refuse the uncheck; the branch head must still be stored so the gate blocks a re-check.
            if (failed.isSet('copado__Promote_Change__c')) {
                retries.add(
                    new copado__User_Story__c(
                        Id = failed.Id,
                        Branch_Head_SHA__c = failed.Branch_Head_SHA__c,
                        Branch_Head_Pushed_At__c = failed.Branch_Head_Pushed_At__c
                    )
                );
            }
        }
        List<Database.SaveResult> retried = Database.update(retries, false);
        for (Integer i = 0; i < retried.size(); i++) {
            if (!retried[i].isSuccess()) {
                logError(retries[i].Id, retried[i]);
            }
        }
    }

    @TestVisible
    private static copado__User_Story__c headUpdate(copado__User_Story__c story, Story_Branch_Push__e push) {
        Boolean newer = story.Branch_Head_Pushed_At__c == null || push.Pushed_At__c >= story.Branch_Head_Pushed_At__c;
        if (!newer || push.Head_SHA__c == story.Branch_Head_SHA__c) {
            return null;
        }
        copado__User_Story__c upd = new copado__User_Story__c(
            Id = story.Id,
            Branch_Head_SHA__c = push.Head_SHA__c,
            Branch_Head_Pushed_At__c = push.Pushed_At__c
        );
        Boolean unverified = push.Head_SHA__c != story.Verified_Head_SHA__c;
        if (unverified && (story.copado__Promote_Change__c == true || story.copado__Promote_and_Deploy__c == true)) {
            upd.copado__Promote_Change__c = false;
            upd.copado__Promote_and_Deploy__c = false;
        }
        return upd;
    }

    private static void logError(Id storyId, Database.SaveResult result) {
        System.debug(LoggingLevel.ERROR, 'Story branch head not saved for ' + storyId + ': ' + result.getErrors()[0].getMessage());
    }
}
