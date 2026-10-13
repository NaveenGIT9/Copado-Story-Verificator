public with sharing class StoryVerificationComplete {
    public class Request {
        @InvocableVariable(label='Job Execution Id' description='Id of the finished copado__JobExecution__c' required=true)
        public Id jobExecutionId;
    }

    @InvocableMethod(
        label='Complete Story Verification'
        description='Writes the result of a finished Story_Verification job back to the user story'
    )
    public static void complete(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<Id> jobExecutionIds = new List<Id>();
        for (Request req : requests) {
            jobExecutionIds.add(req.jobExecutionId);
        }
        StoryVerificationService.completeVerifications(jobExecutionIds);
    }
}
