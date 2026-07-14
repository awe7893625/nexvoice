# NexVoice local runtime

This helper is the authenticated local MLX boundary used by the macOS app.
It listens only on `127.0.0.1`, accepts bounded base64 audio bytes (never a
user file path), requires `X-NexVoice-Local-Token`, and returns a transcript.

On Apple Silicon, install the pinned `runtime/requirements.txt` into a private
virtual environment and set `NEXVOICE_MLX_MODEL` to a verified model revision.
The repository deliberately does not include model weights. A public binary
release must publish the exact model revision, SHA-256, and license in
`model-manifest.json`.

Example development launch:

```sh
zsh runtime/setup-runtime.sh
```

The app creates `~/.cache/nexvoice/local-runtime.token` with mode 0600. A
launchd bundle must run under the same user and read that file; never place the
token in a plist, command line, or world-readable log.
