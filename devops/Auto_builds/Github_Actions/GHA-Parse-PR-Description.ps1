<#
.SYNOPSIS
    Extracts and verifies related pull request URLs from a GitHub pull request description.

.DESCRIPTION
    This script processes a GitHub pull request body from a GitHub Actions event to identify URLs listed under 
    a "This PR connects with:" section. It filters for valid PR URLs, checks if each PR is open using the GitHub API, 
    and compiles an array of open PRs with their repository names and PR numbers. The result is output as a compressed 
    JSON string to $env:GITHUB_OUTPUT for use in a GitHub Actions workflow.
#>

# Load PR body from GitHub event data
$event = Get-Content $env:GITHUB_EVENT_PATH | ConvertFrom-Json
$prBody = $event.pull_request.body

# Initialize array for related PRs
$relatedPRs = @()

# Extract section after "This PR connects with:"
$relatedSection = $prBody -split "This PR connects with:" | Select-Object -Skip 1

if ($relatedSection) {
    # Filter for lines starting with "- http" and extract URLs
    $urls = ($relatedSection -split "`n" | Where-Object { $_.Trim().StartsWith("- http") } | ForEach-Object { $_.Trim().Substring(2).Trim() })
    
    if ($urls) {
        Write-Output "Found $($urls.Count) PR URL(s): $($urls -join ', ')"
        
        # Set up headers for GitHub API requests
        $headers = @{
            Authorization = "token $env:GITHUB_TOKEN"
            Accept = "application/vnd.github.v3+json"
        }

        # Process each URL
        foreach ($url in $urls) {
            Write-Output "Processing URL: $url"
            
            # Parse URL to extract repo and PR number
            $parts = $url -split "/"
            $repo = $parts[3] + "/" + $parts[4]  # owner/repo
            $prNumber = $parts[6]
            Write-Output "Parsed URL: repo=$repo, prNumber=$prNumber"
            
            # Check PR status via GitHub API
            $apiUrl = "https://api.github.com/repos/$repo/pulls/$prNumber"
            Write-Output "Checking PR status via API: $apiUrl"
            try {
                $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
                Write-Output "API response received for PR $repo #$prNumber, state: $($response.state)"
                if ($response.state -eq "open") {
                    $relatedPRs += @{ repo = $repo; prNumber = $prNumber }
                    Write-Output "Added open PR $repo #$prNumber to relatedPRs"
                } else {
                    Write-Output "PR $repo #$prNumber is not open (state: $($response.state)), skipping"
                }
            } catch {
                Write-Output "Error checking PR $($repo) #$($prNumber): $($_.Exception.Message)"
            }
        }

        # Log results
        if ($relatedPRs.Count -gt 0) {
            Write-Output "Found $($relatedPRs.Count) related open PR(s): $($relatedPRs | ConvertTo-Json -Compress)"
        } else {
            Write-Output "No related open PRs found."
        }
    } else {
        Write-Output "No related PR URLs found in description."
    }
} else {
    Write-Output "No 'This PR connects with:' section found in PR description."
}

# Output compressed JSON to GITHUB_OUTPUT
$relatedPRsJson = $relatedPRs | ConvertTo-Json -Compress
Write-Output "relatedPRs=$relatedPRsJson" >> $env:GITHUB_OUTPUT
