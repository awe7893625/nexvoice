#!/usr/bin/env python3
"""Static safety checks for the macOS installer preflight transaction."""

from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).with_name("install-app.sh").read_text()


class InstallAppOrderingTests(unittest.TestCase):
    def test_runtime_setup_is_after_every_preflight_gate(self):
        runtime_block = SCRIPT.index("# One-command open-source onboarding:")
        gates = (
            'if [[ -e "$STRAY" ]]; then',
            'for LEGACY_LABEL in ai.nexvoice.local-runtime ai.nexvoice.locald; do',
            'if pgrep -x NexVoice >/dev/null 2>&1; then',
            'if [[ "$PORT_FREE" != "1" ]]; then',
            'if [[ -f "$OWNER_MARKER" ]]',
            'if [[ -f "$OWNER_RECORD" ]]',
        )
        for gate in gates:
            self.assertLess(SCRIPT.index(gate), runtime_block, gate)

    def test_runtime_install_is_staged_and_published_after_success(self):
        runtime_block = SCRIPT.index("# One-command open-source onboarding:")
        runtime_end = SCRIPT.index('\nmkdir -p "$HOME/Applications"', runtime_block)
        stage = SCRIPT.index('RUNTIME_STAGE_ROOT="$RUNTIME_ROOT/.venv-runtime.$$"', runtime_block, runtime_end)
        setup = SCRIPT.index('zsh "$ROOT_DIR/runtime/setup-runtime.sh"', stage, runtime_end)
        stage_check = SCRIPT.index('[[ -x "$RUNTIME_STAGE_VENV/bin/python3" ]]', setup, runtime_end)
        publish = SCRIPT.index('publish-runtime-venv.py', stage_check, runtime_end)
        backup = SCRIPT.index('RUNTIME_BACKUP="$RUNTIME_ROOT/.venv.previous.$$"', publish, runtime_end)
        published = SCRIPT.index('RUNTIME_STAGE_PUBLISHED=1', publish, runtime_end)

        self.assertGreaterEqual(stage, runtime_block)
        self.assertLess(setup, stage_check)
        self.assertLess(stage_check, publish)
        self.assertLess(publish, backup)
        self.assertLess(backup, published)
        self.assertIn('NEXVOICE_RUNTIME_DEST="$RUNTIME_STAGE_ROOT"', SCRIPT[stage:setup])
        self.assertNotIn('mv -f "$RUNTIME_LINK_STAGE" "$RUNTIME_VENV"', SCRIPT[runtime_block:runtime_end])

    def test_failed_staging_cleans_up_until_publication(self):
        runtime_block = SCRIPT.index("# One-command open-source onboarding:")
        cleanup = SCRIPT.index("cleanup() {")
        runtime_end = SCRIPT.index('\nmkdir -p "$HOME/Applications"', runtime_block)
        cleanup_stage = SCRIPT.index('if [[ -n "$RUNTIME_STAGE_ROOT" && "$RUNTIME_STAGE_PUBLISHED" != "1" ]]; then', cleanup)
        published = SCRIPT.index('RUNTIME_STAGE_PUBLISHED=1', runtime_block, runtime_end)

        self.assertIn('RUNTIME_STAGE_PUBLISHED=0', SCRIPT[:cleanup])
        self.assertLess(cleanup_stage, runtime_block)
        self.assertLess(cleanup_stage, published)
        self.assertLess(published, runtime_end)
        self.assertIn('rm -rf "$RUNTIME_STAGE_ROOT"', SCRIPT[cleanup_stage:cleanup_stage + 180])

    def test_failed_pip_stage_executes_cleanup(self):
        cleanup_start = SCRIPT.index("cleanup() {")
        cleanup_end = SCRIPT.index("\ntrap cleanup EXIT", cleanup_start)
        cleanup_function = SCRIPT[cleanup_start:cleanup_end]
        setup_runtime = Path(__file__).parents[2] / "runtime" / "setup-runtime.sh"

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            fake_python = temp_root / "python3"
            fake_python.write_text(
                "#!/bin/zsh\n"
                "if [[ \"$1\" == \"-m\" && \"$2\" == \"venv\" ]]; then\n"
                "  mkdir -p \"$3/bin\"\n"
                "  print '#!/bin/zsh' > \"$3/bin/pip\"\n"
                "  print 'exit 77' >> \"$3/bin/pip\"\n"
                "  chmod +x \"$3/bin/pip\"\n"
                "  exit 0\n"
                "fi\n"
                "exit 99\n"
            )
            fake_python.chmod(0o755)
            stage_root = temp_root / "runtime" / ".venv-runtime.forced-failure"
            harness = temp_root / "cleanup-harness.zsh"
            harness.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/zsh
                    set -euo pipefail
                    STAGING="{temp_root}/app.staging"
                    RUNTIME_ROOT="{temp_root}/runtime"
                    RUNTIME_VENV="{temp_root}/runtime/.venv"
                    RUNTIME_STAGE_ROOT=""
                    RUNTIME_STAGE_PUBLISHED=0
                    RUNTIME_BACKUP=""
                    LOCK_DIR="{temp_root}/install.lock"
                    {cleanup_function}
                    trap cleanup EXIT

                    RUNTIME_STAGE_ROOT="{stage_root}"
                    if NEXVOICE_PYTHON="{fake_python}" \\
                        NEXVOICE_RUNTIME_DEST="{stage_root}" \\
                        zsh "{setup_runtime}"; then
                      print -u2 "forced pip failure unexpectedly succeeded"
                      exit 1
                    fi
                    exit 0
                    """
                )
            )
            harness.chmod(0o755)

            result = subprocess.run(
                ["zsh", str(harness)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(stage_root.exists(), result.stderr)

    def test_active_venv_is_not_used_for_dependency_install(self):
        self.assertNotIn('"$RUNTIME_VENV" -m pip install', SCRIPT)
        self.assertNotIn('"$RUNTIME_PYTHON" -m pip install', SCRIPT)


if __name__ == "__main__":
    unittest.main()
