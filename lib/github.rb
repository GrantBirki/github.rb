# frozen_string_literal: true

# This class provides a comprehensive wrapper around the Octokit client for GitHub App authentication.
# It handles token generation and refreshing, built-in retry logic, rate limiting, and delegates method calls to the Octokit client.
# Helpful: https://github.com/octokit/handbook?tab=readme-ov-file#github-app-authentication-json-web-token

# Why? In some cases, you may not want to have a static long lived token like a GitHub PAT when authenticating...
# with octokit.rb.
# Most importantly, this class will handle automatic token refreshing, retries, and rate limiting for you out-of-the-box.
# Simply provide the correct environment variables, call `GitHub.new`, and then use the returned object as you would an Octokit client.

# Note: Environment variables have the `GH_` prefix because in GitHub Actions, you cannot use `GITHUB_` for secrets

require "octokit"
require "jwt"
require "redacting_logger"

class GitHub
  TOKEN_EXPIRATION_TIME = 2700 # 45 minutes
  JWT_EXPIRATION_TIME = 600 # 10 minutes

  # Initializes a new GitHub App client with authentication and configuration
  #
  # @param log [Logger, nil] Custom logger instance. If nil, creates a RedactingLogger with level from GH_APP_LOG_LEVEL env var (default: INFO)
  # @param app_id [Integer, nil] GitHub App ID from the App's settings page. If nil, reads from GH_APP_ID env var
  # @param installation_id [Integer, nil] Installation ID from the organization's installations page. If nil, reads from GH_APP_INSTALLATION_ID env var
  # @param app_key [String, nil] Private key for the GitHub App. Can be:
  #   - File path ending in .pem (will read from file)
  #   - Key string with \n escape sequences (will be normalized)
  #   - nil (will read from GH_APP_KEY env var)
  # @param app_algo [String, nil] JWT signing algorithm. If nil, reads from GH_APP_ALGO env var (default: RS256)
  #
  # @raise [RuntimeError] If required environment variables are not set when parameters are nil
  # @raise [RuntimeError] If app_key file path is provided but file doesn't exist or is empty
  #
  # @example Basic usage with environment variables
  #   # Set environment variables: GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_KEY
  #   github = GitHub.new
  #
  # @example Usage with explicit parameters
  #   github = GitHub.new(
  #     app_id: 12345,
  #     installation_id: 87654321,
  #     app_key: "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
  #   )
  #
  # @example Usage with key file
  #   github = GitHub.new(
  #     app_id: 12345,
  #     installation_id: 87654321,
  #     app_key: "/path/to/private-key.pem"
  #   )
  #
  # @note Installation IDs can be found at: https://github.com/organizations/<org>/settings/installations/<8_digit_id>
  # @note App keys should be downloaded from the App's settings page in PEM format
  # @note When using environment variables for keys, ensure newlines are escaped as \n in a single line string
  def initialize(log: nil, app_id: nil, installation_id: nil, app_key: nil, app_algo: nil)
    @log = log || create_default_logger

    # app ids are found on the App's settings page
    @app_id = app_id || fetch_env_var("GH_APP_ID").to_i

    # installation ids look like this:
    # https://github.com/organizations/<org>/settings/installations/<8_digit_id>
    @installation_id = installation_id || fetch_env_var("GH_APP_INSTALLATION_ID").to_i

    # app keys are found on the App's settings page and can be downloaded
    # format: "-----BEGIN...key\n...END-----\n"
    # make sure this key in your env is a single line string with newlines as "\n"
    @app_key = resolve_app_key(app_key)

    @app_algo = app_algo || ENV.fetch("GH_APP_ALGO", "RS256")

    @client = nil
    @token_refresh_time = nil
    @rate_limit_all = nil

    setup_retry_config!
  end

  # Checks the client's current rate limit status and blocks if the rate limit is hit
  #
  # This method will sleep for the remaining time until the rate limit resets if the rate limit is exceeded.
  # It automatically fetches fresh rate limit data and handles edge cases like negative remaining counts.
  #
  # @param type [Symbol] The type of rate limit to check (:core, :search, :graphql, etc.)
  # @return [void] This method blocks until the rate limit is reset for the given type
  #
  # @example Check core API rate limit before making requests
  #   github = GitHub.new
  #   github.wait_for_rate_limit!(:core)
  #   repos = github.repos
  #
  # @example Check search API rate limit before searching
  #   github = GitHub.new
  #   github.wait_for_rate_limit!(:search)
  #   results = github.search_issues("is:open repo:owner/name")
  #
  # @note This method will log debug information about rate limit status
  # @note Checking rate limit status does not count against any rate limits
  def wait_for_rate_limit!(type = :core)
    @log.debug("checking rate limit status for type: #{type}")
    # make a request to get the comprehensive rate limit status
    # note: checking the rate limit status does not count against the rate limit in any way
    fetch_rate_limit if @rate_limit_all.nil?

    details = rate_limit_details(type)
    rate_limit = details[:rate_limit]
    resets_at = details[:resets_at]

    @log.debug(
      "rate_limit remaining: #{rate_limit[:remaining]} - " \
      "used: #{rate_limit[:used]} - " \
      "resets_at: #{resets_at} - " \
      "current time: #{Time.now}"
    )

    # exit early if the rate limit is not hit (we have remaining requests)
    unless rate_limit[:remaining].zero?
      update_rate_limit(type)
      return
    end

    # if we make it here, we (probably) have hit the rate limit
    # fetch the rate limit again if we are at zero or if the rate limit reset time is in the past
    fetch_rate_limit if rate_limit[:remaining].zero? || rate_limit[:remaining] < 0 || resets_at < Time.now

    details = rate_limit_details(type)
    rate_limit = details[:rate_limit]
    resets_at = details[:resets_at]

    # exit early if the rate limit is not actually hit (we have remaining requests)
    unless rate_limit[:remaining].zero?
      @log.debug("rate_limit not hit - remaining: #{rate_limit[:remaining]}")
      update_rate_limit(type)
      return
    end

    # calculate the sleep duration - ex: reset time - current time
    sleep_duration = resets_at - Time.now
    @log.debug("sleep_duration: #{sleep_duration}")
    sleep_duration = [sleep_duration, 0].max # ensure sleep duration is not negative
    sleep_duration_and_a_little_more = sleep_duration.ceil + 2 # sleep a little more than the rate limit reset time

    # log the sleep duration and begin the blocking sleep call
    @log.info("github rate_limit hit: sleeping for: #{sleep_duration_and_a_little_more} seconds")
    sleep(sleep_duration_and_a_little_more)

    @log.info("github rate_limit sleep complete - Time.now: #{Time.now}")
  end

  private

  # Creates a default logger if none is provided during initialization
  #
  # Creates a RedactingLogger instance that writes to stdout with a configurable log level.
  # The log level can be controlled via the GH_APP_LOG_LEVEL environment variable.
  #
  # @return [RedactingLogger] A new logger instance configured for GitHub API operations
  # @api private
  def create_default_logger
    RedactingLogger.new($stdout, level: ENV.fetch("GH_APP_LOG_LEVEL", "INFO").upcase)
  end

  # Sets up retry configuration for handling API errors
  #
  # Configures retry behavior based on environment variables. If the maximum number of retries
  # is reached without success, the last exception will be raised.
  #
  # Environment variables used:
  # - GH_APP_SLEEP: Base sleep time between retries (default: 3 seconds)
  # - GH_APP_RETRIES: Maximum number of retry attempts (default: 10)
  # - GH_APP_EXPONENTIAL_BACKOFF: Enable exponential backoff (default: false)
  #
  # @return [void]
  # @api private
  def setup_retry_config!
    @retry_sleep = ENV.fetch("GH_APP_SLEEP", 3).to_i
    @retry_tries = ENV.fetch("GH_APP_RETRIES", 10).to_i
    @retry_exponential_backoff = ENV.fetch("GH_APP_EXPONENTIAL_BACKOFF", "false").downcase == "true"
  end

  # Custom retry logic with optional exponential backoff and logging
  #
  # Executes the provided block with configurable retry logic. Supports both fixed-rate
  # and exponential backoff retry strategies with detailed logging of retry attempts.
  #
  # @param retries [Integer] Number of retries to attempt (uses instance default if not specified)
  # @param sleep_time [Integer] Base sleep time between retries in seconds (uses instance default if not specified)
  # @param block [Proc] The block to execute with retry logic
  # @return [Object] The result of the successful block execution
  # @raise [StandardError] The last exception encountered if all retries are exhausted
  #
  # @example Retry with exponential backoff enabled
  #   # When exponential backoff is enabled:
  #   # 1st retry: 3 seconds
  #   # 2nd retry: 6 seconds
  #   # 3rd retry: 12 seconds
  #   # 4th retry: 24 seconds
  #
  # @example Retry with fixed rate (default)
  #   # When exponential backoff is disabled:
  #   # All retries: 3 seconds (fixed rate)
  #
  # @api private
  def retry_request(retries: @retry_tries, sleep_time: @retry_sleep, &block)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue StandardError => e
      if attempt < retries
        if @retry_exponential_backoff
          backoff_time = sleep_time * (2**(attempt - 1)) # Exponential backoff
        else
          backoff_time = sleep_time # Fixed rate
        end
        @log.debug("[retry ##{attempt}] #{e.class}: #{e.message} - sleeping #{backoff_time}s before retry")
        sleep(backoff_time)
        retry
      else
        @log.debug("[retry ##{attempt}] #{e.class}: #{e.message} - max retries exceeded")
        raise e
      end
    end
  end

  # Fetches the current rate limit status from the GitHub API
  #
  # Makes a request to the GitHub rate limit endpoint to get comprehensive rate limit
  # information for all API types (core, search, graphql, etc). This request does not
  # count against any rate limits.
  #
  # @return [Hash] The complete rate limit response from GitHub API
  # @api private
  def fetch_rate_limit
    @rate_limit_all = retry_request do
      client.get("rate_limit")
    end
  end

  # Updates the in-memory cached rate limit value for the given rate limit type
  #
  # Decrements the remaining count for the specified rate limit type to keep the
  # local cache in sync with actual API usage without making additional API calls.
  #
  # @param type [Symbol] The rate limit type to update (:core, :search, :graphql, etc.)
  # @return [void]
  # @api private
  def update_rate_limit(type)
    @rate_limit_all[:resources][type][:remaining] -= 1
  end

  # Extracts rate limit details for a specific rate limit type
  #
  # Processes the cached rate limit data to extract information for a specific type
  # and calculates the reset time as a Time object.
  #
  # @param type [Symbol] The rate limit type to get details for (:core, :search, :graphql, etc.)
  # @return [Hash] A hash containing:
  #   - :rate_limit [Hash] Rate limit data with :limit, :used, :remaining, :reset keys
  #   - :resets_at [Time] UTC time when the rate limit will reset
  # @api private
  def rate_limit_details(type)
    # fetch the provided rate limit type
    # rate_limit resulting structure: {:limit=>5000, :used=>15, :remaining=>4985, :reset=>1713897293}
    rate_limit = @rate_limit_all[:resources][type]

    # calculate the time the rate limit will reset
    resets_at = Time.at(rate_limit[:reset]).utc

    return {
      rate_limit: rate_limit,
      resets_at: resets_at,
    }
  end

  private

  # Fetches the value of an environment variable and raises an error if it is not set
  #
  # Provides a consistent way to fetch required environment variables with clear error
  # messages when they are missing.
  #
  # @param key [String] The name of the environment variable to fetch
  # @return [String] The value of the environment variable
  # @raise [RuntimeError] If the environment variable is not set
  # @api private
  def fetch_env_var(key)
    ENV.fetch(key) { raise "environment variable #{key} is not set" }
  end

  # Resolves the GitHub App private key from various sources
  #
  # Handles multiple input formats for the GitHub App private key:
  # - File path ending in .pem (reads from file system)
  # - Key string with escape sequences (normalizes \n sequences)
  # - nil (falls back to GH_APP_KEY environment variable)
  #
  # @param app_key [String, nil] The app key parameter from initialization
  # @return [String] The resolved and normalized private key content
  # @raise [RuntimeError] If app_key file path is provided but file doesn't exist
  # @raise [RuntimeError] If app_key file path is provided but file is empty
  # @raise [RuntimeError] If GH_APP_KEY environment variable is not set when app_key is nil
  # @api private
  def resolve_app_key(app_key)
    # If app_key is provided as a parameter
    if app_key
      # Check if it's a file path (ends with .pem)
      if app_key.end_with?(".pem")
        unless File.exist?(app_key)
          raise "App key file not found: #{app_key}"
        end

        @log.debug("Loading app key from file: #{app_key}")
        key_content = File.read(app_key)

        if key_content.strip.empty?
          raise "App key file is empty: #{app_key}"
        end

        @log.debug("Successfully loaded app key from file (#{key_content.length} characters)")
        return key_content
      else
        # It's a key string, process escape sequences
        @log.debug("Using provided app key string")
        return normalize_key_string(app_key)
      end
    end

    # Fall back to environment variable
    @log.debug("Loading app key from environment variable")
    env_key = fetch_env_var("GH_APP_KEY")
    normalize_key_string(env_key)
  end

  # Normalizes escape sequences in private key strings safely
  #
  # Converts literal \n sequences to actual newline characters in private key strings.
  # Uses simple string replacement to avoid ReDoS (Regular Expression Denial of Service)
  # vulnerabilities while handling both single \n and multiple consecutive \\n sequences.
  #
  # @param key_string [String] The private key string containing escape sequences
  # @return [String] The normalized private key string with actual newline characters
  # @api private
  def normalize_key_string(key_string)
    # Use simple string replacement to avoid ReDoS vulnerability
    # This handles both single \n and multiple consecutive \\n sequences
    key_string.gsub('\\n', "\n")
  end

  # Gets or creates the authenticated Octokit client with automatic token management
  #
  # Returns a cached Octokit client instance or creates a new one if the current client
  # is nil or the authentication token has expired. Handles automatic token refresh
  # to ensure the client always has valid authentication.
  #
  # @return [Octokit::Client] An authenticated Octokit client ready for API calls
  # @api private
  def client
    if @client.nil? || token_expired?
      @client = create_client
    end

    @client
  end

  # Generates a JWT token for GitHub App authentication
  #
  # Creates a JSON Web Token (JWT) signed with the GitHub App's private key for
  # authenticating as the GitHub App itself. The token is valid for 10 minutes
  # (GitHub's maximum) and includes clock drift protection.
  #
  # @return [String] A signed JWT token for GitHub App authentication
  # @raise [OpenSSL::PKey::RSAError] If the private key is invalid or malformed
  # @api private
  def jwt_token
    private_key = OpenSSL::PKey::RSA.new(@app_key)

    payload = {}.tap do |opts|
      opts[:iat] = Time.now.to_i - 60 # issued at time, 60 seconds in the past to allow for clock drift
      opts[:exp] = opts[:iat] + JWT_EXPIRATION_TIME # JWT expiration time (10 minute maximum)
      opts[:iss] = @app_id # GitHub App ID
    end

    JWT.encode(payload, private_key, @app_algo)
  end

  # Creates a new authenticated Octokit client with installation access token
  #
  # Performs the GitHub App authentication flow:
  # 1. Creates a temporary client with JWT token
  # 2. Uses that client to generate an installation access token
  # 3. Creates the final client with the installation access token
  # 4. Configures pagination settings for optimal API usage
  #
  # @return [Octokit::Client] A fully configured and authenticated Octokit client
  # @api private
  def create_client
    client = ::Octokit::Client.new(bearer_token: jwt_token)
    access_token = client.create_app_installation_access_token(@installation_id)[:token]
    client = ::Octokit::Client.new(access_token:)
    client.auto_paginate = true
    client.per_page = 100
    @token_refresh_time = Time.now
    client
  end

  # Checks if the current GitHub App installation access token has expired
  #
  # GitHub App installation access tokens expire after 1 hour. This method is
  # conservative and considers tokens expired after 45 minutes to account for
  # clock drift and provide a safety margin.
  #
  # @return [Boolean] true if the token has expired or no token exists, false otherwise
  # @api private
  def token_expired?
    @token_refresh_time.nil? || (Time.now - @token_refresh_time) > TOKEN_EXPIRATION_TIME
  end

  # Delegates method calls to the underlying Octokit client with built-in enhancements
  #
  # This method enables the GitHub wrapper to act as a drop-in replacement for Octokit::Client
  # while adding automatic retry logic, rate limiting, and special handling for certain endpoints.
  # It intelligently determines the appropriate rate limit type and applies method-specific logic.
  #
  # @param method [Symbol] The name of the method being called
  # @param args [Array] The arguments passed to the method
  # @param kwargs [Hash] The keyword arguments passed to the method
  # @param block [Proc] An optional block passed to the method
  # @return [Object] The result of the method call on the underlying Octokit client
  # @raise [StandardError] Any exception from the underlying API call after retries are exhausted
  #
  # @example Using any Octokit method with automatic enhancements
  #   github = GitHub.new
  #
  #   # Core API calls (automatic rate limiting and retries)
  #   repos = github.repos
  #   issues = github.issues("owner/repo")
  #
  #   # Search API calls (special rate limit handling)
  #   results = github.search_issues("is:open repo:owner/name")
  #
  #   # Disable retry for specific calls
  #   github.create_issue("owner/repo", "Title", "Body", disable_retry: true)
  #
  # @note Special handling for search_issues includes secondary rate limit protection
  # @note The disable_retry keyword argument can be used to skip retry logic for any method
  def method_missing(method, *args, **kwargs, &block)
    # Check if retry is explicitly disabled for this call
    disable_retry = kwargs.delete(:disable_retry) || false

    # Determine the rate limit type based on the method name and arguments
    rate_limit_type = case method.to_s
                      when /search_/
                        :search
                      when /graphql/
                        # :nocov:
                        :graphql # I don't actually know of any endpoints that match this method sig yet
                        # :nocov:
                      else
                        # Check if this is a GraphQL call via POST
                        if method.to_s == "post" && args.first&.include?("/graphql")
                          :graphql
                        else
                          :core
                        end
                      end

    # Handle special case for search_issues which can hit secondary rate limits
    if method.to_s == "search_issues"
      request_proc = proc do
        wait_for_rate_limit!(rate_limit_type)
        client.send(method, *args, **kwargs, &block) # rubocop:disable GitHub/AvoidObjectSendWithDynamicMethod
      end

      begin
        if disable_retry
          request_proc.call
        else
          retry_request(&request_proc)
        end
      rescue StandardError => e
        # re-raise the error but if its a secondary rate limit error, just sleep for a minute
        if e.message.include?("exceeded a secondary rate limit")
          @log.warn("GitHub secondary rate limit hit, sleeping for 60 seconds")
          sleep(60)
        end
        raise e
      end
    else
      # For all other methods, use standard retry and rate limiting
      request_proc = proc do
        wait_for_rate_limit!(rate_limit_type)
        client.send(method, *args, **kwargs, &block) # rubocop:disable GitHub/AvoidObjectSendWithDynamicMethod
      end

      if disable_retry
        request_proc.call
      else
        retry_request(&request_proc)
      end
    end
  end

  # Determines if the GitHub wrapper responds to a given method
  #
  # This method ensures that the GitHub wrapper correctly reports whether it can handle
  # a method call by checking if the underlying Octokit client responds to the method.
  # This is essential for proper method delegation and introspection.
  #
  # @param method [Symbol] The name of the method being checked
  # @param include_private [Boolean] Whether to include private methods in the check
  # @return [Boolean] true if the underlying Octokit client responds to the method, false otherwise
  #
  # @example Check if a method is available
  #   github = GitHub.new
  #   github.respond_to?(:repos)           # => true
  #   github.respond_to?(:search_issues)   # => true
  #   github.respond_to?(:nonexistent)     # => false
  def respond_to_missing?(method, include_private = false)
    client.respond_to?(method, include_private) || super
  end
end
