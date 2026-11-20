import { createElement } from 'lwc';
import StoryBypassBanner from 'c/storyBypassBanner';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import USER_ID from '@salesforce/user/Id';
import getBypassedStories from '@salesforce/apex/StoryBypassController.getBypassedStories';

jest.mock('lightning/confirm', () => ({ __esModule: true, default: { open: jest.fn() } }));
jest.mock('@salesforce/apex/StoryBypassController.getBypassedStories', () => ({ default: jest.fn() }), { virtual: true });

const STORY_ID = 'a0X000000000001AAA';
const PROMOTION_ID = 'a0Y000000000001AAA';
const OTHER_USER = '005000000000099AAA';

function storyRecord({ status = 'Issues', bypass = true, promote = false, modifiedBy = USER_ID } = {}) {
    return {
        apiName: 'copado__User_Story__c',
        id: STORY_ID,
        fields: {
            Name: { value: 'US-0001' },
            Verification_Status__c: { value: status },
            Bypass_Verification__c: { value: bypass },
            Bypass_Reason__c: { value: 'Hotfix for outage' },
            Bypassed_By__r: { value: { fields: { Name: { value: 'Rel Engineer' } } } },
            Bypassed_At__c: { value: '2026-11-20T10:00:00.000Z' },
            copado__Promote_Change__c: { value: promote },
            LastModifiedById: { value: modifiedBy }
        }
    };
}

function mount(objectApiName, recordId) {
    const element = createElement('c-story-bypass-banner', { is: StoryBypassBanner });
    element.objectApiName = objectApiName;
    element.recordId = recordId;
    document.body.appendChild(element);
    return element;
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('c-story-bypass-banner', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows who, when and why on a bypassed story that still has issues', async () => {
        const element = mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord());
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="story-banner"]')).not.toBeNull();
        expect(element.shadowRoot.querySelector('[data-id="story-banner-who"]').textContent).toContain('Rel Engineer');
        expect(element.shadowRoot.querySelector('[data-id="story-banner-reason"]').textContent).toContain('Hotfix for outage');
    });

    it('shows nothing when the story has issues but no bypass', async () => {
        const element = mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord({ bypass: false }));
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="story-banner"]')).toBeNull();
    });

    it('shows nothing when the story is clean', async () => {
        const element = mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord({ status: 'Clean' }));
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="story-banner"]')).toBeNull();
    });

    it('asks before promoting and unchecks Ready to Promote on No', async () => {
        LightningConfirm.open.mockResolvedValue(false);
        updateRecord.mockResolvedValue({});
        mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord({ promote: false }));
        await flush();

        getRecord.emit(storyRecord({ promote: true }));
        await flush();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(LightningConfirm.open.mock.calls[0][0].message).toContain('You are going to promote US-0001');
        expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: STORY_ID, copado__Promote_Change__c: false } });
    });

    it('keeps Ready to Promote on Yes', async () => {
        LightningConfirm.open.mockResolvedValue(true);
        mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord({ promote: false }));
        await flush();

        getRecord.emit(storyRecord({ promote: true }));
        await flush();

        expect(LightningConfirm.open).toHaveBeenCalledTimes(1);
        expect(updateRecord).not.toHaveBeenCalled();
    });

    it('does not ask when the box was already checked on load or another user checked it', async () => {
        mount('copado__User_Story__c', STORY_ID);
        getRecord.emit(storyRecord({ promote: true }));
        await flush();
        expect(LightningConfirm.open).not.toHaveBeenCalled();

        getRecord.emit(storyRecord({ promote: false }));
        await flush();
        getRecord.emit(storyRecord({ promote: true, modifiedBy: OTHER_USER }));
        await flush();
        expect(LightningConfirm.open).not.toHaveBeenCalled();
    });

    it('lists bypassed stories on a promotion', async () => {
        getBypassedStories.mockResolvedValue([{ id: STORY_ID, name: 'US-0001', reason: 'Hotfix', bypassedBy: 'Rel Engineer' }]);
        const element = mount('copado__Promotion__c', PROMOTION_ID);
        await flush();

        expect(getBypassedStories).toHaveBeenCalledWith({ promotionId: PROMOTION_ID });
        const rows = element.shadowRoot.querySelectorAll('[data-id="promotion-story"]');
        expect(rows.length).toBe(1);
        expect(rows[0].querySelector('a').getAttribute('href')).toBe('/' + STORY_ID);
    });

    it('shows no promotion banner when nothing is bypassed', async () => {
        getBypassedStories.mockResolvedValue([]);
        const element = mount('copado__Promotion__c', PROMOTION_ID);
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="promotion-banner"]')).toBeNull();
    });
});
