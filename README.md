# Slim images for the homelab stacks

Builds minified copies of the music stacks' Docker images with
[mint](https://github.com/mintoolkit/mint) (formerly DockerSlim /
SlimToolkit). mint runs from its own Docker image
(`mintoolkit/mint:1.41.8`), so nothing is installed on the host.

mint starts the source image, watches which files the app opens
while a profile's probes exercise it, and writes a new image with only
those files (plus the paths a profile keeps on purpose). Anything the
probes never touch is gone from the slim image, so a profile has to reach
every real code path: pages, API calls, background jobs, scheduled
scripts and optional features.

## Use

```bash
make list               # profiles
make slim P=somafm      # pull the source image, build the slim image, compare
make verify P=somafm    # compare the slim and source images again
make sizes P=somafm     # both sizes
```

`make slim` runs `slim-image.sh build` and then `slim-image.sh verify`.
Only use a slim image whose verify run passed.

A stack that uses a slim image has these two lines in its
`docker-compose.yml`, so the shared Makefile's `make pull` skips it:

```yaml
    image: slim/mympd-somafm:latest
    pull_policy: never
```

When the source image updates, run `make slim P=<profile>` here, then
`make force` in the stack's folder.

## How a run works

- **build**: copies the stack's data into
  `/home/william/tmp/scratchpad/slim-work/<profile>` (never the live
  `./data`), starts mint, waits for the app, runs the profile's `probe()`,
  then tells mint to finish. The new image is audited: if it holds any
  mounted path or a value from the stack's env file, it is deleted and the
  run fails. mint's leftover volumes (which hold copies of the kept files)
  are removed.
- **verify**: runs the source image and the slim image in turn, the way
  the stack runs them (same user, environment and mounts, spare ports),
  runs `check()` against each, and diffs the two outputs. It also fails if
  the slim image logs more errors than the source image.

## Profiles

Each profile is `profiles/<name>.conf`; the header of `slim-image.sh`
lists the settings and functions a profile can define.

| Profile | Tested with | Notes |
|---|---|---|
| somafm | lineup, stream lookup, recent songs | |
| tunein | favorites, every favorite's stream, search, regions | favorite add/remove only on the refusal paths (real account) |
| iheart | favorites, every station, search, podcasts, episodes | favorite saving only on the refusal paths (real account) |
| pandora | stations, management lookups, a 20 s stream through ffmpeg, track controls | no station edits or ratings (real account) |
| ibroadcast | library browse, every picker view, a ranged audio stream, cover caching | only runs while the access token has 20+ minutes left, so the copy never rotates the live login |
| mympd-radio-scrobble | dry run against `tools/fake-mpd.py` playing SomaFM, iHeart, iBroadcast, Pandora and TuneIn titles | nothing is sent to Last.fm |
| music-librarian | every page, scan, genre apply/revert, tag cleanup, lyrics on two copied albums, CLI | fake MPD answers the rescan requests |
| mpd-listening-tools | sessions, mixes, queue, replace, handoff, Last.fm history | against a throwaway MPD (`tools/test-mpd.sh`) |
| explo | web UI, one full discovery run (YouTube download, ffmpeg, cover art), pip upgrade | Python kept whole: the image upgrades yt-dlp with pip |
| deemix | every API route, login, one real download | cannot be built: see below |
| mpd-alsa | plugin lists, database update, tags, art, fingerprints, MP3/M4A and every radio stream type, HTTP stream, playlists, stickers | second MPD on ports 6612/8012; plays to a null output, PulseAudio output created but off |
| beets | the nightly job, mpdstats, update, autobpm, keyfinder, missing, duplicates, export | waits for the stack's first analysis pass; fresh library of copied files |
| download-check | every review page and list, audio streaming with byte ranges, theme, approve and re-check, one pass over copied folders against the real MusicBrainz, the command line | needs network for MusicBrainz; a fake MPD refuses the rescan requests; Gotify alerts not tested |

## Images that are not slimmed

- **deemix**: its s6-overlay `/init` refuses to run unless it is PID 1,
  and mint's sensor is always PID 1 in the target container.
- **blissify**: nearly the whole image is the binary and the libraries it
  links, and the dynamic loader opens all of them at start.
- **aurral**: node, a static ffmpeg, cloudflared and Python are all used;
  a slim image that keeps every feature saves about 50 MB of 735 MB.

## Measuring the disk saving

Judge by the bytes freed on disk, not by image sizes. Images built on the
same base share those layers, while a slim image is a new single layer,
so slimming several small images on a shared base can use more disk.
Count only the layers no remaining image uses, minus the slim images'
size, before switching a stack.

## Safety rules

- Tests use copies; anything that would change a real account (favorites,
  ratings, playlists on a service) is only tested on its refusal path.
- mint's own `--exclude-mounts` does not work when mint runs in a
  container, so `slim-image.sh` excludes every mount target itself and
  audits the result. Do not remove that.
- The slim images are local only (`slim/...`); never push them.

## Contributing

Contributions are welcome!

- **Bug reports**: [Open an issue](https://github.com/bonelifer/homelab-slim/issues).
- **Everything else** (questions, feature requests, ideas, general discussion): [Use Discussions](https://github.com/bonelifer/homelab-slim/discussions).
- Pull requests are welcome for bug fixes or discussed features.

## Acknowledgments

- Built on [mint](https://github.com/mintoolkit/mint) (formerly DockerSlim / SlimToolkit).
- Code review, bug fixes, and documentation assisted by [Claude](https://www.anthropic.com/claude).

## License

This project is licensed under the **GNU General Public License v3.0**.

See [LICENSE](LICENSE) for more information.
