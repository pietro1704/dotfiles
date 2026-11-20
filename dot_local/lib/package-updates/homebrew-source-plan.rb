# frozen_string_literal: true
require "json"
# AI archive updates use their dedicated path. Herdr is updated manually.
excluded = %w[ai-memory ai-jail herdr]
formulas = Formula.installed.select { |formula| formula.outdated? && !excluded.include?(formula.name) &&
  formula.installed_kegs.none? { |keg| keg.version > formula.pkg_version } }
indexed = formulas.to_h { |formula| [formula.name, formula] }
queue = []
visited = {}
visit = lambda do |formula|
  return if visited[formula.name]
  visited[formula.name] = true
  formula.deps.each do |dependency|
    child = indexed[dependency.name]
    visit.call(child) if child
  end
  queue << { "name" => formula.full_name, "pinned" => formula.pinned? }
end
formulas.each { |formula| visit.call(formula) }
puts JSON.generate(queue)
