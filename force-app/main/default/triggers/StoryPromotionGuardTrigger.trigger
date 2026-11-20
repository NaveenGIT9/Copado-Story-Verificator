trigger StoryPromotionGuardTrigger on copado__Promoted_User_Story__c(before insert) {
    StoryPromotionGuard.check(Trigger.new);
}
