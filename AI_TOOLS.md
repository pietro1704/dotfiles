# Arch AI launchers

`ai-memory run codex --yolo --jail` works from the home directory by launching
in `~/workspace/homelab`, scoped to `default/pips`. The shell's directory is
unchanged. This is a dedicated writable project, **not access to the whole
homelab**. Within an existing project its directory and memory scope stay intact.
Use project-local launches or explicitly approved extra mounts for other files.

The launchers prefer verified user releases (ai-memory 3.4.5 and ai-jail 3.3.1)
until `/usr/bin` has an equal or newer version, then automatically use the system
package. They preserve ai-jail's trust-store boundary and the existing Arch
`~/.local/bin/agent-guard` resource limits.

Codex is installed as the native 0.166.0 executable and its two companion
executables from the existing Codex application distribution. The ai-jail wrapper
maps only those three executables read-only for declared Codex launches. This
works with project profiles disabling mise and toolchains, where the npm launcher
otherwise cannot find its platform dependency. Native arguments after `--`
cannot request these mappings. Agent configuration and credentials are untouched.

Reinstall on Linux x86_64 using `bash scripts/install-ai-tools.sh /path/to/native/bin`.
The source directory must contain `codex`, `codex-code-mode-host`, and
`codex-exec-server`. The script validates upstream SHA-256 files before extraction,
keeps rollback copies, and requires the existing Arch agent-guard. Apply the
chezmoi service drop-in separately and restart the user ai-memory service to make
its server use the selected release too. The installer never restarts a service.
Linux launchers and service overrides are excluded from other operating systems.

Validation: `python3 -m unittest discover -s tests`; `bash -n` on the two
launchers and installer. Runtime acceptance additionally launches `codex --version`
through ai-memory/ai-jail both from home and a real project, verifies the expected
memory scope, checks that the trust store and SSH keys are not accessible, and
checks child failure/cancellation exit codes. These probes send no model prompts.
