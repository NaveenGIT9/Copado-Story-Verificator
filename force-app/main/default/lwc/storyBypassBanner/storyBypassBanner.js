import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import USER_ID from '@salesforce/user/Id';
import getBypassedStories from '@salesforce/apex/StoryBypassController.getBypassedStories';
import NAME_FIELD from '@salesforce/schema/copado__User_Story__c.Name';
import STATUS_FIELD from '@salesforce/schema/copado__User_Story__c.Verification_Status__c';
import BYPASS_FIELD from '@salesforce/schema/copado__User_Story__c.Bypass_Verification__c';
import REASON_FIELD from '@salesforce/schema/copado__User_Story__c.Bypass_Reason__c';
import BYPASSED_BY_FIELD from '@salesforce/schema/copado__User_Story__c.Bypassed_By__r.Name';
import BYPASSED_AT_FIELD from '@salesforce/schema/copado__User_Story__c.Bypassed_At__c';
import PROMOTE_FIELD from '@salesforce/schema/copado__User_Story__c.copado__Promote_Change__c';
import MODIFIED_BY_FIELD from '@salesforce/schema/copado__User_Story__c.LastModifiedById';

const STORY_OBJECT = 'copado__User_Story__c';
const PROMOTION_OBJECT = 'copado__Promotion__c';
const STORY_FIELDS = [NAME_FIELD, STATUS_FIELD, BYPASS_FIELD, REASON_FIELD, BYPASSED_BY_FIELD, BYPASSED_AT_FIELD, PROMOTE_FIELD, MODIFIED_BY_FIELD];

export default class StoryBypassBanner extends LightningElement {
    @api recordId;
    @api objectApiName;

    story;
    promotionStories = [];
    // Ready to Promote as last seen; undefined until the first load, so a box that was already checked never prompts.
    lastPromote;
    confirming = false;

    get isStoryPage() {
        return this.objectApiName === STORY_OBJECT;
    }

    get storyRecordId() {
        return this.isStoryPage ? this.recordId : undefined;
    }

    @wire(getRecord, { recordId: '$storyRecordId', optionalFields: STORY_FIELDS })
    wiredStory({ data }) {
        if (!data) {
            return;
        }
        this.story = data;
        const promote = getFieldValue(data, PROMOTE_FIELD) === true;
        const justChecked = this.lastPromote === false && promote;
        this.lastPromote = promote;
        if (justChecked && this.storyBypassed && getFieldValue(data, MODIFIED_BY_FIELD) === USER_ID) {
            this.confirmPromote();
        }
    }

    connectedCallback() {
        if (this.objectApiName === PROMOTION_OBJECT && this.recordId) {
            getBypassedStories({ promotionId: this.recordId })
                .then((rows) => {
                    this.promotionStories = (rows || []).map((row) => ({ ...row, url: '/' + row.id }));
                })
                .catch(() => {
                    this.promotionStories = [];
                });
        }
    }

    get storyBypassed() {
        return (
            !!this.story &&
            getFieldValue(this.story, STATUS_FIELD) === 'Issues' &&
            getFieldValue(this.story, BYPASS_FIELD) === true
        );
    }

    get storyName() {
        return getFieldValue(this.story, NAME_FIELD);
    }

    get bypassedBy() {
        return getFieldValue(this.story, BYPASSED_BY_FIELD) || 'a release engineer';
    }

    get bypassedAt() {
        const value = getFieldValue(this.story, BYPASSED_AT_FIELD);
        return value ? new Date(value).toLocaleString() : '';
    }

    get reason() {
        return getFieldValue(this.story, REASON_FIELD);
    }

    get showPromotionBanner() {
        return this.promotionStories.length > 0;
    }

    async confirmPromote() {
        if (this.confirming) {
            return;
        }
        this.confirming = true;
        try {
            const proceed = await LightningConfirm.open({
                label: 'Promote a bypassed story?',
                message:
                    'You are going to promote ' +
                    this.storyName +
                    '. Its verification was bypassed and it still has issues. Do you want to proceed?',
                theme: 'warning',
                variant: 'header'
            });
            if (!proceed) {
                await updateRecord({ fields: { Id: this.recordId, [PROMOTE_FIELD.fieldApiName]: false } });
            }
        } finally {
            this.confirming = false;
        }
    }
}
