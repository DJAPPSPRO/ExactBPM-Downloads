# RhythmCore AutoCue

A native macOS app (SwiftUI, Apple Silicon and Intel, macOS 13+) that automatically places named, color-coded hot cues on MP3s. It writes them as Serato tags, which both **djay Pro** and **Serato DJ** read.

It does the same thing that was done by hand for *Bird Machine*, *Biggie Bounce* and *Bigger Than My Body*:

1. **Decode** the audio (AVFoundation). The MP3 encoder delay is trimmed, so 0:00 is the first real sample.
2. **Beat grid.** It builds an onset curve from spectral flux and finds the tempo with autocorrelation plus a tempo prior. It then folds the curve at sub-0.1% steps to lock the exact BPM and phase. The resulting grid sits within about 5 ms of the transients.
3. **Downbeat.** For each of the four possible bar phases, it checks how strongly the kick, harmony changes and level changes line up. The best-scoring phase is the downbeat.
4. **Sections.** A beat-level self-similarity matrix (timbre + harmony + onsets) gives structural novelty, and four-bar spectral jumps add to it. Candidate cues are only ever bar starts. Club tracks prefer 4- and 8-bar phrase lines; songs do not.
5. **Cue choice.**
   - Intro is always the first real downbeat: the earliest non-clamped bar start that has music, so the first cue lands perfectly on beat 1.
   - Outro is where the energy drops and stays down, or 8 bars before the end.
   - The strongest section starts fill the remaining pads, at least 4 bars apart.
5b. **Attack alignment.** The wide analysis window reacts about 20 ms before a drum hit. AutoCue measures the real attack on every downbeat with an 11.6 ms window and moves the grid so each cue sits exactly on the hit (perfect on-beat alignment). The first cue is always placed on the true first beat of the track.
6. **Names and colors.**

   | Part | Color | Meaning |
   |---|---|---|
   | Intro | green | start of the track: mix in here |
   | Verse | blue | vocal or rap section |
   | Pre-Chorus | cyan | lead-in to the chorus |
   | Chorus | red | main hook of a song |
   | Build | yellow | tension rising into a drop |
   | Drop | red | full energy, bass in |
   | Hook | magenta | new phrase while the energy stays high |
   | Break | purple | short dip in energy |
   | Breakdown | purple | long, stripped-back section |
   | Bridge | sky blue | a section that appears once in a song |
   | Outro | orange | ending: mix out here |

   Every pad has a ● ▾ menu to set its part, which changes the name and color together. Typing a part name, such as "Chorus" or "Drop 2", also recolors the cue. A color key sits under the pads.

   The names depend on the kind of track:
   - **Club tracks** (big swings in bass): names come from energy and bass. Intro, Build, Drop, Hook, Break/Breakdown, Verse and Outro.
   - **Songs**: sections that sound alike are grouped. The loudest repeating group is the Chorus, the next one is the Verse, a short section leading into a chorus is the Pre-Chorus, and a section that appears only once late in the track is the Bridge.
7. **Write** a `Serato Markers2` ID3 GEOB frame. Existing Serato loops and the track color are kept. Every write is read back and verified.

## Build

You need Xcode 15 or later. Run:

```bash
./build_app.sh                 # → dist/RhythmCore AutoCue.app (ad-hoc signed) + dist/autocue-cli
UNIVERSAL=0 ./build_app.sh     # faster, this Mac's architecture only
SIGN_IDENTITY="Developer ID Application: RhythmCore Industries (TEAMID)" NOTARY_PROFILE=rhythmcore ./build_app.sh
```

To work in Xcode instead, run `open Package.swift`, choose the **RhythmCoreAutoCue** scheme and press Run.

To run the tests: `swift test`. They check the Serato tag reader and writer, including a byte-for-byte match with the Python writer used on the first three tracks.

## Use

Click **New Cue Screen** (⌘N) at any time to clear the screen and load a new folder. If any tracks have cues that haven't been written, AutoCue asks first. Your files are never touched by this.

1. **Add.** Drop MP3s or whole folders on the window, or press ⌘O. Tracks are only listed. Nothing is analyzed yet.
1b. **Scan.** Press **Start Scan** (⌘R) to analyze every track not scanned yet. The header shows "Scanning X of Y". **Stop Scan** finishes the tracks in progress and stops; the rest stay "Not scanned yet" until you press Start Scan again. **Analyze Again** on one track re-scans only that track.
2. **Check.** Click a track to see its waveform and pads.
   - Click a pad's number (or anywhere on the waveform) to hear it from that point. ⌘. stops playback.
   - Rename a cue by typing in its name field.
   - Click the color dot to recolor a cue.
   - Use ‹‹ ›› to move a cue by a bar and ‹ › to move it by a beat. Cues always stay exactly on the beat grid.
   - **Reset to Automatic Cues** undoes your changes.
   - **Cues per track** (4, 8, 12 or 16) re-picks the cues instantly. This replaces your manual edits.
