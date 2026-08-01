"""pytest fixtures shared by the server/ test suite.

mlx-whisper (and its `mlx` dependency) only ships wheels for Apple Silicon
macOS, so it cannot be installed on Linux CI runners. Most of the server
test suite already avoids needing it (every real `import mlx_whisper` in
server/*.py is lazy/guarded), but a couple of code paths do exercise it at
call time: diagnostics.run_doctor() probes it via importlib.util.find_spec,
and stt_router._run_local() (exercised by test_agent_api.py's
test_cloud_enabled_default_and_key_not_enough / test_privacy_mode_enforcement)
imports and calls it directly.

When the real package is missing, stub it in sys.modules with a MagicMock so
those code paths keep working on Linux CI too:
  - __spec__ is set to a real ModuleSpec, because importlib.util.find_spec()
    accesses module.__spec__ directly and Mock's __getattr__ raises
    AttributeError for any dunder-looking name it hasn't been told about,
    which find_spec() turns into 'ValueError: mlx_whisper.__spec__ is not set'.
  - transcribe(...) is configured to return {"text": ""} (a real string)
    rather than an auto-generated MagicMock, because the caller passes that
    text into opencc.OpenCC(...).convert(...) -- and opencc IS actually
    installed here, so it runs for real and requires an actual str, not a
    Mock.

On a machine that has mlx-whisper installed (e.g. local macOS dev), all of
this is a no-op -- the real package is used, exactly as before.
"""
import importlib.machinery
import sys
from unittest.mock import MagicMock

try:
    import mlx_whisper  # noqa: F401
except ImportError:
    stub = MagicMock()
    stub.__spec__ = importlib.machinery.ModuleSpec(name="mlx_whisper", loader=None)
    stub.transcribe.return_value = {"text": ""}
    sys.modules["mlx_whisper"] = stub
