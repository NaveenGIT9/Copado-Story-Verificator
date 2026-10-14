@IsTest
private class StoryVerificationMetadataControllerTest {
    private static final String STORY_TITLE = 'SVM Story';
    private static final String CLASS_PATH = 'force-app/main/default/classes/ChatterUtil.cls';

    // Some orgs make Jira_Key__c mandatory on the story; fill it when the field exists (set by name so this compiles everywhere).
    private static copado__User_Story__c withJira(copado__User_Story__c story) {
        if (Schema.SObjectType.copado__User_Story__c.fields.getMap().containsKey('Jira_Key__c')) {
            story.put('Jira_Key__c', 'SV-1');
        }
        return story;
    }

    @TestSetup
    static void setup() {
        insert withJira(new copado__User_Story__c(copado__User_Story_Title__c = STORY_TITLE));
    }

    private static User newUser(Boolean withCreator) {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String suffix = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        User u = new User(
            Alias = 'svmeta',
            Email = 'svmeta@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SVMeta',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'svmeta.' + suffix + '@example.com.invalid'
        );
        insert u;
        List<String> names = new List<String>{ 'Copado_Story_Verification_User' };
        if (withCreator) {
            names.add('Copado_Story_Verification_Metadata_Creator');
        }
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet access : [SELECT Id FROM PermissionSet WHERE Name IN :names]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = access.Id));
        }
        insert assignments;
        return u;
    }

    private static copado__User_Story__c story() {
        return [SELECT Id, Name FROM copado__User_Story__c WHERE copado__User_Story_Title__c = :STORY_TITLE];
    }

    private static Map<String, Object> item(String name, String action, String commitTime, String path) {
        return new Map<String, Object>{ 'name' => name, 'action' => action, 'date' => commitTime, 'path' => path };
    }

    // The stored result of a verification whose Metadata Coverage check lists these components as not registered.
    private static String checksJson() {
        List<Object> groups = new List<Object>{
            new Map<String, Object>{
                'kind' => 'classes',
                'type' => 'Apex Class',
                'items' => new List<Object>{
                    item('ChatterUtil', 'Add', '2026-10-14T10:11:34+05:30', CLASS_PATH),
                    item('OldHelper', 'Delete', '2026-10-14T09:00:00+00:00', 'force-app/main/default/classes/OldHelper.cls')
                }
            },
            new Map<String, Object>{
                'kind' => 'objects/fields',
                'type' => 'Custom Field',
                'items' => new List<Object>{ item('Contact.Phone2__c', 'Add', '', 'force-app/main/default/objects/Contact/fields/Phone2__c.field-meta.xml') }
            },
            new Map<String, Object>{ 'kind' => 'weirdFolder', 'type' => 'Weird', 'items' => new List<Object>{ item('Thing', 'Add', '', 'x/Thing.xyz') } }
        };
        Map<String, Object> row = new Map<String, Object>{ 't' => 'select', 'label' => 'Not registered', 'count' => 4, 'groups' => groups };
        Map<String, Object> check = new Map<String, Object>{ 'id' => 'metadata-coverage', 'status' => 'fail', 'rows' => new List<Object>{ row } };
        return JSON.serialize(new Map<String, Object>{ 'checks' => new List<Object>{ check } });
    }

    private static void storeVerification(Id storyId, String status) {
        update new copado__User_Story__c(Id = storyId, Verification_Status__c = status, Verification_Checks__c = checksJson());
    }

    @IsTest
    static void previewListsOnlyTheTickedComponentsWithCopadosTypes() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            storeVerification(story.Id, 'Issues');

            StoryVerificationMetadataController.PreviewResult result = StoryVerificationMetadataController.preview(
                story.Id,
                new List<String>{ 'classes|ChatterUtil', 'objects/fields|Contact.Phone2__c', 'weirdFolder|Thing', 'classes|NotInTheResult' }
            );

            System.assertEquals(story.Name, result.storyName);
            System.assertEquals(STORY_TITLE, result.storyTitle);
            System.assertEquals(2, result.lines.size(), 'A component that is not in the stored result is ignored');
            System.assertEquals('ApexClass', result.lines[0].type);
            System.assertEquals('Apex Class', result.lines[0].typeLabel);
            System.assertEquals('ChatterUtil', result.lines[0].name);
            System.assertEquals('Add', result.lines[0].action);
            System.assertEquals(CLASS_PATH, result.lines[0].path);
            System.assertEquals('CustomField', result.lines[1].type);
            System.assertEquals(new List<String>{ 'Thing' }, result.unsupported, 'A folder that cannot be mapped to a type is not guessed');
            System.assertEquals(2, result.newCount);
            System.assertEquals(0, result.existingCount);
            System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story_Metadata__c], 'A preview writes nothing');
        }
    }

    @IsTest
    static void createInsertsRecordsInCopadosShapeAndASecondRunCreatesNothing() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            storeVerification(story.Id, 'Issues');
            List<String> keys = new List<String>{ 'classes|ChatterUtil', 'classes|OldHelper' };

            StoryVerificationMetadataController.CreateResult first = StoryVerificationMetadataController.create(story.Id, keys);

            System.assertEquals(2, first.created, String.valueOf(first.errors));
            System.assertEquals(0, first.skipped);
            Map<String, copado__User_Story_Metadata__c> byName = new Map<String, copado__User_Story_Metadata__c>();
            for (copado__User_Story_Metadata__c record : [
                SELECT Name, copado__User_Story__c, copado__Type__c, copado__Metadata_API_Name__c, copado__Action__c,
                    copado__Category__c, copado__ModuleDirectory__c, copado__Unique_ID__c, copado__Last_Commit_Date__c
                FROM copado__User_Story_Metadata__c
            ]) {
                byName.put(record.copado__Metadata_API_Name__c, record);
            }
            copado__User_Story_Metadata__c added = byName.get('ChatterUtil');
            System.assertEquals(story.Id, added.copado__User_Story__c);
            System.assertEquals(story.Name + ' Add ApexClass.ChatterUtil', added.Name);
            System.assertEquals('ApexClass', added.copado__Type__c);
            System.assertEquals('Add', added.copado__Action__c);
            System.assertEquals('SFDX', added.copado__Category__c);
            System.assertEquals(CLASS_PATH, added.copado__ModuleDirectory__c);
            System.assertEquals(String.valueOf(story.Id) + ';' + CLASS_PATH + ';ApexClass;ChatterUtil', added.copado__Unique_ID__c);
            System.assertEquals(Datetime.newInstanceGmt(2026, 10, 14, 4, 41, 34), added.copado__Last_Commit_Date__c, 'The commit time keeps its time zone');
            System.assertEquals('Delete', byName.get('OldHelper').copado__Action__c);

            StoryVerificationMetadataController.CreateResult second = StoryVerificationMetadataController.create(story.Id, keys);
            System.assertEquals(0, second.created, 'Nothing is created twice');
            System.assertEquals(2, second.skipped);
            System.assertEquals(2, [SELECT COUNT() FROM copado__User_Story_Metadata__c]);

            StoryVerificationMetadataController.PreviewResult again = StoryVerificationMetadataController.preview(story.Id, keys);
            System.assertEquals(2, again.existingCount, 'The preview shows what already exists');
            System.assertEquals(0, again.newCount);
        }
    }

    @IsTest
    static void aRecordOfAnotherTypeWithTheSameNameIsNotTheSameComponent() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            storeVerification(story.Id, 'Issues');
            // Someone edited the Type of this record from ApexClass to ApexTrigger; its unique ID still says ApexClass.
            insert new copado__User_Story_Metadata__c(
                Name = 'SV edited type',
                copado__User_Story__c = story.Id,
                copado__Type__c = 'ApexTrigger',
                copado__Metadata_API_Name__c = 'ChatterUtil',
                copado__Action__c = 'Add',
                copado__Unique_ID__c = String.valueOf(story.Id) + ';' + CLASS_PATH + ';ApexClass;ChatterUtil'
            );
            List<String> keys = new List<String>{ 'classes|ChatterUtil' };

            StoryVerificationMetadataController.PreviewResult preview = StoryVerificationMetadataController.preview(story.Id, keys);

            System.assertEquals(false, preview.lines[0].exists, 'A trigger called ChatterUtil is not the class ChatterUtil');
            System.assert(preview.lines[0].conflict.contains('ApexTrigger'), String.valueOf(preview.lines[0].conflict));
            System.assertEquals(1, preview.conflictCount);
            System.assertEquals(0, preview.newCount);
            System.assertEquals(0, preview.existingCount);

            StoryVerificationMetadataController.CreateResult result = StoryVerificationMetadataController.create(story.Id, keys);
            System.assertEquals(0, result.created, 'A conflicting line is not inserted');
            System.assertEquals(1, result.errors.size());
            System.assert(result.errors[0].startsWith('ChatterUtil: '), result.errors[0]);
            System.assertEquals(1, [SELECT COUNT() FROM copado__User_Story_Metadata__c], 'Nothing was added next to the conflicting record');
        }
    }

    @IsTest
    static void theSameTypeAndNameCountsAsRegisteredWhateverItsPath() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            storeVerification(story.Id, 'Issues');
            insert new copado__User_Story_Metadata__c(
                Name = 'SV same component',
                copado__User_Story__c = story.Id,
                copado__Type__c = 'apexclass',
                copado__Metadata_API_Name__c = 'chatterutil',
                copado__Action__c = 'Add',
                copado__Unique_ID__c = 'registered-without-the-path'
            );

            StoryVerificationMetadataController.PreviewResult preview = StoryVerificationMetadataController.preview(
                story.Id,
                new List<String>{ 'classes|ChatterUtil' }
            );

            System.assertEquals(true, preview.lines[0].exists, 'Same type and name, ignoring case and path');
            System.assertEquals(null, preview.lines[0].conflict);
            System.assertEquals(1, preview.existingCount);
            System.assertEquals(0, preview.newCount);
        }
    }

    @IsTest
    static void aUserWithoutThePermissionCanNeitherPreviewNorCreate() {
        User user = newUser(false);
        System.runAs(user) {
            copado__User_Story__c story = story();
            storeVerification(story.Id, 'Issues');
            System.assertEquals(false, StoryVerificationMetadataController.isAllowed());
            for (Integer i = 0; i < 2; i++) {
                String message = null;
                try {
                    if (i == 0) {
                        StoryVerificationMetadataController.preview(story.Id, new List<String>{ 'classes|ChatterUtil' });
                    } else {
                        StoryVerificationMetadataController.create(story.Id, new List<String>{ 'classes|ChatterUtil' });
                    }
                } catch (AuraHandledException e) {
                    message = e.getMessage();
                }
                System.assertEquals('You are not allowed to register metadata on stories.', message);
            }
            System.assertEquals(0, [SELECT COUNT() FROM copado__User_Story_Metadata__c]);
        }
    }

    @IsTest
    static void thePermissionSetTurnsTheButtonOn() {
        User user = newUser(true);
        System.runAs(user) {
            System.assertEquals(true, StoryVerificationMetadataController.isAllowed());
        }
    }

    @IsTest
    static void aStoryThatIsNotVerifiedYetCannotBeUsed() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            for (String status : new List<String>{ 'Running', 'Failed', null }) {
                update new copado__User_Story__c(Id = story.Id, Verification_Status__c = status, Verification_Checks__c = checksJson());
                String message = null;
                try {
                    StoryVerificationMetadataController.preview(story.Id, new List<String>{ 'classes|ChatterUtil' });
                } catch (AuraHandledException e) {
                    message = e.getMessage();
                }
                System.assertEquals('Verify the story first, then register the missing metadata.', message, 'status: ' + status);
            }
        }
    }

    @IsTest
    static void aStoryWithoutStoredChecksOrWithUnreadableOnesListsNothing() {
        User user = newUser(true);
        System.runAs(user) {
            copado__User_Story__c story = story();
            update new copado__User_Story__c(Id = story.Id, Verification_Status__c = 'Issues', Verification_Checks__c = 'not json');
            System.assertEquals(0, StoryVerificationMetadataController.preview(story.Id, new List<String>{ 'classes|ChatterUtil' }).lines.size());
            update new copado__User_Story__c(Id = story.Id, Verification_Checks__c = '{"checks":[{"id":"metadata-coverage","rows":"x"}]}');
            System.assertEquals(0, StoryVerificationMetadataController.preview(story.Id, new List<String>{ 'classes|ChatterUtil' }).lines.size());
            System.assertEquals(0, StoryVerificationMetadataController.preview(story.Id, null).lines.size());
        }
    }

    @IsTest
    static void recordNamesAreCutAtTheFieldLength() {
        StoryVerificationMetadataController.Line line = new StoryVerificationMetadataController.Line();
        line.action = 'Add';
        line.type = 'CustomField';
        line.name = 'A'.repeat(100);
        System.assertEquals(80, StoryVerificationMetadataController.recordName('US-1', line).length());
        line.name = 'Short__c';
        System.assertEquals('US-1 Add CustomField.Short__c', StoryVerificationMetadataController.recordName('US-1', line));
    }

    @IsTest
    static void commitTimesKeepTheirZoneAndBadOnesBecomeNow() {
        System.assertEquals(
            Datetime.newInstanceGmt(2026, 10, 14, 4, 41, 34),
            StoryVerificationMetadataController.parseTime('2026-10-14T10:11:34+05:30')
        );
        System.assertNotEquals(null, StoryVerificationMetadataController.parseTime('junk'));
        System.assertNotEquals(null, StoryVerificationMetadataController.parseTime(null));
        System.assertNotEquals(null, StoryVerificationMetadataController.parseTime(''));
    }

    @IsTest
    static void supportedKindsCoverTheCommonFoldersButNotGuesses() {
        List<String> kinds = StoryVerificationMetadataController.supportedKinds();
        for (String kind : new List<String>{ 'classes', 'lwc', 'aura', 'objects/fields', 'objects/validationRules', 'permissionsets', 'flows' }) {
            System.assert(kinds.contains(kind), kind);
        }
        System.assert(!kinds.contains('labels'), 'A labels file holds many labels, so it cannot be registered as one component');
    }
}
