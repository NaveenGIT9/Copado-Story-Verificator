trigger StoryBranchPushTrigger on Story_Branch_Push__e(after insert) {
    StoryBranchPushHandler.apply(Trigger.new);
}
