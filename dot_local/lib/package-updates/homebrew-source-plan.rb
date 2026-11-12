# frozen_string_literal: true
# Read-only source queue; manually managed / pinned formulas remain excluded.
require "json"
excluded = %w[edencommon fb303 fbthrift fizz folly mvfst wangle llvm llvm@22 watchman xcodes mise herdr ai-memory ai-jail]
queue = Formula.installed.filter_map do |formula|
  next if formula.pinned? || excluded.include?(formula.name)
  next unless formula.outdated?
  formula.full_name
end
puts JSON.generate(queue)
