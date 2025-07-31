# frozen_string_literal: true

require_relative "example"

first_value = 1
second_value = 2

rbt = RubyTemplate.new

puts rbt.simple_addition(first_value, second_value)
