# Run using brew ruby: exercises the guard against the installed Homebrew API.
ENV['HOMEBREW_BINARY_UPDATE_MODE'] = 'test'
require_relative '../dot_local/lib/package-updates/homebrew-binary-upgrade'

def check(message)
  raise message unless yield
  puts "PASS #{message}"
end
FakeBottle = Struct.new(:compatible_locations?)
FakeFormula = Struct.new(:full_name, :bottle, :pour_bottle?, :pinned?, :latest_version_installed?, :dependencies) do
  def recursive_dependencies
    dependencies || []
  end
end
FakeDependency = Struct.new(:to_formula)
root = FakeFormula.new('vendor/tap/app', FakeBottle.new(true), true, false, false, [])
check('compatible root accepted') { BinaryPackageUpdates.blockers(root).empty? }
root.bottle = nil
check('missing root bottle rejected') { BinaryPackageUpdates.blockers(root).first.include?('vendor/tap/app') }
root.bottle = FakeBottle.new(false)
check('wrong cellar rejected') { !BinaryPackageUpdates.blockers(root).empty? }
root.bottle = FakeBottle.new(true)
root[:pinned?] = true
check('explicit pinned root rejected') { BinaryPackageUpdates.blockers(root).first.include?('pinned') }
root[:pinned?] = false
dep = FakeFormula.new('other/tap/lib', nil, true, false, false, [])
root.dependencies = [FakeDependency.new(dep)]
check('implicit source dependency rejected with full identity') { BinaryPackageUpdates.blockers(root).first.start_with?('other/tap/lib:') }
dep[:pinned?] = true
check('outdated pinned dependency rejected') { BinaryPackageUpdates.blockers(root).first.include?('pinned dependency') }
dep[:latest_version_installed?] = true
check('current installed dependency accepted without a new bottle') { BinaryPackageUpdates.blockers(root).empty? }

# Allocate without installing: both interception points must raise before Homebrew
# can fetch source or launch its compiler subprocess, also for implicit installs.
installer = FormulaInstaller.allocate
installer.define_singleton_method(:formula) { root }
%i[build run_fetch].each do |phase|
  blocked = false
  begin
    installer.send(phase)
  rescue CannotInstallFormulaError => e
    blocked = e.message.include?('vendor/tap/app')
  end
  check("#{phase} blocked by actual FormulaInstaller") { blocked }
end
