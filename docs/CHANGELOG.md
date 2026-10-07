# Changelog

## Unreleased

- Memory (claude-c13r): the app now reuses one ephemeral `URLSession` for
  runtime probes, vocab and provider tests instead of leaking one per call; the
  health loop backs off from 5s to 30s after 5 consecutive healthy checks; live
  captions read only the last 30s of the growing recording; the HUD meter no
  longer spawns a Task per 25Hz tick. The local runtime unloads cached ASR
  weights after `NEXVOICE_IDLE_UNLOAD_SEC` (default 1800s) of inactivity and
  reloads them on the next request.
