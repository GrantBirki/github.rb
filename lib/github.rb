# frozen_string_literal: true

require "jwt"
require "octokit"
require "openssl"
require "redacting_logger"
require "time"

# A small GitHub App authentication wrapper around Octokit.
#
# GitHub App installation access tokens are intentionally treated as opaque
# strings. Do not decode them, validate their shape, or assume a fixed length.
class GitHub
  TOKEN_EXPIRATION_TIME = 2700
  JWT_EXPIRATION_TIME = 600
  TOKEN_REFRESH_BUFFER = 300
  DEFAULT_PER_PAGE = 100
  SECONDARY_RATE_LIMIT_SLEEP = 60
  DEFAULT_RETRY_SLEEP = 3
  DEFAULT_RETRY_TRIES = 10

  TRANSIENT_ERROR_CLASSES = [
    Octokit::ServerError,
    Octokit::TooManyRequests,
    Faraday::TimeoutError,
    Faraday::ConnectionFailed,
    EOFError,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
  ].freeze

  # Initializes a new GitHub App client with authentication and retry settings.
  #
  # @param log [Logger, nil] Custom logger. Defaults to a RedactingLogger.
  # @param app_id [Integer, String, nil] GitHub App ID. Defaults to GH_APP_ID.
  # @param installation_id [Integer, String, nil] GitHub App installation ID. Defaults to GH_APP_INSTALLATION_ID.
  # @param app_key [String, nil] PEM private key content, escaped PEM content, or a .pem file path. Defaults to GH_APP_KEY.
  # @param app_algo [String, nil] JWT signing algorithm. Defaults to GH_APP_ALGO or RS256.
  # @raise [ArgumentError] if required configuration is missing or malformed.
  def initialize(log: nil, app_id: nil, installation_id: nil, app_key: nil, app_algo: nil)
    @log = log || create_default_logger
    @app_id = positive_integer(app_id || fetch_env_var("GH_APP_ID"), "app_id")
    @installation_id = positive_integer(installation_id || fetch_env_var("GH_APP_INSTALLATION_ID"), "installation_id")
    @app_key = resolve_app_key(app_key)
    @app_algo = non_empty_string(app_algo || ENV.fetch("GH_APP_ALGO", "RS256"), "app_algo")
    @client = nil
    @token_refresh_time = nil
    @token_expires_at = nil
    @rate_limit_all = nil

    setup_retry_config!
  end

  # Checks the current rate-limit bucket and sleeps until reset if it is empty.
  #
  # @param type [Symbol, String] The GitHub rate-limit resource to check.
  # @return [void]
  def wait_for_rate_limit!(type = :core)
    @log.debug("checking rate limit status for type: #{type}")
    fetch_rate_limit if @rate_limit_all.nil?

    details = rate_limit_details(type)
    return unless details

    log_rate_limit_details(details)

    if details[:remaining].positive?
      update_rate_limit(type)
      return
    end

    fetch_rate_limit if details[:remaining] <= 0 || details[:resets_at] <= Time.now
    details = rate_limit_details(type)
    return unless details

    if details[:remaining].positive?
      @log.debug("rate_limit not hit - remaining: #{details[:remaining]}")
      update_rate_limit(type)
      return
    end

    sleep_duration = [details[:resets_at] - Time.now, 0].max
    sleep_duration_and_a_little_more = sleep_duration.ceil + 2
    @log.info("github rate_limit hit: sleeping for: #{sleep_duration_and_a_little_more} seconds")
    sleep(sleep_duration_and_a_little_more)
    @log.info("github rate_limit sleep complete - Time.now: #{Time.now}")
  end

  # Delegates supported Octokit calls to the authenticated client.
  #
  # @param method [Symbol] The method being called.
  # @param args [Array<Object>] Positional arguments for the Octokit method.
  # @param kwargs [Hash] Keyword arguments for the Octokit method.
  # @return [Object] The Octokit response.
  # @raise [NoMethodError] if Octokit does not support the method.
  def method_missing(method, *args, **kwargs, &block)
    return super unless octokit_respond_to?(method)

    disable_retry = kwargs.delete(:disable_retry) || false
    rate_limit_type = rate_limit_type_for(method, args)

    request = proc do
      wait_for_rate_limit!(rate_limit_type)
      client.public_send(method, *args, **kwargs, &block) # rubocop:disable GitHub/AvoidObjectSendWithDynamicMethod
    end

    return request.call if disable_retry

    retry_request(&request)
  rescue StandardError => e
    handle_secondary_rate_limit(e) if disable_retry
    raise
  end

  # Reports whether this wrapper can delegate a method to Octokit.
  #
  # @param method [Symbol] The method being checked.
  # @param include_private [Boolean] Whether private and protected methods should be considered.
  # @return [Boolean] true when Octokit supports the method.
  def respond_to_missing?(method, include_private = false)
    octokit_respond_to?(method, include_private) || super
  end

  private

  # @return [RedactingLogger] default stdout logger.
  def create_default_logger
    RedactingLogger.new($stdout, level: ENV.fetch("GH_APP_LOG_LEVEL", "INFO").upcase)
  end

  # @return [void]
  # @raise [ArgumentError] if retry settings are malformed.
  def setup_retry_config!
    @retry_sleep = non_negative_integer(ENV.fetch("GH_APP_SLEEP", DEFAULT_RETRY_SLEEP), "GH_APP_SLEEP")
    @retry_tries = positive_integer(ENV.fetch("GH_APP_RETRIES", DEFAULT_RETRY_TRIES), "GH_APP_RETRIES")
    @retry_exponential_backoff = ENV.fetch("GH_APP_EXPONENTIAL_BACKOFF", "false").to_s.downcase == "true"
  end

  # Executes a block with retry behavior for transient errors.
  #
  # @param retries [Integer] Total attempts, including the first attempt.
  # @param sleep_time [Integer] Base sleep between attempts.
  # @return [Object] The block result.
  def retry_request(retries: @retry_tries, sleep_time: @retry_sleep)
    attempt = 0

    begin
      attempt += 1
      yield
    rescue StandardError => e
      handle_secondary_rate_limit(e)

      unless retryable_error?(e) && attempt < retries
        @log.debug("[retry ##{attempt}] #{e.class}: #{e.message} - max retries exceeded")
        raise
      end

      backoff_time = retry_sleep_duration(sleep_time, attempt)
      @log.debug("[retry ##{attempt}] #{e.class}: #{e.message} - sleeping #{backoff_time}s before retry")
      sleep(backoff_time)
      retry
    end
  end

  # @return [Hash, Sawyer::Resource] current rate-limit response.
  def fetch_rate_limit
    @rate_limit_all = retry_request do
      client.get("rate_limit")
    end
  end

  # @param type [Symbol, String] rate-limit resource name.
  # @return [void]
  def update_rate_limit(type)
    rate_limit = rate_limit_resource(type)
    return unless rate_limit

    remaining = rate_limit_value(rate_limit, :remaining).to_i
    return unless remaining.positive?

    set_rate_limit_value(rate_limit, :remaining, remaining - 1)
  end

  # @param type [Symbol, String] rate-limit resource name.
  # @return [Hash, nil] normalized rate-limit details.
  def rate_limit_details(type)
    rate_limit = rate_limit_resource(type)
    unless rate_limit
      @log.debug("rate_limit resource not found for type: #{type}")
      return nil
    end

    reset = rate_limit_value(rate_limit, :reset)
    resets_at = reset ? Time.at(reset.to_i).utc : Time.now.utc

    {
      rate_limit: rate_limit,
      remaining: rate_limit_value(rate_limit, :remaining).to_i,
      used: rate_limit_value(rate_limit, :used).to_i,
      resets_at: resets_at,
    }
  end

  # @param details [Hash] normalized rate-limit details.
  # @return [void]
  def log_rate_limit_details(details)
    @log.debug(
      "rate_limit remaining: #{details[:remaining]} - " \
      "used: #{details[:used]} - " \
      "resets_at: #{details[:resets_at]} - " \
      "current time: #{Time.now}"
    )
  end

  # @param type [Symbol, String] rate-limit resource name.
  # @return [Hash, nil] rate-limit resource data.
  def rate_limit_resource(type)
    resources = rate_limit_value(@rate_limit_all, :resources)
    return nil unless resources

    rate_limit_value(resources, type)
  end

  # @param object [Object] hash-like object.
  # @param key [Symbol, String] value key.
  # @return [Object, nil] extracted value.
  def rate_limit_value(object, key)
    return nil unless object.respond_to?(:[])

    object[key] || object[key.to_s] || object[key.to_sym]
  rescue TypeError, NoMethodError
    nil
  end

  # @param object [Object] hash-like object.
  # @param key [Symbol, String] value key.
  # @param value [Object] replacement value.
  # @return [void]
  def set_rate_limit_value(object, key, value)
    if object.respond_to?(:key?) && object.key?(key.to_s)
      object[key.to_s] = value
    else
      object[key] = value
    end
  rescue TypeError, NoMethodError
    object[key.to_s] = value
  end

  # @param key [String] environment variable name.
  # @return [String] environment variable value.
  # @raise [ArgumentError] if the variable is missing or empty.
  def fetch_env_var(key)
    non_empty_string(ENV.fetch(key), key)
  rescue KeyError
    raise ArgumentError, "environment variable #{key} is not set"
  end

  # @param app_key [String, nil] private key string or .pem path.
  # @return [String] private key content.
  # @raise [ArgumentError] if the key is missing or empty.
  def resolve_app_key(app_key)
    key = app_key || fetch_env_var("GH_APP_KEY")
    key = non_empty_string(key, "app_key")

    return normalize_key_string(key) unless key.end_with?(".pem")

    raise ArgumentError, "App key file not found: #{key}" unless File.exist?(key)

    @log.debug("Loading app key from file: #{key}")
    key_content = File.read(key)
    raise ArgumentError, "App key file is empty: #{key}" if key_content.strip.empty?

    @log.debug("Successfully loaded app key from file (#{key_content.length} characters)")
    key_content
  end

  # @param key_string [String] private key text.
  # @return [String] normalized private key text.
  def normalize_key_string(key_string)
    non_empty_string(key_string, "app_key").gsub('\\n', "\n")
  end

  # @return [Octokit::Client] authenticated client.
  def client
    @client = create_client if @client.nil? || token_expired?
    @client
  end

  # @return [String] signed GitHub App JWT.
  def jwt_token
    private_key = OpenSSL::PKey::RSA.new(@app_key)

    issued_at = Time.now.to_i - 60
    payload = {
      iat: issued_at,
      exp: issued_at + JWT_EXPIRATION_TIME,
      iss: @app_id,
    }

    JWT.encode(payload, private_key, @app_algo)
  end

  # @return [Octokit::Client] authenticated installation client.
  # @raise [ArgumentError] if GitHub returns a malformed token response.
  def create_client
    app_client = ::Octokit::Client.new(bearer_token: jwt_token)
    token_response = app_client.create_app_installation_access_token(@installation_id)
    access_token = response_value(token_response, :token)
    raise ArgumentError, "GitHub installation token response did not include a token" if access_token.to_s.empty?

    client = ::Octokit::Client.new(access_token: access_token)
    client.auto_paginate = true
    client.per_page = DEFAULT_PER_PAGE
    @token_refresh_time = Time.now
    @token_expires_at = token_expires_at(token_response)
    client
  end

  # @return [Boolean] true when the installation token needs refresh.
  def token_expired?
    return true if @token_expires_at.nil?

    Time.now >= @token_expires_at
  end

  # @param token_response [Object] GitHub token response.
  # @return [Time] local refresh deadline.
  def token_expires_at(token_response)
    expires_at = response_value(token_response, :expires_at)
    return @token_refresh_time + TOKEN_EXPIRATION_TIME if expires_at.to_s.empty?

    Time.iso8601(expires_at.to_s).utc - TOKEN_REFRESH_BUFFER
  rescue ArgumentError
    @token_refresh_time + TOKEN_EXPIRATION_TIME
  end

  # @param response [Object] hash-like response object.
  # @param key [Symbol] response key.
  # @return [Object, nil] extracted response value.
  def response_value(response, key)
    return response.token if key == :token && response.respond_to?(:token)
    return response.expires_at if key == :expires_at && response.respond_to?(:expires_at)
    return nil unless response.respond_to?(:[])

    response[key] || response[key.to_s]
  end

  # @param method [Symbol] Octokit method name.
  # @param include_private [Boolean] whether private/protected methods are included.
  # @return [Boolean] true when Octokit supports the method.
  def octokit_respond_to?(method, include_private = false)
    methods = ::Octokit::Client.public_instance_methods
    if include_private
      methods += ::Octokit::Client.protected_instance_methods
      methods += ::Octokit::Client.private_instance_methods
    end
    methods.include?(method)
  end

  # @param method [Symbol] Octokit method name.
  # @param args [Array<Object>] Octokit method args.
  # @return [Symbol] rate-limit resource name.
  def rate_limit_type_for(method, args)
    method_name = method.to_s
    return :search if method_name.start_with?("search_")
    return :graphql if method_name.include?("graphql")
    return :graphql if method_name == "post" && args.first.is_a?(String) && args.first.include?("/graphql")

    :core
  end

  # @param error [StandardError] raised API error.
  # @return [Boolean] true when the request can be retried.
  def retryable_error?(error)
    return false if secondary_rate_limit?(error)

    TRANSIENT_ERROR_CLASSES.any? { |error_class| error.is_a?(error_class) }
  end

  # @param error [StandardError] raised API error.
  # @return [void]
  def handle_secondary_rate_limit(error)
    return unless secondary_rate_limit?(error)

    @log.warn("GitHub secondary rate limit hit, sleeping for #{SECONDARY_RATE_LIMIT_SLEEP} seconds")
    sleep(SECONDARY_RATE_LIMIT_SLEEP)
  end

  # @param error [StandardError] raised API error.
  # @return [Boolean] true when GitHub reported a secondary rate limit.
  def secondary_rate_limit?(error)
    error.message.to_s.downcase.include?("secondary rate limit")
  end

  # @param sleep_time [Integer] configured base sleep.
  # @param attempt [Integer] current attempt number.
  # @return [Integer] sleep duration.
  def retry_sleep_duration(sleep_time, attempt)
    return sleep_time unless @retry_exponential_backoff

    sleep_time * (2**(attempt - 1))
  end

  # @param value [Object] value to parse.
  # @param name [String] value name for error messages.
  # @return [Integer] parsed positive integer.
  # @raise [ArgumentError] if the value is not a positive integer.
  def positive_integer(value, name)
    parsed = Integer(value)
    raise ArgumentError, "#{name} must be a positive integer" unless parsed.positive?

    parsed
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a positive integer"
  end

  # @param value [Object] value to parse.
  # @param name [String] value name for error messages.
  # @return [Integer] parsed non-negative integer.
  # @raise [ArgumentError] if the value is not a non-negative integer.
  def non_negative_integer(value, name)
    parsed = Integer(value)
    raise ArgumentError, "#{name} must be a non-negative integer" if parsed.negative?

    parsed
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a non-negative integer"
  end

  # @param value [Object] value to validate.
  # @param name [String] value name for error messages.
  # @return [String] validated string.
  # @raise [ArgumentError] if the value is empty.
  def non_empty_string(value, name)
    string = value.to_s
    raise ArgumentError, "#{name} must not be empty" if string.strip.empty?

    string
  end
end
