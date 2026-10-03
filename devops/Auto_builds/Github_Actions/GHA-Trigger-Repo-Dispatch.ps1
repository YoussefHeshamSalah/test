<#
.SYNOPSIS
    Triggers an automated build workflow in a target repository using submodule branch details.
    Before triggering, the script checks whether any related pull requests (including the triggering PR
    or associated submodule PRs) are behind or diverged from their base branches. If so, it comments
    on the triggering PR and exits with code 1.

.DESCRIPTION
    This script sends a repository dispatch event to a specified GitHub repository.
    It accepts submodule branch information (in JSON format), a personal access token for authentication,
    and the workflow event type to trigger.

.PARAMETER SubmoduleBranchesJson
    JSON string containing submodule branch and commit info.

.PARAMETER Token
    GitHub Personal Access Token used for authentication.

.PARAMETER EventType
    The event type name that will be used to trigger the workflow in the target repo (required).

.PARAMETER Repo
    Target repository name (required), in the same owner as the calling repository.

.EXAMPLE
    ./GHA-Trigger-Repo-Dispatch.ps1 -SubmoduleBranchesJson $json -Token $token -EventType "Claude_Code_Review" -Repo "test"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SubmoduleBranchesJson,

    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$EventType,

    [Parameter(Mandatory = $true)]
    [string]$Repo
)

Write-Output "Parameters received:"
Write-Output "  EventType=$EventType"
Write-Output "  Repo=$Repo"
Write-Output "  SubmoduleBranchesJson=$SubmoduleBranchesJson"
Write-Output "  Token=[HIDDEN]"

# Build dispatch URL dynamically
$DispatchUrl = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY.Split('/')[0])/$Repo/dispatches"
Write-Output "Dispatch URL set to: $DispatchUrl"

# Define headers for the API requests
$headers = @{
    "Accept"        = "application/vnd.github.v3+json"
    "Authorization" = "token $Token"
    "User-Agent"    = "GHA-Trigger-Repo-Dispatch"
}

# Parse submodule branches from JSON
$submoduleBranches = $SubmoduleBranchesJson | ConvertFrom-Json
Write-Output "Parsed submodule branches: $submoduleBranches"

# Load PR data from GitHub event context if available
try {
    $event = Get-Content $env:GITHUB_EVENT_PATH -ErrorAction Stop | ConvertFrom-Json
    $PRBranch = $event.pull_request.head.ref
    $PRSha    = $event.pull_request.head.sha
    $PRTitle  = $event.pull_request.title
    $PRNumber = $event.pull_request.number
    $RepoFullName = $env:GITHUB_REPOSITORY
} catch {
    Write-Error "No GitHub event context found."
    exit 1
}

$repoName = $RepoFullName.Split("/")[1]
$owner = $RepoFullName.Split("/")[0]
Write-Output "Repo context: $RepoFullName - RepoName=$repoName"
Write-Output "PR Info: Branch=$PRBranch, SHA=$PRSha, Title=$PRTitle, Number=$PRNumber"

# Determine local time (UTC+3)
$currentHour = (Get-Date).AddHours(3).Hour
Write-Output "Local time hour (UTC+3): $currentHour"

