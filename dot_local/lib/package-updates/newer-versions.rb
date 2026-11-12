# frozen_string_literal: true
require "json"
# Use Homebrew's version ordering, including formula revisions, instead of guessing semver.
newer = Formula.installed.select do |formula|
  formula.installed_kegs.any? { |keg| keg.version > formula.pkg_version }
end
puts JSON.generate(newer.map(&:name))
