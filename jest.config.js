const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        ...jestConfig.moduleNameMapper,
        // Local stub that renders its slots, so slotted body/footer content is queryable in tests.
        '^lightning/quickActionPanel$': '<rootDir>/jest-mocks/lightning/quickActionPanel/quickActionPanel.js',
        // lightning/actions only exists inside Salesforce
        '^lightning/actions$': '<rootDir>/jest-mocks/lightning/actions/actions.js'
    },
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver']
};