# Disable rebase checking between 00:00 and 09:00
if ($currentHour -ge 0 -and $currentHour -lt 9) {
    Write-Warning "Rebase check disabled between 12:00 AM and 09:00 AM (UTC+3)."
    Write-Warning "Skipping rebase validation and proceeding directly to workflow dispatch."
} else {
    # Helper for compare endpoint
    function Compare-Branches {
        param($owner, $repo, $baseRef, $headRef)

        $baseEnc = [System.Uri]::EscapeDataString($baseRef)
        $headEnc = [System.Uri]::EscapeDataString($headRef)
        $compareUrl = "https://api.github.com/repos/$owner/$repo/compare/$baseEnc...$headEnc"
        Write-Output "Comparing $owner/$repo $baseRef ... $headRef"
        try {
            $compare = Invoke-RestMethod -Method Get -Uri $compareUrl -Headers $headers
            return $compare
        } catch {
            Write-Output "Failed to compare $owner/$repo $baseRef...$headRef : $_"
            return $null
        }
    }

    # Collect PRs that need rebase
    $needsRebase = @()

    # Check the triggering PR itself
    $triggerPrUrl = "https://api.github.com/repos/$owner/$repoName/pulls/$PRNumber"
    try {
        $triggerPr = Invoke-RestMethod -Method Get -Uri $triggerPrUrl -Headers $headers
        $triggerBase = $triggerPr.base.ref
        $triggerHead = $triggerPr.head.ref

        $compare = Compare-Branches -owner $owner -repo $repoName -baseRef $triggerBase -headRef $triggerHead
        if ($null -eq $compare) {
            Write-Output "Could not get compare result for trigger PR; skipping compare-based decision for this PR."
        } else {
            # consider 'behind' or 'diverged' as needing rebase
            if ($compare.status -eq "behind" -or $compare.status -eq "diverged") {
                $needsRebase += @{
                    owner = $owner
                    repo = $repoName
                    pr_number = $PRNumber
                    pr_url = "https://github.com/$owner/$repoName/pull/$PRNumber"
                    reason = $compare.status
                    head_sha = $triggerPr.head.sha
                }                
                Write-Output "Triggering PR requires rebase (status=$($compare.status))."
            } else {
                Write-Output "Triggering PR OK (status=$($compare.status))."
            }
        }
    } catch {
        Write-Output "Warning: failed to retrieve/compare triggering PR: $_"
    }

    # For each submodule entry: try to find an open PR in owner/subRepo with head = owner:branch and compare it
    foreach ($sub in $submoduleBranches.PSObject.Properties) {
        $subRepo = $sub.Name
        $branchName = $sub.Value.branchName
        Write-Output "Checking submodule repo $subRepo for branch $branchName"

        # Find open PR(s) with head owner:branchName
        $searchPrsUrl = "https://api.github.com/repos/$owner/$subRepo/pulls?head=$owner`:$([System.Uri]::EscapeDataString($branchName))&state=open"
        try {
            $foundPrs = Invoke-RestMethod -Method Get -Uri $searchPrsUrl -Headers $headers
        } catch {
            Write-Output "Failed to list PRs for ${owner}/${subRepo} with head ${owner}:${branchName} : $_"
            $foundPrs = @()
        }

        if ($foundPrs -and $foundPrs.Count -gt 0) {
            foreach ($pr in $foundPrs) {
                $subPrNumber = $pr.number
                $subPrBase = $pr.base.ref
                $subPrHead = $pr.head.ref
                Write-Output "Found PR #$subPrNumber in $owner/$subRepo (base=$subPrBase head=$subPrHead)."

                $compareSub = Compare-Branches -owner $owner -repo $subRepo -baseRef $subPrBase -headRef $subPrHead
                if ($null -eq $compareSub) {
                    Write-Output "Could not compare $owner/$subRepo PR #$subPrNumber; skipping."
                    continue
                }

                if ($compareSub.status -eq "behind" -or $compareSub.status -eq "diverged") {
                    $needsRebase += @{
                        owner = $owner
                        repo = $subRepo
                        pr_number = $subPrNumber
                        pr_url = "https://github.com/$owner/$subRepo/pull/$subPrNumber"
                        reason = $compareSub.status
                        head_sha = $pr.head.sha
                    }                    
                    Write-Output "Submodule PR requires rebase: $owner/$subRepo#${subPrNumber} (status=$($compareSub.status))."
                } else {
                    Write-Output "Submodule PR OK (status=$($compareSub.status))."
                }
            }
        } else {
            Write-Output "No open PR found for ${owner}/${subRepo} with head ${owner}:${branchName}. Skipping."
        }
    }

    # If any need rebase, post a comment on triggering PR and exit
    if ($needsRebase.Count -gt 0) {
        $commentLines = @()
        $commentLines += "### Workflow Trigger Blocked"
        $commentLines += ""
        $commentLines += "One or more related pull requests need to be rebased before this workflow can proceed."
        $commentLines += ""

        foreach ($item in $needsRebase) {
            if ($null -ne $item.head_sha -and $item.head_sha.Length -ge 7) {
                $shaShort = $item.head_sha.Substring(0,7)
            } else {
                $shaShort = "unknown"
            }

            # use format operator to avoid concatenation parsing issues
            $line = ('- {0}/{1}#{2} - status: **{3}** - head: `{4}`' -f $item.owner, $item.repo, $item.pr_number, $item.reason, $shaShort)
            $commentLines += $line
        }

        $commentLines += ""
        $commentLines += "Please rebase the affected PR(s) onto their base branches and push the updated commits. Once updated, you can trigger it normally."
        $commentLines += ""
        $commentBody = ($commentLines -join "`r`n")

        # --- Avoid posting duplicate comments ---
        $commentsUrl = "https://api.github.com/repos/$owner/$repoName/issues/$PRNumber/comments"
        try {
            Write-Output "Checking existing comments to avoid duplicates..."
            $existingComments = Invoke-RestMethod -Method Get -Uri $commentsUrl -Headers $headers
            $existingMatch = $existingComments | Where-Object { $_.body -eq $commentBody }

            if ($existingMatch) {
                Write-Output "Identical rebase warning comment already exists on PR. Skipping duplicate comment."
            } else {
                Write-Output "Posting new rebase warning comment to $owner/$repoName#${PRNumber}..."
                $bodyJson = @{ body = $commentBody } | ConvertTo-Json -Depth 3
                Invoke-RestMethod -Method Post -Uri $commentsUrl -Headers $headers -Body $bodyJson -ContentType "application/json"
                Write-Output "Comment posted successfully."
            }
        } catch {
            Write-Output "WARNING: Failed to check or post comment on triggering PR: $_"
        }

        Write-Output "Exiting with code 1 because one or more PRs require rebase."
        exit 1
    }
}

