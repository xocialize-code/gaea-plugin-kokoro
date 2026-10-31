# gaea-plugin-kokoro

hexgrad's **Kokoro-82M** (Apache-2.0) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: fast English
text-to-speech, the first plugin on MES Audio 0.1. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-kokoro-tts-swift](https://github.com/xocialize/mlx-kokoro-tts-swift), runs in its own process, and speaks the Gaea
Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-kokoro
```

## What it offers

One model, `kokoro-82m`, on MES `audio.speak` (Audio 0.1, media-engine-spec v0.7.0):

- **Voices.** The 28 English preset voices in the Kokoro-82M snapshot: 11 American female (`af_*`), 9 American male
  (`am_*`), 4 British female (`bf_*`) and 4 British male (`bm_*`). `af_heart` is the default. Clients list them with
  `GET …/operations/audio.speak/models/kokoro-82m/voices`. An American voice speaks `en-US`, a British one `en-GB`.
- **Text.** Up to 4,000 characters. The package draws at most 512 phonemes in one forward pass, so the worker plans
  the text: it cuts it at sentence ends (and, in a long sentence, at the last comma or space) into pieces of at most
  300 characters, and draws them in turn. `[pause 1.5s]` (or `[pause]`, half a second) is silence, up to 10 s. Kokoro
  performs no other cue; MES removes one with the warning `cue_unsupported`.
- **Streaming.** The offer streams: with `"stream": [{"output": "audio"}]` each piece reaches the client as soon as
  it's drawn. The chunks are the package's own 16-bit samples, so a `pcm_s16le` stream rebuilds the batch WAV byte
  for byte.
- **Seeds.** Kokoro's sine source draws noise from MLX's random state, which the worker seeds with the job's seed
  (0 to 2³² − 1) before the first piece. A job without one gets one, reported in `effective.seed`. The same seed and
  text give the same WAV.
- **Output.** 24 kHz mono 16-bit WAV. Gaea converts to the request's `output` (rate, channels, bit depth).
- **Not offered.** Cloning (`voice_ref`), emotions, styles and speed. MES refuses them with 422 before the worker sees
  them.

On an M5 Max, a sentence takes about 0.35 s warm, and 2,000 characters (two minutes of speech, nine pieces) take
about 2.7 s.

## Lanes and memory

One lane, `bf16`, declared at 500 MB resident. The worker's measured footprint after a run is about 2.75 GB, most of
it MLX's buffer cache.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). The lane reads
`mlx-community/Kokoro-82M-bf16` (339 MB: the checkpoint and every voice embedding) there, and downloads it on
`prepare` or `materialize` when it's missing.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` speaks one sentence over GPP on the signed bundle, with every `.build` folder hidden, then shows
that the bare worker outside the bundle finds no metallib. `scripts/release.sh` builds, checks, notarizes with the
fleet's `mlx-notary` profile, and publishes the GitHub release. The release workflow does the same in CI when a
`v<version>` tag is pushed.

`kokoro-inproc` (its header lists the options) is not part of the plugin: it runs the same lane in-process through
MLXServeEngine, with the worker's text plan and seeding, as the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` runs four seeded jobs over GPP on the signed bundle and through `kokoro-inproc`, and needs each pair to
be the same WAV byte for byte: one piece, three pieces with a pause, nine pieces of a long text, and seed 0.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). Kokoro-82M's weights are Apache-2.0 (hexgrad), and mlx-kokoro-tts-swift and its
kokoro-mlx-swift core are MIT.
