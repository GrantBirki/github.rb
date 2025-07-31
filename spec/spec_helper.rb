# frozen_string_literal: true

# Here is a snippet of what your spec_helper might look like when including this github.rb code in your project
# The key bits to note is really just around '# Globally capture all sleep calls' since the github.rb client
# calls out to sleep methods when doing retry logic

require "simplecov"
require "rspec"
require "simplecov-erb"

TIME_MOCK = "2025-01-01T00:00:00Z"

COV_DIR = File.expand_path("../coverage", File.dirname(__FILE__))

SimpleCov.root File.expand_path("..", File.dirname(__FILE__))
SimpleCov.coverage_dir COV_DIR

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::ERBFormatter
]

SimpleCov.minimum_coverage 100

SimpleCov.at_exit do
  File.write("#{COV_DIR}/total-coverage.txt", SimpleCov.result.covered_percent)
  SimpleCov.result.format!
end

SimpleCov.start do
  add_filter "spec/"
  add_filter "vendor/gems/"
end

# Globally capture all sleep calls
RSpec.configure do |config|
  config.before(:each) do
    fake_time = Time.parse(TIME_MOCK)
    allow(Time).to receive(:now).and_return(fake_time)
    allow(Time).to receive(:new).and_return(fake_time)
    allow(Time).to receive(:iso8601).and_return(fake_time)
    allow(fake_time).to receive(:utc).and_return(fake_time)
    allow(fake_time).to receive(:iso8601).and_return(TIME_MOCK)
    allow(Kernel).to receive(:sleep)
    allow_any_instance_of(Kernel).to receive(:sleep)
    allow_any_instance_of(Object).to receive(:sleep)
  end
end
