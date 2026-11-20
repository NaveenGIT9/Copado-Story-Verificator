trigger StoryBypassTrigger on copado__User_Story__c(before insert, before update) {
    StoryBypass.apply(Trigger.new, Trigger.oldMap);
}
