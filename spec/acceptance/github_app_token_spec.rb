# frozen_string_literal: true

require "json"
require "rspec"
require "webmock/rspec"
require_relative "../../lib/github"

WebMock.disable_net_connect!

describe "GitHub App installation token handling" do
  APP_ID = 123
  INSTALLATION_ID = 456
  EXPIRES_AT = "2030-01-01T00:00:00Z"
  PRIVATE_KEY = File.read("spec/fixtures/fake_private_key.pem")

  CLASSIC_INSTALLATION_TOKEN = "ghs_fake-classic-token-not-secret"
  STATELESS_INSTALLATION_TOKEN = "ghs_12345.not-a-real-jwt-segment.#{'a' * 260}.#{'b' * 260}"

  def stub_installation_token(token)
    stub_request(:post, "https://api.github.com/app/installations/#{INSTALLATION_ID}/access_tokens")
      .with(headers: { "Authorization" => /Bearer .+/ })
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(token: token, expires_at: EXPIRES_AT)
      )
  end

  def stub_rate_limit(token)
    stub_request(:get, "https://api.github.com/rate_limit")
      .with(headers: { "Authorization" => "token #{token}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(
          resources: {
            core: {
              limit: 5_000,
              used: 0,
              remaining: 5_000,
              reset: Time.now.to_i + 3_600
            }
          }
        )
      )
  end

  def stub_user(token)
    stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "token #{token}" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(login: "octocat")
      )
  end

  def expect_token_to_remain_opaque(token)
    token_stub = stub_installation_token(token)
    rate_limit_stub = stub_rate_limit(token)
    user_stub = stub_user(token)

    client = GitHub.new(app_id: APP_ID, installation_id: INSTALLATION_ID, app_key: PRIVATE_KEY)

    expect(client.user.login).to eq("octocat")
    expect(token_stub).to have_been_requested.once
    expect(rate_limit_stub).to have_been_requested.once
    expect(user_stub).to have_been_requested.once
  end

  it "uses classic opaque installation tokens without format assumptions" do
    expect_token_to_remain_opaque(CLASSIC_INSTALLATION_TOKEN)
  end

  it "uses stateless JWT-format installation tokens without format assumptions" do
    expect_token_to_remain_opaque(STATELESS_INSTALLATION_TOKEN)
  end
end
