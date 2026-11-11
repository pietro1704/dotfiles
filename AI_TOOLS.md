# Arch AI launchers and shared mise toolchains

All mise tools have explicit defaults in `~/.config/mise/config.toml`. Their
installations are shared under `~/.local/share/mise/installs`; project `mise.toml`
files only select versions. The Epub-to-Mp3 project retains its existing pins.
A matching global/project version uses one installation.

| Tool | Global | Epub-to-Mp3 |
| --- | --- | --- |
| Node | 26.13.0 | 26.13.0, same installation |
| npm | 12.2.2 | 12.2.2, same installation |
| Python | 3.12.10 | 3.14.10 |
| Ruby | 4.0.7 | 4.0.7, same installation |
| Codex | native 0.166.0 | npm distribution 0.167.0 |

Python 3.12.10 preserves the base interpreter used by existing virtual
environments. Ruby 4.0.7 is shared by the global environment and Epub; landingPagePietro's
legacy Ruby pin is migrated separately before removing its old installation. Other installed
mise tools use one retained version selected globally. Historical Epub worktrees
can still request older versions; explicitly install their requirements when
returning to that historical checkout. Do not change their source pins as part
of host cleanup. Independently managed system, uv and Hermes runtimes are outside
this cleanup.

Linux `.zshenv` puts stable mise shims on PATH in interactive and noninteractive
shells, removes inherited version-specific mise paths and preserves an active
virtual environment. NVM/rbenv remain fallbacks only on hosts without mise.
Reload `.zshrc` or open a new terminal after deployment.

`ai-memory run codex --yolo --jail` uses the selected mise Codex version. The
resolver accepts only native executables in that selected installation and
refuses a missing npm platform package instead of falling back to another
version. The jail maps that native executable and its available companions
read-only to stable entry points. Tiny host-side companion launchers ensure
mount targets exist even when the entire bin directory is shared read-only.
No additional Codex binaries are copied into `~/.local/bin`.

A launch from home uses `~/workspace/homelab`, scoped to `default/pips`. The
shell directory stays unchanged; this is a dedicated project, **not access to the
whole home**. Existing projects retain their own directory and memory scope.
Use a project-local launch or explicitly approved mounts for other files.

Verified user releases of ai-memory 3.4.5 and ai-jail 3.3.1 remain selected until
`/usr/bin` has an equal or newer version, then the wrappers use the system
package. ai-jail's trust-store boundary and the existing Arch `agent-guard`
resource limits remain enforced. The user-service override selects the same
ai-memory release as the CLI.

Install the global mise configuration and selected Codex before running
`bash scripts/install-ai-tools.sh`. This Linux x86_64 installer validates release
checksums, keeps rollback copies and requires the existing Arch agent-guard.
It installs only stable launcher scripts for Codex, resolving binaries through
mise. Apply the service drop-in separately; the installer never restarts services.
Machine-specific launchers/configuration are excluded from non-Linux hosts.

Validation: `python3 -m unittest discover -s tests`, shell syntax checks, then
real commands in home, a clean directory, Epub and a nested Epub directory.
Check both native and jailed Codex versions against the active mise selection.
No model prompt is needed for version, isolation or exit-status probes.
