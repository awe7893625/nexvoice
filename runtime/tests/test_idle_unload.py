"""Idle unload of cached ASR models (claude-c13r).

Uses an injected clock and a fake mlx_whisper whose ModelHolder counts model
loads, so no real weights or MLX are needed.
"""

import os
import sys
import threading
import types
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import nexvoice_local_runtime as runtime


class FakeClock:
    def __init__(self):
        self.now = 1_000.0

    def __call__(self):
        return self.now


def fake_mlx(loads, gate=None, entered=None):
    package = types.ModuleType("mlx_whisper")
    transcribe_module = types.ModuleType("mlx_whisper.transcribe")

    class ModelHolder:
        model = None
        model_path = None

    def transcribe(path, *, path_or_hf_repo, **kwargs):
        if ModelHolder.model is None or ModelHolder.model_path != path_or_hf_repo:
            loads.append(path_or_hf_repo)
            ModelHolder.model = object()
            ModelHolder.model_path = path_or_hf_repo
        if entered is not None:
            entered.set()
        if gate is not None:
            gate.wait(5)
        return {"text": "ok"}

    transcribe_module.ModelHolder = ModelHolder
    package.transcribe = transcribe
    package.ModelHolder = ModelHolder
    return {"mlx_whisper": package, "mlx_whisper.transcribe": transcribe_module}


class TestIdleUnload:
    def setup_method(self):
        self.clock = FakeClock()
        self.patches = [
            patch.object(runtime, "_CLOCK", self.clock),
            patch.object(runtime, "_LAST_USED", self.clock.now),
            patch.object(runtime, "_IN_FLIGHT", 0),
            patch.object(runtime, "_UNLOADED_MODELS", set()),
            patch.object(runtime, "_MODEL_CACHE", {}),
            patch.dict(
                os.environ,
                {
                    "NEXVOICE_IDLE_UNLOAD_SEC": "1800",
                    "NEXVOICE_MLX_MODEL": "fake/final",
                    "NEXVOICE_MLX_PARTIAL_MODEL": "fake/partial",
                },
            ),
        ]
        for p in self.patches:
            p.start()

    def teardown_method(self):
        for p in reversed(self.patches):
            p.stop()

    def _transcribe(self, quality):
        return runtime.transcribe_wav(
            runtime._make_warmup_wav(), quality=quality, skip_vad=True
        )

    def test_unloads_after_idle_and_reloads_lazily(self):
        loads = []
        modules = fake_mlx(loads)
        holder = modules["mlx_whisper.transcribe"].ModelHolder
        with patch.dict(sys.modules, modules):
            self._transcribe("partial")
            self._transcribe("final")
            assert loads == ["fake/partial", "fake/final"]
            assert set(runtime._MODEL_CACHE) == {"fake/partial", "fake/final"}

            # Not idle long enough yet.
            self.clock.now += 1_799
            assert runtime.maybe_unload_idle_models() is False
            assert len(runtime._MODEL_CACHE) == 2

            self.clock.now += 2
            assert runtime.maybe_unload_idle_models() is True
            assert runtime._MODEL_CACHE == {}
            assert holder.model is None
            # Nothing left to unload: second pass is a no-op.
            assert runtime.maybe_unload_idle_models() is False

            # Both the tiny partial and the final model reload on demand.
            self._transcribe("final")
            self._transcribe("partial")
            assert loads == ["fake/partial", "fake/final", "fake/final", "fake/partial"]
            assert set(runtime._MODEL_CACHE) == {"fake/partial", "fake/final"}

    def test_recent_use_resets_idle_timer(self):
        loads = []
        with patch.dict(sys.modules, fake_mlx(loads)):
            self._transcribe("final")
            self.clock.now += 1_500
            self._transcribe("final")
            self.clock.now += 1_500
            assert runtime.maybe_unload_idle_models() is False
            assert "fake/final" in runtime._MODEL_CACHE

    def test_in_flight_request_blocks_unload(self):
        # Negative control: a request is mid-inference and the clock says the
        # runtime has been idle far past the limit -- unload must not happen.
        loads = []
        gate = threading.Event()
        entered = threading.Event()
        with patch.dict(sys.modules, fake_mlx(loads, gate=gate, entered=entered)):
            worker = threading.Thread(target=self._transcribe, args=("final",))
            worker.start()
            assert entered.wait(5)
            self.clock.now += 10_000
            assert runtime._IN_FLIGHT == 1
            assert runtime.maybe_unload_idle_models() is False
            gate.set()
            worker.join(5)
            assert not worker.is_alive()
            assert runtime._IN_FLIGHT == 0
            assert "fake/final" in runtime._MODEL_CACHE

        runtime._begin_model_use()
        try:
            self.clock.now += 10_000
            assert runtime.maybe_unload_idle_models() is False
            assert "fake/final" in runtime._MODEL_CACHE
        finally:
            runtime._end_model_use()
        # Once nothing is in flight and the idle window passes, it unloads.
        self.clock.now += 1_801
        assert runtime.maybe_unload_idle_models() is True

    def test_disabled_when_non_positive(self):
        loads = []
        with patch.dict(sys.modules, fake_mlx(loads)), patch.dict(
            os.environ, {"NEXVOICE_IDLE_UNLOAD_SEC": "0"}
        ):
            self._transcribe("final")
            self.clock.now += 1_000_000
            assert runtime.maybe_unload_idle_models() is False
            assert "fake/final" in runtime._MODEL_CACHE
