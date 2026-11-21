// Stops a User Story whose last verification found issues (Issues or Blocked) from being added to a promotion by any route
// (Add User Stories, data loader, API); the promote-checkbox validation rules never fire on that path. The only way through is
// a release engineer (custom permission Bypass_Verification_Gate) adding an Issues story that has Bypass Verification checked.
// A Blocked story is always refused. Without sharing so a story the running user cannot see is still checked.
public without sharing class StoryPromotionGuard {
    @TestVisible
    static final String NOT_BYPASSED_MESSAGE =
        '{0} cannot be added to this promotion because its last verification found issues. ' +
        'Open the User Story, click Verify, fix the issues it lists, and add the story again once the verification is Clean.';
    @TestVisible
    static final String RELEASE_ENGINEER_MESSAGE =
        'Verification for {0} was bypassed, but it still has issues. Only a release engineer can add it to a promotion.';
    @TestVisible
    static final String BLOCKED_MESSAGE =
        '{0} cannot be added to this promotion because another branch is merged into its feature branch (verification Blocked). ' +
        'A Blocked story cannot be bypassed. Remove the merge from the feature branch, click Verify, and add the story again once the verification is Clean.';

    // Insert only: Copado makes the story lookup on a promotion line read-only once created.
    public static void check(List<copado__Promoted_User_Story__c> rows) {
        if (StoryVerificationSwitch.isDisabled()) {
            return;
        }
        List<copado__Promoted_User_Story__c> toCheck = new List<copado__Promoted_User_Story__c>();
        Set<Id> storyIds = new Set<Id>();
        for (copado__Promoted_User_Story__c row : rows) {
            if (row.copado__User_Story__c != null) {
                toCheck.add(row);
                storyIds.add(row.copado__User_Story__c);
            }
        }
        if (toCheck.isEmpty()) {
            return;
        }
        Map<Id, copado__User_Story__c> withIssues = new Map<Id, copado__User_Story__c>(
            [
                SELECT Id, Name, Bypass_Verification__c, Verification_Status__c
                FROM copado__User_Story__c
                WHERE Id IN :storyIds AND Verification_Status__c IN ('Issues', 'Blocked')
            ]
        );
        if (withIssues.isEmpty()) {
            return;
        }
        Boolean releaseEngineer = FeatureManagement.checkPermission('Bypass_Verification_Gate');
        for (copado__Promoted_User_Story__c row : toCheck) {
            copado__User_Story__c story = withIssues.get(row.copado__User_Story__c);
            if (story == null) {
                continue;
            }
            if (story.Verification_Status__c == 'Blocked') {
                row.addError(String.format(BLOCKED_MESSAGE, new List<Object>{ story.Name }));
                continue;
            }
            if (story.Bypass_Verification__c && releaseEngineer) {
                continue;
            }
            String message = story.Bypass_Verification__c ? RELEASE_ENGINEER_MESSAGE : NOT_BYPASSED_MESSAGE;
            row.addError(String.format(message, new List<Object>{ story.Name }));
        }
    }
}
