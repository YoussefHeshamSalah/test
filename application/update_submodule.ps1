# Define input parameters
param (
    [string]$EventName,
    [string]$RepoName,
    [string]$BranchName
)

# Determine the submodule name
$SubmoduleName = ""
if ($EventName -eq "repository_dispatch") {
    $SubmoduleName = $RepoNames
} elseif ($EventName -eq "workflow_dispatch") {
    $SubmoduleName = $RepoName
}

# Get submodule path
$SubmodulePath = git config --file .gitmodules --get-regexp path | Where-Object {$_ -match $SubmoduleName} | ForEach-Object { ($_ -split " ")[1] }

if (-not $SubmodulePath) {
    Write-Error "Submodule '$SubmoduleName' not found!"
    exit 1
}

Write-Output "Submodule '$SubmoduleName' is located at: $SubmodulePath"

# Change directory to the submodule
Set-Location $SubmodulePath

git fetch origin

# Determine the branch name
if ($EventName -eq "repository_dispatch") {
    $BranchName = $BranchName
} elseif ($EventName -eq "workflow_dispatch") {
    $BranchName = $BranchName
}

# Check out the branch
if (git branch --list $BranchName) {
    git checkout $BranchName
    git pull origin $BranchName
} else {
    git checkout -b $BranchName origin/$BranchName
}
