---
name: nexvoice-operations
description: Install, diagnose, tune, configure, and verify NexVoice without exposing secrets or automating macOS privacy prompts.
---

# NexVoice Agent Operations

AI agents interacting with NexVoice should follow this deterministic operations workflow.

## Operational Workflow Matrix

1. **Doctor / Diagnostics**
   Run non-interactive system and dependency health checks:
   ```bash
   python3 server/agent_cli.py doctor --json
   ```
   - Verifies system requirements, hardware specs, dependencies, model caches, ports, and tokens.
   - Inspects macOS TCC boundaries without prompting.

2. **Auto-Tune**
   Dry-run or transactionally apply model configuration based on hardware resources:
   ```bash
   # Dry-run recommendation
   python3 server/agent_cli.py tune --json

   # Benchmark local performance (uses cached model/sample, does not auto-download)
   python3 server/agent_cli.py tune --json --bench

   # Transactionally apply only local model fields
   python3 server/agent_cli.py tune --json --apply --config ./config.json
   ```

3. **Setup Local**
   Inspect exact non-interactive setup instructions:
   ```bash
   python3 server/agent_cli.py setup-local --json
   ```

4. **Verification**
   Execute test suite to confirm operational readiness:
   ```bash
   python3 -m pytest -q server runtime
   cd macos && swift test
   ```

## TCC Permission Boundaries (HUMAN Only)

The following permissions **cannot** be programmatically granted or verified via automated CLI/TCC manipulation:
- **Microphone Access**: Must be manually enabled by human operator in System Settings → Privacy & Security → Microphone.
- **Accessibility Access**: Must be manually granted by human operator in System Settings → Privacy & Security → Accessibility.

AI agents must report `HUMAN` / `BLOCKED` status for these checks without attempting interactive triggers or GUI automation.

Never print provider key values or `gateway.token`. Never add `--allow-download`
unless the user has explicitly approved model downloads. Windows clients may use
the authenticated HTTP API, but the native HUD app and MLX runtime require an
Apple Silicon Mac.
