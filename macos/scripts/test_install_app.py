#!/usr/bin/env python3
"""Static safety checks for the macOS installer preflight transaction."""

from pathlib import Path
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
        stage = SCRIPT.index('RUNTIME_STAGE_ROOT="$RUNTIME_ROOT/.venv-runtime.$$"')
        setup = SCRIPT.index('zsh "$ROOT_DIR/runtime/setup-runtime.sh"', stage)
        stage_check = SCRIPT.index('[[ -x "$RUNTIME_STAGE_VENV/bin/python3" ]]', setup)
        link = SCRIPT.index('ln -s "$RUNTIME_STAGE_VENV" "$RUNTIME_LINK_STAGE"', stage_check)
        publish = SCRIPT.index('mv -f "$RUNTIME_LINK_STAGE" "$RUNTIME_VENV"', link)
        legacy_publish = SCRIPT.index('mv "$RUNTIME_LINK_STAGE" "$RUNTIME_VENV"', link)

        self.assertGreaterEqual(stage, runtime_block)
        self.assertLess(setup, stage_check)
        self.assertLess(stage_check, link)
        self.assertLess(link, publish)
        self.assertLess(link, legacy_publish)
        self.assertIn('NEXVOICE_RUNTIME_DEST="$RUNTIME_STAGE_ROOT"', SCRIPT[stage:publish])
        self.assertIn('RUNTIME_BACKUP="$RUNTIME_ROOT/.venv.previous.$$"', SCRIPT[legacy_publish:])
        self.assertNotIn('mv "$RUNTIME_STAGE_VENV" "$RUNTIME_VENV"', SCRIPT)

    def test_active_venv_is_not_used_for_dependency_install(self):
        self.assertNotIn('"$RUNTIME_VENV" -m pip install', SCRIPT)
        self.assertNotIn('"$RUNTIME_PYTHON" -m pip install', SCRIPT)


if __name__ == "__main__":
    unittest.main()
