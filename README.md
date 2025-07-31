# github.rb 🧰

[![test](https://github.com/GrantBirki/github.rb/actions/workflows/test.yml/badge.svg)](https://github.com/GrantBirki/github.rb/actions/workflows/test.yml)
[![lint](https://github.com/GrantBirki/github.rb/actions/workflows/lint.yml/badge.svg)](https://github.com/GrantBirki/github.rb/actions/workflows/lint.yml)

## About ⭐

A light weight wrapper around octokit.rb for common GitHub related operations

## Usage 💻

This library provides a comprehensive wrapper around the Octokit client for GitHub App authentication with automatic token refreshing, built-in retry logic, and rate limiting.

## Why would I want to use this? 💡

You might want to copy/paste the [`lib/github.rb`](lib/github.rb) file into your project to hydrate an instance of [`octokit.rb`](https://github.com/octokit/octokit.rb) if you want the following:

1. **You want to use GitHub App authentication**: This library handles the JWT token generation and refreshing automatically.
2. **You want built-in retry logic**: It retries requests that fail due to rate limits or other transient errors (optionally with exponential backoff). You can also bypass this if you want to handle retries yourself.
3. **You want to use any Octokit method**: This library delegates all methods to the underlying Octokit client, so you can use it just like you would with Octokit.
4. **You want to avoid boilerplate code**: It simplifies the setup process for using Octokit with GitHub Apps, reducing the amount of code you need to write. Yay copy/paste!
5. **You want to handle rate limits automatically**: It waits for the appropriate time when rate limits are hit, so you don't have to manage this manually.

### Basic Usage 🔨

```ruby
require_relative "path/to/github" # the relative path to the github.rb file

# Using environment variables
github = GitHub.new

# Using explicit parameters
github = GitHub.new(
  app_id: 12345,
  installation_id: 87654321,
  app_key: "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
)

# Using a key file
github = GitHub.new(
  app_id: 12345,
  installation_id: 87654321,
  app_key: "/path/to/private-key.pem"
)

# Use like any Octokit client
repos = github.repos
issues = github.search_issues("repo:owner/name is:open")

# Disabling automatic retries for a single request
issues = github.search_issues("repo:owner/name is:open", disable_retry: true)
```

### Environment Variables

Set these environment variables for authentication:

```bash
export GH_APP_ID="12345"                           # GitHub App ID (required)
export GH_APP_INSTALLATION_ID="87654321"           # Installation ID (required)
export GH_APP_KEY="-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"  # Private key (required)
```

Optional configuration:

```bash
export GH_APP_ALGO="RS256"                         # JWT algorithm (default: RS256)
export GH_APP_LOG_LEVEL="INFO"                     # Log level (default: INFO)
export GH_APP_SLEEP="3"                           # Retry sleep time in seconds (default: 3)
export GH_APP_RETRIES="10"                        # Number of retries (default: 10)
export GH_APP_EXPONENTIAL_BACKOFF="false"         # Enable exponential backoff (default: false)
```

### Key Features

- **Automatic token refresh**: Handles GitHub App token expiration automatically
- **Built-in retries**: Configurable retry logic with optional exponential backoff
- **Rate limit handling**: Automatically waits when rate limits are hit
- **Method delegation**: Use any Octokit method directly on the GitHub instance
