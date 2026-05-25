# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require_relative "../../lib/github"

describe GitHub do
  let(:app_id) { 123 }
  let(:installation_id) { 456 }
  let(:app_key) { File.read("spec/fixtures/fake_private_key.pem") }
  let(:jwt_token) { "mocked_jwt_token" }
  let(:access_token) { "ghs_fake-classic-token-not-secret" }
  let(:expires_at) { "2026-01-01T01:00:00Z" }
  let(:now) { Time.utc(2026, 1, 1, 0, 0, 0) }
  let(:logger) { instance_double(RedactingLogger) }
  let(:app_client) { instance_double(Octokit::Client) }
  let(:installation_client) { instance_double(Octokit::Client) }

  let(:default_rate_limit_response) do
    {
      resources: {
        core: { remaining: 5_000, used: 0, limit: 5_000, reset: (now + 3_600).to_i },
        search: { remaining: 30, used: 0, limit: 30, reset: (now + 3_600).to_i },
        graphql: { remaining: 5_000, used: 0, limit: 5_000, reset: (now + 3_600).to_i }
      }
    }
  end

  def stub_env(name, value)
    allow(ENV).to receive(:fetch).with(name).and_return(value)
    allow(ENV).to receive(:fetch).with(name, anything).and_return(value)
  end

  def stub_default_env
    allow(ENV).to receive(:fetch).and_call_original
    stub_env("GH_APP_ID", app_id.to_s)
    stub_env("GH_APP_INSTALLATION_ID", installation_id.to_s)
    stub_env("GH_APP_KEY", app_key)
    stub_env("GH_APP_LOG_LEVEL", "INFO")
    stub_env("GH_APP_SLEEP", "3")
    stub_env("GH_APP_RETRIES", "10")
    stub_env("GH_APP_EXPONENTIAL_BACKOFF", "false")
    stub_env("GH_APP_ALGO", "RS256")
  end

  def stub_logger
    [:debug, :info, :warn, :error].each do |method|
      allow(logger).to receive(method)
    end
    allow(RedactingLogger).to receive(:new).and_return(logger)
  end

  def stub_client_creation(token_response: { token: access_token, expires_at: expires_at })
    allow(JWT).to receive(:encode).and_return(jwt_token)
    allow(Octokit::Client).to receive(:new).with(bearer_token: jwt_token).and_return(app_client)
    allow(app_client).to receive(:create_app_installation_access_token).with(installation_id).and_return(token_response)
    allow(Octokit::Client).to receive(:new).with(access_token: access_token).and_return(installation_client)
    allow(installation_client).to receive(:auto_paginate=).with(true)
    allow(installation_client).to receive(:per_page=).with(GitHub::DEFAULT_PER_PAGE)
  end

  def github_with_cached_client
    GitHub.new.tap do |github|
      github.instance_variable_set(:@client, installation_client)
      github.instance_variable_set(:@token_refresh_time, now)
      github.instance_variable_set(:@token_expires_at, now + 3_600)
    end
  end

  before do
    stub_default_env
    stub_logger
    allow(Time).to receive(:now).and_return(now)
    allow(installation_client).to receive(:get).with("rate_limit").and_return(default_rate_limit_response)
  end

  describe "#initialize" do
    it "initializes with environment variables" do
      github = GitHub.new

      expect(github.instance_variable_get(:@app_id)).to eq(app_id)
      expect(github.instance_variable_get(:@installation_id)).to eq(installation_id)
      expect(github.instance_variable_get(:@app_key)).to eq(app_key)
      expect(github.instance_variable_get(:@app_algo)).to eq("RS256")
    end

    it "initializes with provided parameters" do
      github = GitHub.new(log: logger, app_id: "999", installation_id: "888", app_key: app_key, app_algo: "RS512")

      expect(github.instance_variable_get(:@log)).to eq(logger)
      expect(github.instance_variable_get(:@app_id)).to eq(999)
      expect(github.instance_variable_get(:@installation_id)).to eq(888)
      expect(github.instance_variable_get(:@app_algo)).to eq("RS512")
    end

    it "loads app key from a PEM file path" do
      github = GitHub.new(app_id: 999, installation_id: 888, app_key: "spec/fixtures/fake_private_key.pem")

      expect(github.instance_variable_get(:@app_key)).to eq(app_key)
    end

    it "normalizes escaped newlines in key strings" do
      key_with_escapes = "-----BEGIN RSA PRIVATE KEY-----\\nsome\\nkey\\ndata\\n-----END RSA PRIVATE KEY-----"
      github = GitHub.new(app_id: 999, installation_id: 888, app_key: key_with_escapes)

      expect(github.instance_variable_get(:@app_key)).to eq(key_with_escapes.gsub('\\n', "\n"))
    end

    it "raises when a PEM file path does not exist" do
      expect {
        GitHub.new(app_id: 999, installation_id: 888, app_key: "nonexistent_file.pem")
      }.to raise_error(ArgumentError, "App key file not found: nonexistent_file.pem")
    end

    it "raises when a PEM file is empty" do
      file = Tempfile.new(["empty_key", ".pem"])
      file.close

      expect {
        GitHub.new(app_id: 999, installation_id: 888, app_key: file.path)
      }.to raise_error(ArgumentError, "App key file is empty: #{file.path}")
    ensure
      file&.unlink
    end

    it "raises when a required environment variable is missing" do
      allow(ENV).to receive(:fetch).with("GH_APP_KEY").and_raise(KeyError)

      expect {
        GitHub.new(app_id: 999, installation_id: 888)
      }.to raise_error(ArgumentError, "environment variable GH_APP_KEY is not set")
    end

    it "raises when IDs or config values are malformed" do
      expect { GitHub.new(app_id: "0") }.to raise_error(ArgumentError, "app_id must be a positive integer")
      expect { GitHub.new(installation_id: "abc") }.to raise_error(ArgumentError, "installation_id must be a positive integer")

      stub_env("GH_APP_SLEEP", "-1")
      expect { GitHub.new }.to raise_error(ArgumentError, "GH_APP_SLEEP must be a non-negative integer")

      stub_env("GH_APP_SLEEP", "1")
      stub_env("GH_APP_RETRIES", "0")
      expect { GitHub.new }.to raise_error(ArgumentError, "GH_APP_RETRIES must be a positive integer")

      stub_env("GH_APP_RETRIES", "1")
      stub_env("GH_APP_ALGO", " ")
      expect { GitHub.new }.to raise_error(ArgumentError, "app_algo must not be empty")
    end
  end

  describe "client creation" do
    it "creates a client with a GitHub installation token and its refresh deadline" do
      stub_client_creation

      github = GitHub.new
      expect(github.send(:client)).to eq(installation_client)
      expect(github.instance_variable_get(:@token_expires_at)).to eq(Time.iso8601(expires_at) - GitHub::TOKEN_REFRESH_BUFFER)
    end

    it "accepts response objects that expose token fields as methods" do
      token_response = Struct.new(:token, :expires_at).new(access_token, expires_at)
      stub_client_creation(token_response: token_response)

      expect(GitHub.new.send(:client)).to eq(installation_client)
    end

    it "falls back to the conservative token lifetime when expires_at is absent or invalid" do
      stub_client_creation(token_response: { token: access_token, expires_at: "not-a-time" })

      github = GitHub.new
      github.send(:client)

      expect(github.instance_variable_get(:@token_expires_at)).to eq(now + GitHub::TOKEN_EXPIRATION_TIME)
    end

    it "raises when GitHub does not return a token" do
      allow(JWT).to receive(:encode).and_return(jwt_token)
      allow(Octokit::Client).to receive(:new).with(bearer_token: jwt_token).and_return(app_client)
      allow(app_client).to receive(:create_app_installation_access_token).with(installation_id).and_return({})

      expect {
        GitHub.new.send(:client)
      }.to raise_error(ArgumentError, "GitHub installation token response did not include a token")
    end

    it "refreshes expired cached clients and reuses fresh cached clients" do
      stub_client_creation
      github = GitHub.new

      expect(github.send(:client)).to eq(installation_client)

      github.instance_variable_set(:@token_expires_at, now + 1)
      expect(github.send(:client)).to eq(installation_client)

      github.instance_variable_set(:@token_expires_at, now)
      expect(github.send(:client)).to eq(installation_client)
      expect(app_client).to have_received(:create_app_installation_access_token).twice
    end

    it "generates a JWT with GitHub App timing claims" do
      github = GitHub.new

      expect(JWT).to receive(:encode).with(
        hash_including(iat: now.to_i - 60, exp: now.to_i - 60 + GitHub::JWT_EXPIRATION_TIME, iss: app_id),
        kind_of(OpenSSL::PKey::RSA),
        "RS256"
      ).and_return(jwt_token)

      expect(github.send(:jwt_token)).to eq(jwt_token)
    end

    it "raises OpenSSL errors for invalid private keys" do
      github = GitHub.new(app_id: app_id, installation_id: installation_id, app_key: "invalid-key-content")

      expect { github.send(:jwt_token) }.to raise_error(OpenSSL::PKey::RSAError)
    end
  end

  describe "#wait_for_rate_limit!" do
    let(:github) { github_with_cached_client }

    it "fetches and decrements the selected rate-limit bucket" do
      github.wait_for_rate_limit!(:search)

      expect(installation_client).to have_received(:get).with("rate_limit")
      expect(github.instance_variable_get(:@rate_limit_all)[:resources][:search][:remaining]).to eq(29)
    end

    it "supports string-keyed rate-limit responses" do
      response = {
        "resources" => {
          "core" => { "remaining" => 2, "used" => 1, "limit" => 5_000, "reset" => (now + 3_600).to_i }
        }
      }
      allow(installation_client).to receive(:get).with("rate_limit").and_return(response)

      github.wait_for_rate_limit!("core")

      expect(response["resources"]["core"]["remaining"]).to eq(1)
    end

    it "does not sleep when a rate-limit bucket is missing" do
      allow(github).to receive(:sleep)

      github.wait_for_rate_limit!(:integration_manifest)

      expect(github).not_to have_received(:sleep)
    end

    it "refreshes stale empty rate-limit data before deciding to sleep" do
      first_response = {
        resources: { core: { remaining: -1, used: 5_001, limit: 5_000, reset: (now - 10).to_i } }
      }
      second_response = {
        resources: { core: { remaining: 5_000, used: 0, limit: 5_000, reset: (now + 3_600).to_i } }
      }
      allow(installation_client).to receive(:get).with("rate_limit").and_return(first_response, second_response)

      github.wait_for_rate_limit!(:core)

      expect(installation_client).to have_received(:get).with("rate_limit").twice
    end

    it "sleeps when the refreshed rate-limit bucket is still empty" do
      response = {
        resources: { core: { remaining: 0, used: 5_000, limit: 5_000, reset: (now + 10).to_i } }
      }
      allow(installation_client).to receive(:get).with("rate_limit").and_return(response)
      allow(github).to receive(:sleep)

      github.wait_for_rate_limit!(:core)

      expect(github).to have_received(:sleep).with(12)
      expect(logger).to have_received(:info).with(/github rate_limit hit/)
    end

    it "handles hash-like objects that reject symbol accessors" do
      broken_reader = Class.new do
        def [](key)
          raise TypeError if key == :remaining
        end
      end.new
      string_writer = Class.new do
        attr_reader :values

        def initialize
          @values = {}
        end

        def []=(key, value)
          raise TypeError if key.is_a?(Symbol)

          @values[key] = value
        end
      end.new

      expect(github.send(:rate_limit_value, broken_reader, :remaining)).to be_nil

      github.send(:set_rate_limit_value, string_writer, :remaining, 1)

      expect(string_writer.values["remaining"]).to eq(1)
    end
  end

  describe "#method_missing" do
    let(:github) { github_with_cached_client }

    it "delegates supported Octokit methods with core, search, and GraphQL rate limits" do
      allow(installation_client).to receive(:rate_limit).and_return("core")
      allow(installation_client).to receive(:search_users).with("test").and_return("search")
      allow(installation_client).to receive(:post).with("/graphql", { query: "query" }).and_return("graphql")
      allow(installation_client).to receive(:post).with(nil).and_return("nil")

      expect(github.rate_limit).to eq("core")
      expect(github.search_users("test")).to eq("search")
      expect(github.post("/graphql", { query: "query" })).to eq("graphql")
      expect(github.post(nil)).to eq("nil")
    end

    it "raises NoMethodError for unknown methods without retrying" do
      allow(github).to receive(:sleep)

      expect { github.not_an_octokit_method }.to raise_error(NoMethodError)
      expect(github).not_to have_received(:sleep)
    end

    it "retries transient errors and preserves non-transient errors" do
      error_count = 0
      allow(installation_client).to receive(:repositories) do
        error_count += 1
        error_count == 1 ? raise(Faraday::TimeoutError, "timeout") : "repos"
      end
      allow(github).to receive(:sleep)

      expect(github.repositories).to eq("repos")
      expect(github).to have_received(:sleep).with(3)

      allow(installation_client).to receive(:user).and_raise(StandardError, "bad request")

      expect { github.user }.to raise_error(StandardError, "bad request")
      expect(github).to have_received(:sleep).once
    end

    it "uses exponential backoff when configured" do
      stub_env("GH_APP_EXPONENTIAL_BACKOFF", "true")
      github = github_with_cached_client
      error_count = 0
      allow(installation_client).to receive(:organizations) do
        error_count += 1
        error_count < 3 ? raise(Faraday::TimeoutError, "timeout") : "orgs"
      end
      allow(github).to receive(:sleep)

      expect(github.organizations).to eq("orgs")
      expect(github).to have_received(:sleep).with(3)
      expect(github).to have_received(:sleep).with(6)
    end

    it "gives up when retry attempts are exhausted" do
      allow(installation_client).to receive(:organizations).and_raise(Faraday::ConnectionFailed, "down")
      allow(github).to receive(:sleep)

      expect {
        github.organizations
      }.to raise_error(Faraday::ConnectionFailed, "down")

      expect(github).to have_received(:sleep).exactly(9).times
    end

    it "does not retry when disable_retry is true" do
      allow(installation_client).to receive(:user).and_raise(Faraday::TimeoutError, "timeout")
      allow(github).to receive(:sleep)

      expect {
        github.user(disable_retry: true)
      }.to raise_error(Faraday::TimeoutError, "timeout")

      expect(github).not_to have_received(:sleep)
    end

    it "handles secondary rate limits once and raises" do
      allow(installation_client).to receive(:search_issues).and_raise(StandardError, "You have exceeded a secondary rate limit")
      allow(github).to receive(:sleep)

      expect {
        github.search_issues("repo:owner/name is:open")
      }.to raise_error(StandardError, /secondary rate limit/)

      expect(logger).to have_received(:warn).with(/GitHub secondary rate limit hit/)
      expect(github).to have_received(:sleep).with(GitHub::SECONDARY_RATE_LIMIT_SLEEP)
    end
  end

  describe "#respond_to?" do
    it "reports Octokit methods without creating an authenticated client" do
      expect(Octokit::Client).not_to receive(:new)
      github = GitHub.new

      expect(github.respond_to?(:rate_limit)).to be true
      expect(github.respond_to?(:not_an_octokit_method)).to be false
    end

    it "honors include_private" do
      allow(Octokit::Client).to receive(:private_instance_methods).and_return([:private_octokit_method])

      expect(GitHub.new.respond_to?(:private_octokit_method, true)).to be true
    end
  end
end
