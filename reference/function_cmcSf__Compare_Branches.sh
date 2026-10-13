#!/usr/bin/env node

const { exec, execSync } = require('child_process');
const util = require('util');
const execAsync = util.promisify(exec);

async function checkBranches(gitRepoUrl, branchesToCheck) {
    //console.log("Environment Variables:", JSON.stringify(process.env)); // Log all environment variables
    try {
        console.log("GIT_REPO_URL:", gitRepoUrl);
        console.log("BRANCHES_TO_CHECK:", branchesToCheck);
        
        // Parse the gitRepoUrl if its in JSON format
        const repoConfig = JSON.parse(gitRepoUrl);
        const repoUrl = repoConfig.url; // Extract the URL from the JSON object
       
        console.log("Parsed Git Repository URL:", repoUrl);
       
        // Fetch all branches from the repository
        console.log("Fetching branches from repository...");
          
        // Convert branches to check into an array
        const checkBranches = branchesToCheck.split(',');
        console.log("checkBranches:", checkBranches);
       
        // Initialize an array to hold branches that do not exist
        const branchesNotFound = [];
        
        let response = execSync(`copado-git-get --remote ""`, { encoding: 'utf-8' });
        console.log("Remote Branches response...", response);
 
        if (response && response !== '\n') {
            response = response.replace('\n','');
			const remoteBranches = response.split(', ');
            console.log("remoteBranches:", remoteBranches);
            
            // Check each branch in the list
            checkBranches.forEach(branch => {
                //const branchRef = `refs/heads/${branch.trim()}`;
                if (!remoteBranches.includes(branch.trim())) {
                    branchesNotFound.push(branch);
                }
            });
        } else{
        	checkBranches.forEach(branch => {
            	branchesNotFound.push(branch); 
           	});
        }

        // Output branches that do not exist
        if (branchesNotFound.length === 0) {
            console.log("All branches exist in the repository.");
        } else {
            console.log("The following branches do not exist in the repository:");
            console.log(branchesNotFound.join('\n'));
        }
        
        // Result data with branches which are not found
        exec(`copado --progress \"Process finished...\" --result-data '${JSON.stringify(branchesNotFound)}'`);
       
    } catch (error) {
        console.error("Error fetching branches:", error);
    }
}

// Example usage:
const gitRepoUrl = process.env.git_json; // Make sure this matches the exact key in the environment variables
const branchesToCheck = process.env.branches_to_check;

checkBranches(gitRepoUrl, branchesToCheck);