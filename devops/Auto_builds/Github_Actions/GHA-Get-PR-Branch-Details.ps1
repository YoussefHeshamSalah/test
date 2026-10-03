<#
.SYNOPSIS
    Retrieves branch names and last commit hashes for related pull requests and outputs them as a JSON object.

.DESCRIPTION
    This script is used in a GitHub Actions workflow to fetch the branch names and last commit hashes of related pull requests specified in a JSON input.
    It takes a JSON string ($RelatedPRsJson) containing repository and PR number pairs, queries the GitHub CLI ('gh pr view') for each PR’s branch name and last commit hash,
    and constructs a hashtable mapping submodule names (derived from repository names) to their respective branch names and commit hashes.
    The result is output as a compressed JSON string to $env:GITHUB_OUTPUT for use in subsequent workflow steps.
    If no related PRs are provided, it outputs an empty hashtable. The script is part of the 'Notify Main Repository' workflow to support auto-builds
    by identifying submodule branches and commit hashes tied to PR dependencies.
#>

param (
    [string]$RelatedPRsJson
)

$prBranchDetails = @{ }

if ([string]::IsNullOrEmpty($RelatedPRsJson)) {
    Write-Output "No related PRs provided; skipping branch and commit fetch."
} else {
    $relatedPRs = $RelatedPRsJson | ConvertFrom-Json
    
    foreach ($pr in $relatedPRs) {
        $repo = $pr.repo
        $prNumber = $pr.prNumber
        $repoName = $repo.Split("/")[1]

        Write-Output "Fetching branch name and last commit hash for PR #$prNumber in repo $repo..."
        
        $prDetails = gh pr view $prNumber --repo $repo --json headRefName,headRefOid | ConvertFrom-Json
        if ($prDetails -and $prDetails.headRefName -and $prDetails.headRefOid) {
            $prBranchName = $prDetails.headRefName
            $prLastCommitHash = $prDetails.headRefOid

            Write-Output "Repo Name: $repoName"
            Write-Output "Branch Name: $prBranchName"
            Write-Output "Last Commit Hash: $prLastCommitHash"

            $prBranchDetails[$repoName] = @{
                branchName = $prBranchName
                commitHash = $prLastCommitHash
            }
        } else {
            Write-Output "Failed to retrieve branch name or commit hash for PR #$prNumber in $repoName"
            exit 1
        }
    }
}

$prBranchDetailsJson = $prBranchDetails | ConvertTo-Json -Compress
Write-Output "prBranchDetails=$prBranchDetailsJson" >> $env:GITHUB_OUTPUT
