# frozen_string_literal: true

# Run with `brew ruby`. The guard lives only in this update process; Homebrew's
# own files and manually invoked commands are left intact.
require "formula_installer"
require "cmd/upgrade"

module BinaryPackageUpdates
  module RejectSourceBuilds
    def build(*)
      raise CannotInstallFormulaError, "Source builds disabled: #{formula.full_name} needs a compatible bottle"
    end

    def run_fetch(*)
      raise CannotInstallFormulaError, "Source fetch/build disabled: #{formula.full_name} needs a compatible bottle"
    end
  end

  def self.compatible_bottle?(formula)
    bottle = formula.bottle
    bottle && bottle.compatible_locations? && formula.pour_bottle?
  end

  def self.blockers(formula)
    return ["#{formula.full_name}: pinned"] if formula.pinned?
    return ["#{formula.full_name}: no compatible bottle for #{Utils::Bottles.tag}"] unless compatible_bottle?(formula)

    # Conservative: retain the root if any runtime dependency needs an unavailable
    # upgrade. Homebrew still validates version and platform requirements itself.
    formula.recursive_dependencies do |_dependent, dep|
      Dependency.prune if dep.build? || dep.test?
    end.filter_map do |dep|
      dependency = dep.to_formula
      next if dependency.latest_version_installed?
      if dependency.pinned?
        "#{dependency.full_name}: pinned dependency needs an upgrade"
      elsif !compatible_bottle?(dependency)
        "#{dependency.full_name}: dependency has no compatible bottle"
      end
    end
  end

  def self.upgrade(names, dry_run: true)
    supported = names.select do |name|
      reasons = blockers(Formula[name])
      warn "Skipped #{name}: #{reasons.join('; ')}" unless reasons.empty?
      reasons.empty?
    end
    return if supported.empty?

    args = ["--formula", "--force-bottle", "--yes", *supported]
    args.unshift("--dry-run") if dry_run
    command = Homebrew::Cmd::UpgradeCmd.new(args)
    raise "Dry-run flag was not accepted" if dry_run && !command.args.dry_run?
    command.run
    raise "Homebrew reported an update failure" if Homebrew.failed?
  end

  def self.run
    mode = ENV.fetch("HOMEBREW_BINARY_UPDATE_MODE", "audit")
    raise "Unknown binary update mode: #{mode}" unless %w[audit dry-run apply cask-dry-run cask-apply test].include?(mode)
    return if mode == "test"

    if mode.start_with?("cask-")
      args = ["--cask", "--yes"]
      args.unshift("--dry-run") if mode == "cask-dry-run"
      command = Homebrew::Cmd::UpgradeCmd.new(args)
      raise "Dry-run flag was not accepted" if mode == "cask-dry-run" && !command.args.dry_run?
      command.run
      raise "Homebrew reported a cask update failure" if Homebrew.failed?
      return
    end

    excluded = ENV.fetch("HOMEBREW_BINARY_UPDATE_SKIP_FORMULAE", "").split(",")
    names = Formula.installed.select(&:outdated?).reject(&:pinned?).reject do |formula|
      formula.installed_kegs.any? { |keg| keg.version > formula.pkg_version }
    end.map(&:full_name)
    names.reject! { |name| excluded.include?(name.split("/").last) }
    if mode == "audit"
      names.each do |name|
        formula = Formula[name]
        bottle = formula.bottle
        available = compatible_bottle?(formula)
        puts "#{available ? 'BOTTLE' : 'SKIP'}\t#{name}\t#{bottle&.tag || 'none'}"
      end
      return
    end
    upgrade(names, dry_run: mode != "apply")
  end
end

# Both phases are blocked for implicit dependencies and dependent reinstalls too.
%i[build run_fetch].each do |phase|
  raise "Homebrew installer API changed; binary update guard needs review" unless FormulaInstaller.method_defined?(phase)
end
FormulaInstaller.prepend(BinaryPackageUpdates::RejectSourceBuilds)
BinaryPackageUpdates.run
