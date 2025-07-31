# frozen_string_literal: true

require "rspec"
require "docker"

MAX_WAIT_TIME = 30 # how long to wait for the container to complete

APP_NAME = "ruby-template"
CONTAINER = Docker::Container.get(APP_NAME)
CI = ENV.fetch("CI", "false") == "true"

def logs(container)
  container.logs(stdout: true, stderr: true, timestamps: false)
end

describe "ruby-template" do
  before(:all) do
    # wait for the container's state to be "exited"
    start_time = Time.now
    while CONTAINER.info["State"]["Status"] != "exited"
      if Time.now - start_time > MAX_WAIT_TIME
        puts CONTAINER.inspect
        raise "Container did not exit within #{MAX_WAIT_TIME} seconds"
      end

      if CI
        puts "CONTAINER.inspect: #{CONTAINER.inspect}"
        puts "container logs: #{logs(CONTAINER)}"
      end

      sleep 1
    end
  end

  it "checks the logs of the container" do
    expect(logs(CONTAINER)).to include("3")
  end
end