Write-Output "All related PRs OK - proceeding to build payload and send dispatch."

# Build the base payload
Write-Output "Building payload..."
$payload = @{
    "branch_name"       = $PRBranch
    "sha_num"           = $PRSha
    "repo_name"         = $repoName
    "pull_request_name" = $PRTitle
    "pull_request_num"  = $PRNumber
}

# Add normalized submodule info to the payload
Write-Output "Adding submodule branches to payload..."
foreach ($sub in $submoduleBranches.PSObject.Properties) {
    $payload[$sub.Name] = @{
        branch_name = $sub.Value.branchName
        commit_hash = $sub.Value.commitHash
    }
    Write-Output "Added submodule: $($sub.Name) with branch=$($sub.Value.branchName), commit=$($sub.Value.commitHash)"
}

# Construct the dispatch body
$body = @{
    "event_type"     = $EventType
    "client_payload" = $payload
} | ConvertTo-Json -Compress

Write-Output "Final dispatch body: $body"

# Send the dispatch request
Write-Output "Sending dispatch to $DispatchUrl..."
try {
    $response = Invoke-WebRequest -Uri $DispatchUrl `
                                 -Method Post `
                                 -Headers $headers `
                                 -Body $body `
                                 -ContentType "application/json" `
                                 -ErrorAction Stop

    Write-Output "Dispatch request successful. Response status: $($response.StatusCode) $($response.StatusDescription)"
} catch {
    Write-Output "ERROR: Failed to send dispatch request. Error: $_"
    Write-Output "Reason: $_"
    if ($_.Exception.Response) {
        Write-Output "Response: $($_.Exception.Response | ConvertTo-Json -Depth 5 -Compress)"
    }
    exit 1
}
