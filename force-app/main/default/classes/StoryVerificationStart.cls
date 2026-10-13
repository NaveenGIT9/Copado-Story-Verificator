public with sharing class StoryVerificationStart {
    public class Request {
        @InvocableVariable(label='Story Id' description='Id of the Copado User Story to verify' required=true)
        public Id storyId;
    }

    @InvocableMethod(
        label='Start Story Verification'
        description='Starts the Story_Verification Copado job for a user story and marks it Running'
    )
    public static void start(List<Request> requests) {
        if (requests == null) {
            return;
        }
        // One at a time: the managed copado.CreateExecution API accepts a single request per call.
        for (Request req : requests) {
            StoryVerificationService.startVerification(req.storyId);
        }
    }
}
