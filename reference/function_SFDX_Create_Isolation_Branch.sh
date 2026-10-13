#!/usr/bin/env node
'use strict';

// #region Setup
const child_process = require('child_process');
const fs = require('fs');

const { gitDepth, dataJson, isTest, gitEmail, gitName } = process.env;

const CUSTOM_ERROR = {
		COMMAND_EXECUTION_ERROR: 'CommandExecutionError'
	},
	RESULT_INFO = {
		LEVEL: {
			INFO: 'INFO',
			ERROR: 'ERROR',
			WARN: 'WARN'
		},
		ADDITIONAL_INFORMATION: {
			GIT_CLONE: 'Git Clone',
			GIT_CHECKOUT: 'Git Checkout',
			GIT_COMMIT: 'Git Commit',
			GIT_PUSH: 'Git Push',
			GIT_FIND_COMMIT_ID: 'Git Find Commit Id',
			UPLOAD_FILES: 'Upload Files'
		},
		CATEGORY: {
			UNKNOWN_EXCEPTION: 'Unknown Exception',
			COPADO_INFO: 'Copado Info',
			COPADO_SERVICE: 'Copado Service',
			FILE_SYSTEM: 'File System',
			GIT_SERVICE: 'Git Service'
		}
	},
	TEMP_DIRECTORY = getPath('/tmp'),
	COPADO_INFO_PREFIX = 'CopadoFunction INFO',
	RESULT_TABLE_COLUMNS = [
		{
			label: 'Level',
			fieldName: 'Level',
			type: 'text',
			wrapText: true,
			customLabel: 'Level',
			initialWidth: 80
		},
		{
			label: 'Category',
			fieldName: 'Category',
			type: 'text',
			wrapText: true,
			customLabel: 'Category',
			initialWidth: 120
		},
		{
			label: 'Additional Information',
			fieldName: 'AdditionalInformation',
			type: 'text',
			wrapText: true,
			customLabel: 'Additional_Information',
			initialWidth: 200
		},
		{
			label: 'Message',
			fieldName: 'Message',
			type: 'text',
			wrapText: true,
			customLabel: 'Message'
		}
	],
	RESULT_TABLE_HEADER = {
		label: 'Create Isolation Branch Result',
		customLabel: 'create_isolation_branch_result'
	},
	HEADER_ICON = 'standard:note',
	GIT_DEPTH = getGitDepth(),
	parsedDataJson = parseDataJson(),
	isolationBranchName = `isolation/${parsedDataJson.featureBranchName}`, // Only exist to show clean PR to developer, but will not be merged, merge is done in feature branch
	commitMessageValue = (parsedDataJson.commitMessage || parsedDataJson.featureBranchName).replace(/[`"$\\]/g, '\\$&');

let executionError,
	processes = new Map(),
	resultViewerJson = [];
// #endregion

// SCRIPT FUNCTIONS

async function execute() {
	try {
		await this.cloneRepositoryAndCheckoutFeatureBranch();
		await this.configureGit(gitEmail, gitName);
		await this.fetchRequiredBranches();
		await this.createIsolationBranchFromDestinationBranch();
		await this.createSquashBranch();
		await this.squashCommits();
		await this.cherryPickAndResolveConflicts();
		await this.pushIsolationBranchToRemote();
	} catch (err) {
		this.logger(`Error stack: ${err.stack}`);
		if (!(err instanceof CommandExecutionError)) {
			this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, RESULT_INFO.CATEGORY.UNKNOWN_EXCEPTION, 'See logs for more info', err.message);
		}
		executionError = err.message || err?.toString() || 'Unknown Error occurred';
	} finally {
		if (resultViewerJson?.length) {
			this.uploadResultViewerJson(resultViewerJson, RESULT_TABLE_COLUMNS, RESULT_TABLE_HEADER, HEADER_ICON);
		}
		if (executionError) {
			await this.executeCommand(this.getErrorCmdString(executionError));
		}
		this.printMetrics();
		if (executionError) {
			process.exit(1);
		}
	}
}

function parseDataJson() {
	// Merge dataJson with environment variables
	let parsedDataJson = {};
	if (process.env.dataJson) {
		try {
			parsedDataJson = JSON.parse(dataJson);
		} catch (e) {
			console.error('Failed to parse dataJson. Ensure it is valid JSON.', e);
			process.exit(1);
		}
	}
	return parsedDataJson;
}

async function cloneRepositoryAndCheckoutFeatureBranch() {
	const featureBranchDepth = parsedDataJson.numberOfCommits ? parsedDataJson.numberOfCommits : GIT_DEPTH;
	const cloneRepository = `copado-git-get --depth "${featureBranchDepth}" "${parsedDataJson.featureBranchName}"`;
	this.asyncCopadoLogMessage('Cloning repository and checking out feature branch');
	await this.executeCommand(cloneRepository, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE);
}

async function configureGit(gitEmail, gitName) {
	const configureGit = `
        git config --local user.email "${gitEmail}" || exit 1
        git config --local user.name "${gitName}" || exit 1
        `;
	await this.executeCommand(configureGit, RESULT_INFO.CATEGORY.GIT_SERVICE);
}

async function fetchRequiredBranches() {
	// ls-remote checks existence without downloading objects. Do this before fetching
	// destination so the early-exit path does not pay for a destination fetch.
	const checkIsolation = `copado-git-get -g "git ls-remote --heads origin ${isolationBranchName}"`;
	let remoteHeads = '';
	try {
		remoteHeads = await this.executeCommand(
			checkIsolation,
			RESULT_INFO.CATEGORY.GIT_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE
		);
	} catch {
		// Treat a failed existence check as "does not exist" and continue with creation
		this.logger(`${isolationBranchName} does not exist, proceeding with creation...`);
	}

	if ((remoteHeads || '').trim()) {
		this.logger(`Isolation branch ${isolationBranchName} already exists on remote`);
		this.asyncCopadoLogMessage('Isolation branch exists');
		process.exit(0);
	}
	const fetchDestination = `copado-git-get -g "git fetch origin ${parsedDataJson.destinationBranchName} --depth 1"`;
	this.asyncCopadoLogMessage(`Fetching destination branch ${parsedDataJson.destinationBranchName} and creating isolation branch from it`);
	await this.executeCommand(fetchDestination, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE);
}

async function createIsolationBranchFromDestinationBranch() {
	const cmd = `git checkout -b ${isolationBranchName} origin/${parsedDataJson.destinationBranchName}`;
	await this.executeCommand(cmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CHECKOUT);
}

async function createSquashBranch() {
	const cmd = `git checkout -b squashBranch ${parsedDataJson.featureBranchName}`;
	this.asyncCopadoLogMessage('Isolating changes');
	await this.executeCommand(cmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CHECKOUT);
}

async function squashCommits() {
	const parentCommitCmd = `git rev-parse ${parsedDataJson.initialCommitHash}^`;
	let parentCommit;
	try {
		parentCommit = (
			await this.executeCommand(
				parentCommitCmd,
				RESULT_INFO.CATEGORY.GIT_SERVICE,
				RESULT_INFO.ADDITIONAL_INFORMATION.GIT_FIND_COMMIT_ID,
				false,
				false,
				false
			)
		).trim();
		this.logger('Parent commit:', parentCommit);
	} catch (e) {
		console.error('Error finding parent commit:', e);
		process.exit(1);
	}

	this.asyncCopadoLogMessage('Resetting to parent commit and creating squashed commit');
	await this.executeCommand(
		`git reset --soft ${parentCommit} && git commit -m "${commitMessageValue}"`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_COMMIT
	);
}

async function hasUnmergedPaths() {
	const output = await this.executeCommand(
		`git diff --name-only --diff-filter=U`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE,
		false,
		false,
		true
	);
	return Boolean((output || '').trim());
}

async function cherryPickAndResolveConflicts() {
	// Switch back to isolation branch before cherry-picking
	this.asyncCopadoLogMessage('Switching to isolation branch and cherry-picking squashed commit');
	await this.executeCommand(
		`git checkout ${isolationBranchName}`,
		RESULT_INFO.CATEGORY.GIT_SERVICE,
		RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CHECKOUT
	);

	const cherryPickCmd = `git cherry-pick squashBranch`;
	try {
		await this.executeCommand(cherryPickCmd, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE);
	} catch (error) {
		if (!(await this.hasUnmergedPaths())) {
			throw error;
		}

		// If cherry-pick fails due to conflicts, resolve them by taking feature branch changes
		this.logger('Conflicts detected during cherry-pick, resolving with feature branch winning...');
		// Feature branch always wins; only unmerged paths are updated.
		// Before removing a file, explicitly confirms the theirs stage (stage 3) is absent,
		// so only genuine modify/delete conflicts trigger git rm rather than masking other errors.
		// Capture the paths before modifying the index so git diff has released index.lock.
		const unmergedListFile = `${TEMP_DIRECTORY}/copado_unmerged_paths.txt`;
		await this.executeCommand(
			`git diff --name-only --diff-filter=U -z > "${unmergedListFile}"`,
			RESULT_INFO.CATEGORY.GIT_SERVICE,
			RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE
		);
		const resolveConflicts = [
			`while IFS= read -r -d '' f; do if git show :3:"$f" -- > /dev/null 2>&1; then git checkout --theirs -- "$f"; else git rm -f -- "$f"; fi; done < "${unmergedListFile}"`,
			`git add -A`,
			`GIT_EDITOR=true git cherry-pick --continue --no-edit`
		].join(' && ');
		this.asyncCopadoLogMessage('Resolving conflicts with feature branch changes...');
		await this.executeCommand(resolveConflicts, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_CLONE);
		this.logger('Conflicts resolved - feature branch changes preserved');
	}
}

async function pushIsolationBranchToRemote() {
	const pushIsolationBranch = `copado-git-get -g "git push origin ${isolationBranchName}"`;
	this.asyncCopadoLogMessage('Pushing to origin');
	await this.executeCommand(pushIsolationBranch, RESULT_INFO.CATEGORY.GIT_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.GIT_PUSH);
	this.logger('\n Execution completed successfully');
}

// INNER CLASS
class CommandExecutionError extends Error {
	constructor(message, category, additionalInfo) {
		super(`${category ? category + ' - ' : ''}${additionalInfo ? additionalInfo + ' : ' : ''}${message}`);
		this.name = CUSTOM_ERROR.COMMAND_EXECUTION_ERROR;
	}
}

// INNER FUNCTIONS
function executeCommand(command, category, additionalInfo, disableMetrics, hasJsonResponse, disableLogs, options) {
	this.logger(`===> ${command}`);
	return new Promise((resolve, reject) => {
		let output = '',
			error = '';
		if (!disableMetrics) {
			this.startWatch(category, additionalInfo, processes);
		}
		const childProcess = child_process.spawn(command, [], options ? options : { shell: true });

		childProcess.stdout.on('data', data => {
			const outputStream = data?.toString();
			if (!disableLogs && outputStream) {
				this.logger(outputStream);
			}
			output += outputStream;
		});

		childProcess.stderr.on('data', data => {
			const errorStream = data?.toString();
			if (errorStream) {
				this.logger(errorStream);
				error += errorStream;
			}
		});

		childProcess.on('close', code => {
			if (code !== 0) {
				let errorMessage = '';
				if (hasJsonResponse) {
					try {
						resolve(JSON.parse(output));
					} catch (error) {
						errorMessage = error;
					}
				} else {
					errorMessage = error;
				}
				errorMessage = errorMessage ? errorMessage : `Error executing the command ${command.trim()}`;

				this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, errorMessage);
				const truncatedError = JSON.stringify(
					errorMessage
						.split('\n')
						.filter(msg => !msg.includes(COPADO_INFO_PREFIX))
						.join(' ')
				);
				reject(new CommandExecutionError(truncatedError, category, additionalInfo));
			}
			resolve(hasJsonResponse ? JSON.parse(output) : output);
			if (!disableMetrics) {
				this.endWatch(additionalInfo, processes);
			}
		});

		childProcess.on('error', error => {
			this.populateResultViewer(RESULT_INFO.LEVEL.ERROR, category, additionalInfo, error);
			const truncatedError = JSON.stringify(
				error
					.split('\n')
					.filter(msg => !msg.includes(COPADO_INFO_PREFIX))
					.join(' ')
			);
			reject(new CommandExecutionError(truncatedError, category, additionalInfo));
			if (!disableMetrics) {
				this.endWatch(additionalInfo, processes);
			}
		});
	});
}

function getGitDepth() {
	const gitDepthParsed = parseInt(gitDepth);
	if (gitDepthParsed >= 0) {
		return gitDepthParsed;
	}
	return 100;
}

function startWatch(processType, processName, processes) {
	if (!processName || !processType) {
		return;
	}
	const startTime = process.hrtime();
	processes.set(processName, { name: processName, type: processType, startTime, endTime: null, elapsedTime: null });
}

function endWatch(processName, processes) {
	if (!processName) {
		return;
	}

	if (!processes.has(processName)) {
		console.error(`Process '${processName}' not started.`);
		return;
	}
	const processEntry = processes.get(processName);
	const endTime = process.hrtime();
	const elapsedTime = process.hrtime(processEntry.startTime);
	processEntry.endTime = endTime;
	processEntry.elapsedTime = elapsedTime[0] * 1e9 + elapsedTime[1];
	processes.set(processName, processEntry);
}

function logger(text) {
	console.log(text);
}

function populateResultViewer(level, category, additionalInfo, message) {
	resultViewerJson.push({
		Level: level,
		Category: category,
		Message: message,
		AdditionalInformation: additionalInfo
	});
}
function asyncCopadoLogMessage(msg, logLevel) {
	if (msg) {
		this.populateResultViewer(logLevel ? logLevel : RESULT_INFO.LEVEL.INFO, RESULT_INFO.CATEGORY.COPADO_INFO, '', msg);

		this.executeCommand(`copado -p "${msg}"`, RESULT_INFO.CATEGORY.COPADO_SERVICE);
	}
}

function uploadResultViewerJson(data, columns, header, headerIcon) {
	const RESULT_VIEWER_JSON_PATH = `${TEMP_DIRECTORY}/ResultViewer.json`;

	const fileContent = { data, columns, header, headerIcon };
	fs.writeFileSync(RESULT_VIEWER_JSON_PATH, JSON.stringify(fileContent, null, 2));
	this.uploadFileAtPath(RESULT_VIEWER_JSON_PATH);
}

function getPath(filePath) {
	return isTest ? `${__dirname}/__tests__/__mockDir__${filePath}` : filePath;
}

function uploadFileAtPath(filePath) {
	this.executeCommand(`copado --uploadfile ${filePath}`, RESULT_INFO.CATEGORY.COPADO_SERVICE, RESULT_INFO.ADDITIONAL_INFORMATION.UPLOAD_FILES);
}

function getErrorCmdString(error) {
	const suffix = 'Please check the logs for details.';
	return `copado -p "Error" -e ${JSON.stringify((error || '').trim().substring(0, 32760) + '; ' + suffix)}`;
}

function printMetrics() {
	this.logger('\n   ====================       EXECUTION SUMMARY      ====================   ');
}

// Exported for tests and parity with other scripts
module.exports.execute = execute;
module.exports.executeCommand = executeCommand;
module.exports.cloneRepositoryAndCheckoutFeatureBranch = cloneRepositoryAndCheckoutFeatureBranch;
module.exports.configureGit = configureGit;
module.exports.fetchRequiredBranches = fetchRequiredBranches;
module.exports.createIsolationBranchFromDestinationBranch = createIsolationBranchFromDestinationBranch;
module.exports.createSquashBranch = createSquashBranch;
module.exports.squashCommits = squashCommits;
module.exports.hasUnmergedPaths = hasUnmergedPaths;
module.exports.cherryPickAndResolveConflicts = cherryPickAndResolveConflicts;
module.exports.pushIsolationBranchToRemote = pushIsolationBranchToRemote;
module.exports.getGitDepth = getGitDepth;
module.exports.asyncCopadoLogMessage = asyncCopadoLogMessage;
module.exports.startWatch = startWatch;
module.exports.endWatch = endWatch;
module.exports.logger = logger;
module.exports.populateResultViewer = populateResultViewer;
module.exports.uploadResultViewerJson = uploadResultViewerJson;
module.exports.CommandExecutionError = CommandExecutionError;
module.exports.uploadFileAtPath = uploadFileAtPath;
module.exports.getErrorCmdString = getErrorCmdString;
module.exports.printMetrics = printMetrics;

// EXECUTION
!isTest && this.execute();