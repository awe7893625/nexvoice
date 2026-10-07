"""Idle unload of cached ASR models (claude-c13r).

Uses an injected clock, a fake mlx_whisper whose ModelHolder counts model
loads, and fake gc/clear_cache hooks, so no real weights, MLX or Metal are
touched -- even on a Mac where mlx and mlx-whisper are installed.
"""

import os
import sys
import threading
import time
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


class Running:
    """Counts fake transcriptions currently executing."""

    def __init__(self):
        self.lock = threading.Lock()
        self.count = 0


def fake_mlx(loads, gate=None, entered=None, running=None, work_seconds=0.0, load_seconds=0.0):
    package = types.ModuleType("mlx_whisper")
    transcribe_module = types.ModuleType("mlx_whisper.transcribe")

    class ModelHolder:
        model = None
        model_path = None

    def transcribe(path, *, path_or_hf_repo, **kwargs):
        if running is not None:
            with running.lock:
                running.count += 1
        try:
            if ModelHolder.model is None or ModelHolder.model_path != path_or_hf_repo:
                if load_seconds:
                    time.sleep(load_seconds)  # cold load of the weights
                loads.append(path_or_hf_repo)
                ModelHolder.model = object()
                ModelHolder.model_path = path_or_hf_repo
            if entered is not None:
                entered.set()
            if gate is not None:
                gate.wait(5)
            if work_seconds:
                time.sleep(work_seconds)
            return {"text": "ok"}
        finally:
            if running is not None:
                with running.lock:
                    running.count -= 1

    transcribe_module.ModelHolder = ModelHolder
    package.transcribe = transcribe
    package.ModelHolder = ModelHolder
    return {"mlx_whisper": package, "mlx_whisper.transcribe": transcribe_module}


class TestIdleUnload:
    def setup_method(self):
        self.clock = FakeClock()
        self.clears = []
        self.unloaders = []
        self.mlx_loaded_before = "mlx.core" in sys.modules
        self.patches = [
            patch.object(runtime, "_GC_COLLECT", lambda: self.clears.append("gc")),
            patch.object(runtime, "_CLEAR_CACHE", self._clear_cache),
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
        # Stop/join every unloader thread before restoring module state so no
        # background thread outlives the test or sees un-patched hooks.
        for unloader in self.unloaders:
            unloader.stop(timeout=5)
            assert not unloader.is_alive()
        for p in reversed(self.patches):
            p.stop()
        # Unloading must never import MLX itself.
        assert ("mlx.core" in sys.modules) == self.mlx_loaded_before

    def _clear_cache(self):
        # Invariant: the MLX cache is only cleared under the model lock.
        assert runtime._MODEL_LOCK.locked()
        self.clears.append("clear_cache")

    def _start_unloader(self, interval):
        unloader = runtime.IdleUnloader(interval=interval).start()
        self.unloaders.append(unloader)
        return unloader

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
            assert self.clears == ["gc", "clear_cache"]
            # Nothing left to unload: second pass is a no-op.
            assert runtime.maybe_unload_idle_models() is False

            # Both the tiny partial and the final model reload on demand.
            self._transcribe("final")
            self._transcribe("partial")
            assert loads == ["fake/partial", "fake/final", "fake/final", "fake/partial"]
            assert set(runtime._MODEL_CACHE) == {"fake/partial", "fake/final"}

    def test_first_final_after_unload_succeeds(self, capsys):
        """Cold reload after idle unload: slow, but the request succeeds.

        The unloader keeps firing during the reload with the clock far past
        the idle limit; it must not drop the model the request is loading.
        """
        loads = []
        modules = fake_mlx(loads, load_seconds=0.3)
        with patch.dict(sys.modules, modules):
            self._transcribe("final")
            self.clock.now += 10_000
            assert runtime.maybe_unload_idle_models() is True
            assert runtime._MODEL_CACHE == {}
            clears_after_unload = list(self.clears)

            self.clock.now += 10_000  # still "idle" while the reload runs
            self._start_unloader(interval=0.005)
            started = time.monotonic()
            text = self._transcribe("final")
            elapsed = time.monotonic() - started

            assert text == "ok"
            assert elapsed >= 0.3  # really paid the (fake) cold load
            assert loads == ["fake/final", "fake/final"]
            assert "fake/final" in runtime._MODEL_CACHE
            assert self.clears == clears_after_unload  # no unload mid-reload
        assert "idle-unload: reloaded final model" in capsys.readouterr().out

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

    def test_unloader_thread_is_stoppable(self):
        unloader = self._start_unloader(interval=0.01)
        time.sleep(0.05)
        assert unloader.is_alive()
        unloader.stop(timeout=5)
        assert not unloader.is_alive()

    def test_unloader_never_clears_while_transcribing(self):
        """Stress: background unloader racing concurrent requests.

        Real clock with a sub-millisecond idle limit, so the unloader fires in
        the gaps between requests. The clear_cache hook asserts the model lock
        is held, and also that no (fake) transcription is executing.
        """
        running = Running()
        violations = []

        def guarded_clear():
            self._clear_cache()
            with running.lock:
                if running.count:
                    violations.append(running.count)

        loads = []
        with patch.object(runtime, "_CLEAR_CACHE", guarded_clear), patch.object(
            runtime, "_CLOCK", time.monotonic
        ), patch.dict(os.environ, {"NEXVOICE_IDLE_UNLOAD_SEC": "0.0005"}), patch.dict(
            sys.modules, fake_mlx(loads, running=running, work_seconds=0.001)
        ):
            self._start_unloader(interval=0.0005)
            stop = threading.Event()

            def worker(quality):
                while not stop.is_set():
                    self._transcribe(quality)
                    time.sleep(0.003)

            workers = [
                threading.Thread(target=worker, args=(q,))
                for q in ("final", "final", "partial")
            ]
            for w in workers:
                w.start()
            # Run until several unload/reload cycles happened (timing varies
            # by machine and Python version), with a hard cap.
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not (
                self.clears.count("clear_cache") >= 3 and len(loads) >= 4
            ):
                time.sleep(0.05)
            stop.set()
            for w in workers:
                w.join(5)
                assert not w.is_alive()
            for unloader in self.unloaders:
                unloader.stop(timeout=5)

        assert violations == []
        # The stress really exercised unload and lazy reload, not just one path.
        assert self.clears.count("clear_cache") >= 2
        assert len(loads) >= 3
