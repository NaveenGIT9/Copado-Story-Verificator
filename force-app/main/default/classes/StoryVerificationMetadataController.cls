/**
 * Registers components that the verification found changed in git but missing from the story's metadata
 * (the "Not registered" list of the Verify popup) as User Story Metadata records, in the same shape Copado writes them.
 *
 * The browser only sends WHICH components were ticked ("<kind>|<name>"). What is created is rebuilt here from the verification
 * result stored on the story, so nothing that the verification did not find can be added. Reading and writing run in user mode,
 * and a custom permission decides who is offered the button at all.
 */
public with sharing class StoryVerificationMetadataController {
    private static final String PERMISSION = 'Create_Story_Metadata';
    private static final String COVERAGE_CHECK_ID = 'metadata-coverage';
    private static final String CATEGORY = 'SFDX';
    private static final Integer NAME_LENGTH = 80;
    private static final Integer MAX_ID_SUFFIX = 5;
    private static final Set<String> VERIFIED_STATUSES = new Set<String>{ 'Clean', 'Issues' };

    // The folder a component lives in (as the Function reports it) -> the metadata type Copado records for it. A kind that is not
    // listed here is not offered: guessing a type would write a wrong record.
    private static final Map<String, String> KIND_TYPES = new Map<String, String>{
        'classes' => 'ApexClass',
        'triggers' => 'ApexTrigger',
        'pages' => 'ApexPage',
        'components' => 'ApexComponent',
        'lwc' => 'LightningComponentBundle',
        'aura' => 'AuraDefinitionBundle',
        'flows' => 'Flow',
        'layouts' => 'Layout',
        'permissionsets' => 'PermissionSet',
        'permissionsetgroups' => 'PermissionSetGroup',
        'profiles' => 'Profile',
        'flexipages' => 'FlexiPage',
        'customMetadata' => 'CustomMetadata',
        'customPermissions' => 'CustomPermission',
        'email' => 'EmailTemplate',
        'approvalProcesses' => 'ApprovalProcess',
        'quickActions' => 'QuickAction',
        'tabs' => 'CustomTab',
        'applications' => 'CustomApplication',
        'reports' => 'Report',
        'reportTypes' => 'ReportType',
        'dashboards' => 'Dashboard',
        'staticresources' => 'StaticResource',
        'duplicateRules' => 'DuplicateRule',
        'matchingRules' => 'MatchingRule',
        'globalValueSets' => 'GlobalValueSet',
        'objects' => 'CustomObject',
        'objects/fields' => 'CustomField',
        'objects/validationRules' => 'ValidationRule',
        'objects/recordTypes' => 'RecordType',
        'objects/listViews' => 'ListView',
        'objects/fieldSets' => 'FieldSet',
        'objects/webLinks' => 'WebLink',
        'objects/compactLayouts' => 'CompactLayout',
        'objects/businessProcesses' => 'BusinessProcess'
    };

    /** One record that would be (or is) created. */
    public class Line {
        @AuraEnabled
        public String typeLabel;
        @AuraEnabled
        public String type;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String action;
        @AuraEnabled
        public String path;
        @AuraEnabled
        public Boolean exists = false;
        // Set only when no free unique ID could be found for this line (see freeUniqueId): it cannot be inserted.
        @AuraEnabled
        public String conflict;
        // Set when the unique ID had to be adjusted (-1, -2 ...) because another record already uses it; the line is still inserted.
        @AuraEnabled
        public String note;
        public String uniqueId;
        public Datetime committedAt;
    }

    public class PreviewResult {
        @AuraEnabled
        public String storyName;
        @AuraEnabled
        public String storyTitle;
        @AuraEnabled
        public List<Line> lines = new List<Line>();
        @AuraEnabled
        public Integer newCount = 0;
        @AuraEnabled
        public Integer existingCount = 0;
        @AuraEnabled
        public Integer conflictCount = 0;
        @AuraEnabled
        public List<String> unsupported = new List<String>();
    }

    public class CreateResult {
        @AuraEnabled
        public Integer created = 0;
        @AuraEnabled
        public Integer skipped = 0;
        @AuraEnabled
        public List<String> errors = new List<String>();
    }

    // The few story fields this class needs.
    private class Story {
        Id id;
        String name;
        String title;
        String checks;
    }

    /** Whether the running user may register metadata from the popup (custom permission Create_Story_Metadata). */
    public static Boolean isAllowed() {
        return FeatureManagement.checkPermission(PERMISSION);
    }

    /** The kinds this class can turn into a Copado metadata type; the popup disables the others. */
    public static List<String> supportedKinds() {
        List<String> kinds = new List<String>(KIND_TYPES.keySet());
        kinds.sort();
        return kinds;
    }

    /** Read-only: what Insert would create for the ticked components ("<kind>|<name>"), and what already exists. */
    @AuraEnabled
    public static PreviewResult preview(Id storyId, List<String> keys) {
        try {
            return buildPreview(storyId, keys);
        } catch (StoryVerificationException e) {
            throw auraError(e.getMessage());
        }
    }

    /** Creates the records that preview() lists as new; existing ones are skipped, so a second click creates nothing. */
    @AuraEnabled
    public static CreateResult create(Id storyId, List<String> keys) {
        try {
            PreviewResult preview = buildPreview(storyId, keys);
            CreateResult result = new CreateResult();
            List<copado__User_Story_Metadata__c> records = new List<copado__User_Story_Metadata__c>();
            List<Line> toCreate = new List<Line>();
            for (Line line : preview.lines) {
                if (line.exists) {
                    result.skipped++;
                } else if (line.conflict != null) {
                    result.errors.add(line.name + ': ' + line.conflict);
                } else {
                    records.add(toRecord(storyId, preview.storyName, line));
                    toCreate.add(line);
                }
            }
            if (records.isEmpty()) {
                return result;
            }
            List<Database.SaveResult> saved = Database.insert(records, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < saved.size(); i++) {
                if (saved[i].isSuccess()) {
                    result.created++;
                } else {
                    result.errors.add(toCreate[i].name + ': ' + saved[i].getErrors()[0].getMessage());
                }
            }
            return result;
        } catch (StoryVerificationException e) {
            throw auraError(e.getMessage());
        }
    }

    private static PreviewResult buildPreview(Id storyId, List<String> keys) {
        if (!isAllowed()) {
            throw new StoryVerificationException('You are not allowed to register metadata on stories.');
        }
        Story story = loadStory(storyId);
        Set<String> wanted = new Set<String>(keys == null ? new List<String>() : keys);
        PreviewResult result = new PreviewResult();
        result.storyName = story.name;
        result.storyTitle = story.title;

        List<String> uniqueIds = new List<String>();
        for (Map<String, Object> grp : selectableGroups(story.checks)) {
            String kind = String.valueOf(grp.get('kind'));
            for (Object itemObject : (List<Object>) grp.get('items')) {
                Map<String, Object> item = (Map<String, Object>) itemObject;
                String name = String.valueOf(item.get('name'));
                if (!wanted.contains(kind + '|' + name)) {
                    continue;
                }
                String type = KIND_TYPES.get(kind);
                if (type == null) {
                    result.unsupported.add(name);
                    continue;
                }
                Line line = new Line();
                line.typeLabel = String.valueOf(grp.get('type'));
                line.type = type;
                line.name = name;
                line.action = 'Delete'.equalsIgnoreCase(String.valueOf(item.get('action'))) ? 'Delete' : 'Add';
                line.path = item.get('path') == null ? '' : String.valueOf(item.get('path'));
                line.committedAt = parseTime(item.get('date'));
                line.uniqueId = String.valueOf(story.id) + ';' + line.path + ';' + type + ';' + name;
                result.lines.add(line);
                uniqueIds.add(line.uniqueId);
            }
        }

        // Already on the story = a record with the same TYPE and the same name (whatever its path). A record that only shares the
        // unique ID (for example its type was edited) is a different component: the new record then takes the next free unique ID
        // (-1, -2 ...), so the insert goes ahead instead of failing on the unique ID.
        Set<String> names = new Set<String>();
        List<String> candidates = new List<String>();
        for (Line line : result.lines) {
            names.add(line.name);
            for (Integer i = 0; i <= MAX_ID_SUFFIX; i++) {
                candidates.add(suffixed(line.uniqueId, i));
            }
        }
        Id storyRecordId = story.id;
        Set<String> registered = new Set<String>();
        Set<String> taken = new Set<String>();
        if (!uniqueIds.isEmpty()) {
            for (copado__User_Story_Metadata__c record : [
                SELECT copado__Unique_ID__c, copado__Type__c, copado__Metadata_API_Name__c, copado__User_Story__c
                FROM copado__User_Story_Metadata__c
                WHERE
                    (copado__User_Story__c = :storyRecordId AND copado__Metadata_API_Name__c IN :names)
                    OR copado__Unique_ID__c IN :candidates
                WITH USER_MODE
            ]) {
                if (record.copado__User_Story__c == storyRecordId) {
                    registered.add(typeAndName(record.copado__Type__c, record.copado__Metadata_API_Name__c));
                }
                if (record.copado__Unique_ID__c != null) {
                    taken.add(record.copado__Unique_ID__c);
                }
            }
        }
        for (Line line : result.lines) {
            line.exists = registered.contains(typeAndName(line.type, line.name));
            if (line.exists) {
                result.existingCount++;
                continue;
            }
            String free = freeUniqueId(line.uniqueId, taken);
            if (free == null) {
                line.conflict = 'No free unique ID was found for this component. Correct or delete the record that uses it first.';
                result.conflictCount++;
                continue;
            }
            if (free != line.uniqueId) {
                line.note = 'unique ID adjusted (' + free.substring(line.uniqueId.length()) + ') because another record uses it';
                line.uniqueId = free;
            }
            taken.add(free);
            result.newCount++;
        }
        return result;
    }

    private static String suffixed(String uniqueId, Integer suffixNumber) {
        return suffixNumber == 0 ? uniqueId : uniqueId + '-' + suffixNumber;
    }

    // The unique ID itself, or the first of -1, -2 ... that no record (or earlier line) uses; null when all are taken.
    @TestVisible
    private static String freeUniqueId(String uniqueId, Set<String> taken) {
        for (Integer i = 0; i <= MAX_ID_SUFFIX; i++) {
            String candidate = suffixed(uniqueId, i);
            if (!taken.contains(candidate)) {
                return candidate;
            }
        }
        return null;
    }

    private static String typeAndName(String type, String name) {
        return ((String.isBlank(type) ? '' : type.trim()) + '|' + (String.isBlank(name) ? '' : name.trim())).toLowerCase();
    }

    private static Story loadStory(Id storyId) {
        if (storyId == null) {
            throw new StoryVerificationException('Story Id is required');
        }
        List<copado__User_Story__c> rows;
        try {
            rows = [
                SELECT Id, Name, copado__User_Story_Title__c, Verification_Status__c, Verification_Checks__c
                FROM copado__User_Story__c
                WHERE Id = :storyId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            throw new StoryVerificationException('You do not have access to this story.');
        }
        if (rows.isEmpty()) {
            throw new StoryVerificationException('You do not have access to this story.');
        }
        if (!VERIFIED_STATUSES.contains(rows[0].Verification_Status__c) || String.isBlank(rows[0].Verification_Checks__c)) {
            throw new StoryVerificationException('Verify the story first, then register the missing metadata.');
        }
        Story story = new Story();
        story.id = rows[0].Id;
        story.name = rows[0].Name;
        story.title = rows[0].copado__User_Story_Title__c;
        story.checks = rows[0].Verification_Checks__c;
        return story;
    }

    // The groups of the "Not registered" row of the stored Metadata Coverage check: each { kind, type, items:[{ name, action, date, path }] }.
    private static List<Map<String, Object>> selectableGroups(String checksJson) {
        List<Map<String, Object>> groups = new List<Map<String, Object>>();
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(checksJson);
        } catch (Exception e) {
            return groups;
        }
        if (!(parsed instanceof Map<String, Object>) || !(((Map<String, Object>) parsed).get('checks') instanceof List<Object>)) {
            return groups;
        }
        for (Object checkObject : (List<Object>) ((Map<String, Object>) parsed).get('checks')) {
            if (!(checkObject instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> check = (Map<String, Object>) checkObject;
            if (COVERAGE_CHECK_ID != check.get('id') || !(check.get('rows') instanceof List<Object>)) {
                continue;
            }
            for (Object rowObject : (List<Object>) check.get('rows')) {
                if (!(rowObject instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> row = (Map<String, Object>) rowObject;
                if ('select' != row.get('t') || !(row.get('groups') instanceof List<Object>)) {
                    continue;
                }
                for (Object groupObject : (List<Object>) row.get('groups')) {
                    if (groupObject instanceof Map<String, Object> && ((Map<String, Object>) groupObject).get('items') instanceof List<Object>) {
                        groups.add((Map<String, Object>) groupObject);
                    }
                }
            }
        }
        return groups;
    }

    // "2026-10-14T10:11:34+05:30" (the commit time git reports); anything unreadable is now.
    @TestVisible
    private static Datetime parseTime(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return System.now();
        }
        try {
            return (Datetime) JSON.deserialize('"' + String.valueOf(value) + '"', Datetime.class);
        } catch (Exception e) {
            return System.now();
        }
    }

    // Copado's own pattern: "<story> <action> <type>.<name>", cut at the field length.
    @TestVisible
    private static String recordName(String storyName, Line line) {
        String text = storyName + ' ' + line.action + ' ' + line.type + '.' + line.name;
        return text.length() > NAME_LENGTH ? text.substring(0, NAME_LENGTH) : text;
    }

    private static copado__User_Story_Metadata__c toRecord(Id storyId, String storyName, Line line) {
        return new copado__User_Story_Metadata__c(
            Name = recordName(storyName, line),
            copado__User_Story__c = storyId,
            copado__Type__c = line.type,
            copado__Metadata_API_Name__c = line.name,
            copado__Action__c = line.action,
            copado__Category__c = CATEGORY,
            copado__ModuleDirectory__c = line.path,
            copado__Unique_ID__c = line.uniqueId,
            copado__Last_Commit_Date__c = line.committedAt
        );
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
