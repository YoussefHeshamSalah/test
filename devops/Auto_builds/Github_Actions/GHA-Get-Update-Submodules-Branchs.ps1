<#
.SYNOPSIS
    Updates Git submodules by aligning them with branches specified in the event payload or .gitmodules.

.DESCRIPTION
    This script processes a GitHub event (e.g., repository_dispatch) to update submodules, including nested ones,
    by recursively parsing .gitmodules files. It uses the repository name from the URL to identify submodules and
    determines the target branch from the event payload, .gitmodules, or the remote's default branch.
#>

param (
    [string]$EventPath = $env:GITHUB_EVENT_PATH
)

# Load the event data from the GitHub event file
$event = Get-Content $EventPath | ConvertFrom-Json

# Function to recursively collect all submodules with their repository names and specified branches
function Get-AllSubmodules {
    param (
        [string]$currentPath = "."
    )

    $submodules = @()
    $gitmodulesPath = Join-Path $currentPath ".gitmodules"

    if (Test-Path $gitmodulesPath) {
        $submoduleData = git config --file $gitmodulesPath --get-regexp "submodule\..*\.path" | 
                         ForEach-Object { 
                             $key = ($_ -split "\.path")[0]
                             $path = ($_ -split " ")[1]
                             $url = git config --file $gitmodulesPath --get "$key.url"
                             $repoName = if ($url) { ($url -split '/')[-1] -replace '\.git$', '' } else { $null }
                             $branch = git config --file $gitmodulesPath --get "$key.branch"
                             $fullPath = Join-Path $currentPath $path
                             [PSCustomObject]@{
                                RepoName = $repoName
                                FullPath = $fullPath
                                SpecifiedBranch = $branch
                             }
                         }

        foreach ($sub in $submoduleData) {
            $submodules += $sub
            $nestedSubmodules = Get-AllSubmodules -currentPath $sub.FullPath
            $submodules += $nestedSubmodules
        }
    }

    return $submodules
}

# Get all submodules, including nested ones
$allSubmodules = Get-AllSubmodules

# Check if any submodules were found
if (-not $allSubmodules) {
    Write-Error "No submodules found in any .gitmodules files!"
    exit 1
}

Write-Output "Found submodules (including nested): $($allSubmodules.RepoName -join ', ')"

# Store the original directory path
$OriginalPath = Get-Location
Write-Output "Stored the original path: $OriginalPath"

# Process each submodule
foreach ($sub in $allSubmodules) {
    $repoName = $sub.RepoName
    $subPath = $sub.FullPath
    $specifiedBranch = $sub.SpecifiedBranch

    Write-Output "Event type: $($env:GITHUB_EVENT_NAME)"

    # Determine the branch input from the event payload
    $branchInput = $null
    if ($env:GITHUB_EVENT_NAME -eq 'repository_dispatch') {
        $triggerRepoName = $event.client_payload.repo_name
        if ($repoName -eq $triggerRepoName) {
            $branchInput = $event.client_payload.branch_name
            Write-Output "Matched repo_name '$triggerRepoName', using branch: $branchInput"
        } else {
            $branchInput = $event.client_payload.$repoName.branch_name
            if ($branchInput) {
                Write-Output "Found specific branch for '$repoName': $branchInput"
            }
        }
    } else {
        $branchInput = $event.inputs.$repoName
        if ($branchInput) {
            Write-Output "Found branch for '$repoName' in inputs: $branchInput"
        }
    }

    # Change to the submodule directory
    Set-Location -Path $subPath

    # If no branch is specified in the payload, use the branch from .gitmodules or the remote's default
    if (-not $branchInput) {
        if ($specifiedBranch) {
            $branchInput = $specifiedBranch
            Write-Output "Using branch specified in .gitmodules: $branchInput"
        } else {
            $defaultBranch = (git remote show origin | Select-String "HEAD branch").ToString().Split(":")[1].Trim()
            $branchInput = $defaultBranch
            Write-Output "No branch specified in .gitmodules, using remote's default branch: $defaultBranch"
        }
    }

    # Clean and reset the submodule to ensure a fresh state
    git clean -fdx
    git reset --hard HEAD
    
    # Fetch the latest data from the remote repository
    git fetch origin

    # Check out or create the target branch
    if (git branch --list $branchInput) {
        git checkout $branchInput
        git reset --hard origin/$branchInput
        Write-Output "Checked out and reset branch '$branchInput' for '$repoName'"
    } else {
        git checkout -b $branchInput origin/$branchInput
        Write-Output "Created and checked out branch '$branchInput' for '$repoName'"
    }

    # Return to the original directory
    Set-Location -Path $OriginalPath
    Write-Output "Returned to original path: $OriginalPath"
}
