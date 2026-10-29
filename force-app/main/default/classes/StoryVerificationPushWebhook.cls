// GitHub "push" webhook. Every push to a story feature branch (GitHub web edit, local git push or Copado commit) records the new
// branch head, so the Branch_Changed gate rules block Ready to Promote until the story is verified again.
// Runs as the Site guest user: it only checks the signature and publishes Story_Branch_Push__e; StoryBranchPushHandler updates the story.
@RestResource(urlMapping='/storyverification/push')
global without sharing class StoryVerificationPushWebhook {
    private static final String SETTING_NAME = 'Default';
    private static final String SIGNATURE_PREFIX = 'sha256=';
    private static final String REF_PREFIX = 'refs/heads/feature/';
    private static final Pattern STORY_NAME = Pattern.compile('^[A-Za-z]+-[0-9]+$');
    private static final Pattern SHA = Pattern.compile('^[0-9a-f]{40}$');
    private static final String DELETED_SHA = '0000000000000000000000000000000000000000';

    @TestVisible
    private static String secretOverride;

    @HttpPost
    global static void receive() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String secret = loadSecret();
        if (String.isBlank(secret)) {
            reply(res, 500, 'Webhook secret is not configured');
            return;
        }
        Blob body = req.requestBody == null ? Blob.valueOf('') : req.requestBody;
        if (!signatureMatches(body, header(req, 'X-Hub-Signature-256'), secret)) {
            reply(res, 401, 'Invalid signature');
            return;
        }
        String eventName = header(req, 'X-GitHub-Event');
        if (eventName == 'ping') {
            reply(res, 200, 'pong');
            return;
        }
        if (eventName != 'push') {
            reply(res, 200, 'Ignored: event ' + eventName);
            return;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body.toString());
        } catch (JSONException e) {
            parsed = null;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            reply(res, 400, 'Body is not a JSON object');
            return;
        }
        Story_Branch_Push__e push = toEvent((Map<String, Object>) parsed);
        if (push == null) {
            reply(res, 200, 'Ignored: not a story feature branch update');
            return;
        }
        Database.SaveResult sr = EventBus.publish(push);
        if (!sr.isSuccess()) {
            reply(res, 500, 'Could not publish the push: ' + sr.getErrors()[0].getMessage());
            return;
        }
        reply(res, 200, 'Recorded ' + push.Story_Name__c + ' at ' + push.Head_SHA__c);
    }

    private static Story_Branch_Push__e toEvent(Map<String, Object> payload) {
        String ref = payload.get('ref') == null ? '' : String.valueOf(payload.get('ref'));
        String after = payload.get('after') == null ? '' : String.valueOf(payload.get('after')).toLowerCase();
        if (!ref.startsWith(REF_PREFIX) || after == DELETED_SHA || !SHA.matcher(after).matches()) {
            return null;
        }
        String storyName = ref.substring(REF_PREFIX.length());
        if (!STORY_NAME.matcher(storyName).matches()) {
            return null;
        }
        return new Story_Branch_Push__e(Story_Name__c = storyName.toUpperCase(), Head_SHA__c = after, Pushed_At__c = pushedAt(payload));
    }

    // repository.pushed_at is GitHub's own receive time (Unix seconds), unlike commit dates which the author can set to anything.
    private static Datetime pushedAt(Map<String, Object> payload) {
        Object repo = payload.get('repository');
        if (repo instanceof Map<String, Object>) {
            Object raw = ((Map<String, Object>) repo).get('pushed_at');
            if (raw instanceof Integer || raw instanceof Long) {
                return Datetime.newInstance(Long.valueOf(String.valueOf(raw)) * 1000);
            }
        }
        return System.now();
    }

    private static Boolean signatureMatches(Blob body, String signature, String secret) {
        if (String.isBlank(signature) || !signature.startsWith(SIGNATURE_PREFIX)) {
            return false;
        }
        String expected = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', body, Blob.valueOf(secret)));
        return constantTimeEquals(expected, signature.substring(SIGNATURE_PREFIX.length()).toLowerCase());
    }

    private static Boolean constantTimeEquals(String a, String b) {
        if (a.length() != b.length()) {
            return false;
        }
        Integer diff = 0;
        for (Integer i = 0; i < a.length(); i++) {
            diff |= a.charAt(i) ^ b.charAt(i);
        }
        return diff == 0;
    }

    private static String loadSecret() {
        if (secretOverride != null) {
            return secretOverride;
        }
        Story_Verification_Setting__mdt setting = Story_Verification_Setting__mdt.getInstance(SETTING_NAME);
        return setting == null ? null : setting.GitHub_Webhook_Secret__c;
    }

    private static String header(RestRequest req, String name) {
        for (String key : req.headers.keySet()) {
            if (key.equalsIgnoreCase(name)) {
                return req.headers.get(key);
            }
        }
        return null;
    }

    private static void reply(RestResponse res, Integer statusCode, String message) {
        res.statusCode = statusCode;
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'message' => message }));
    }
}