3. **Write.** Ticked tracks are written. **Existing cues are overwritten by default**, and every original is backed up first. To keep cues that are already in the files, turn off **Overwrite Existing Cues** in the ••• menu above the track list, or in the Cues menu. Tracks that already have cues then start unticked. The setting is remembered.
   - **Update original files:** every file is backed up to `~/Music/RhythmCore AutoCue Backups/` first, and **Undo Last Write** restores them.
   - **Save copies to a folder:** your originals are never touched.

   When the write finishes, a summary lists what was written and walks you through loading the tracks in djay Pro.

Right-click a track for **Show in Finder**, **Analyze Again** and **Remove from List**.

**Progress and sleep.** The header shows "Analyzing 4 of 20" or "Writing 3 of 12" with a progress bar, a percentage and the current track. The Dock icon shows the same count (e.g. `3/12`) and bounces once when a job finishes while you're in another app. While AutoCue is analyzing or writing, it keeps the Mac from idle-sleeping, so long batches finish with the display off. The display is still allowed to turn off. A laptop with its lid closed still sleeps unless it's connected to power and an external display, so leave the lid open for big batches.

**Timing fine-tune** (footer, ±50 ms) shifts every cue when writing and previewing, and is remembered between launches. Leave it at 0 unless cues feel early or late in your DJ app.

**Command line:** `dist/autocue-cli track.mp3 [--cues 8] [--write]`

## Speed

These speedups don't change any results:

- **Every core is used.** Each track's spectral analysis is split across all CPU cores, and up to 6 tracks are analyzed at once. A new track starts the moment one finishes.
- **The selected track goes first.** The track on screen jumps to the front of the queue.
- **Finished analyses are cached** by the audio content itself (a SHA-256 of the audio, not the tags). Re-adding a folder, or opening a track after its cues were written, is instant and gives exactly the same result. **Analyze Again** skips the cache, and **Cues ▸ Clear Analysis Cache** empties it.

## Big libraries (9,000+ tracks)

- **Each file is decoded in a separate helper process** (`autocue-worker`, inside the app bundle). Some damaged MP3s make Apple's audio decoder crash, and an app can't catch that kind of crash. With the helper, only the helper dies: the track is marked "crashed the audio decoder — skipped" and the batch continues. A file that hangs is stopped after 3 minutes. Cached tracks skip the helper entirely.

- **Long files are rejected before decoding.** A file over 20 minutes is turned away by reading its header, so a 2-hour mix in the library can never fill memory.
- **Decoding is chunked.** Audio is decoded and mixed to mono in chunks, so only the mono signal is ever held in memory.
- **The novelty matrix is half size.** It stores half the beat-to-beat matrix plus a narrow band, with an exactly computed median. On the test tracks the results are bit-for-bit the same as before.
- **The track list keeps only a slim copy of each analysis** (about 2 KB per track: bar levels and the grid). The full analysis lives in the disk cache and is reloaded when you change the cue count.
- **Parallel analysis is limited by cores and RAM**, so an 8 GB Mac never runs more jobs than it can hold.
- **Folder scanning runs off the main thread,** and thousands of tracks are added in one update. Large drag-and-drops are collected first, then added in one go.
- **The backup log is append-only,** one line per file, so the cost per file stays constant and nothing is lost if the app is interrupted.
- **Backup space is checked before writing.** If the backups won't fit, nothing is changed and AutoCue says so. Files on the same APFS disk as the backups folder are cloned, so their backups take almost no space.
- **Undo runs in the background**, and the summary only lists the first 12 failures.
- **The analysis cache uses about 150 KB per track** (roughly 1.3 GB for 9,000 tracks). **Cues ▸ Clear Analysis Cache** frees it.

## Limits (v1)

- MP3 only, single tracks up to 20 minutes (not full mixes). AIFF, WAV, M4A and FLAC store Serato tags differently, so they come next.
- It assumes a steady tempo, which fits almost all club and studio music. When the tempo drifts (live drums, tempo changes), the track is marked **Check** with an orange warning.
- Section names are educated guesses from the audio. The positions are reliable, but you may want to change a part with the ● ▾ menu.
- Accuracy so far comes from 3 tracks only. Compared with the hand-placed cues, 6/8, 6/8 and 5/8 cues land on the same bar, and the others land on real section changes. Test more of your own tracks to measure accuracy properly.

## Layout

```
Sources/AutoCueCore/      engine (no UI)
  AudioDecoder.swift      AVFoundation decode → mono 22.05 kHz
  DSP.swift               FFT (Accelerate) + numpy-equivalent helpers
  BeatAnalyzer.swift      onset curve, tempo, grid, downbeat, bar/beat features
  CueSelector.swift       section detection, cue choice, naming, colors
  SeratoTags.swift        ID3v2.3/2.4 + GEOB + Serato Markers2 read/write
  BackupManager.swift     full-file backups + restore
Sources/RhythmCoreAutoCue/  SwiftUI app
Sources/autocue-cli/        command-line tool
Tests/                      tag round-trip tests
reference/                  Python reference engine the Swift port mirrors 1:1
```
