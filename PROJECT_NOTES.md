# SAM CAN Trace Viewer — Project Notes

MATLAB app for browsing PCAN-View `.trc` traces from the SAM vehicle CAN bus,
decoded against `SAM_CAN.dbc`. Built as a set of plain `.m` files (not the
App Designer `.mlapp` binary format — see "Why not `.mlapp`" below).

## How to run

```matlab
cd CanViewer
CanTraceViewer            % opens empty, use "Load .trc file" button
CanTraceViewer('path\to\file.trc')   % opens and immediately loads a file
```

`app = CanTraceViewer(...)` also returns the internal handle/data struct —
mainly useful for headless testing (see "How this was tested" below).

## File layout

| File | Purpose |
|---|---|
| `CanTraceViewer.m` | The app: UI construction, load/decode pipeline, scrub/update logic |
| `SAM_CAN.dbc` | DBC, with corrections layered in as `CM_` comments (see below) |
| `parseDBC.m` | Generic DBC parser: `BO_`/`SG_`/`VAL_` → struct array of messages/signals |
| `parseTRC.m` | Parser for PCAN-View **`.trc` v2.0** files only (see limitations) |
| `parseSAMPlay.m` | Parser for SAMPlay logger `.TXT` exports (plain comma-separated rows, no header) |
| `decodeSignalRaw.m` | Generic bit-level signal extraction (Intel/Motorola, signed/unsigned) |
| `decodeMessages.m` | Decodes every DBC signal present in a parsed trace; has special-cased handling for message 960 (multiplex filter) and message 658 (FECU_error byte-swap reconstruction, see below) |
| `buildSignalGroups.m` | All UI content lives here: which signals appear on which tab, as a gauge/plot/lamp/status-label/text-block, with what range/units |
| `decodeFecuErrors.m` | Decodes the FECU fault bitmask (CAN 0x292, bytes B5-B7) into human-readable text, per `SAM2_FECU_Errorhandling.pdf` |

## Architecture

- **No `classdef`/App Designer.** The original `BatteryCanViewer.mlapp` in
  the parent folder was plain text saved with a `.mlapp` extension, which
  MATLAB can't actually open (`.mlapp` must be a packaged zip container).
  Rebuilt from scratch as a nested-function programmatic app in a single
  `.m` file — this is plain text, diffable, and doesn't depend on the
  App Designer binary format at all. The old broken file is still sitting
  untouched in the parent folder; safe to delete if you don't need it.
- **Tabs = "toolbars".** Real MATLAB `uitoolbar` can only hold icon
  buttons, not gauges/plots, so each requested "toolbar group" is a
  `uitab` instead. `buildSignalGroups.m` returns one struct per tab.
- **Two tab layouts.** Normal tabs (Battery, Motor, Charger, Vehicle,
  Dashboard) use gauges + plots + a bottom lamp/status strip. The **Errors**
  tab has no gauges — instead it sets `g.Sections` (see
  `buildSignalGroups.m`, `mksection` helper), which renders as titled
  grouped panels instead of the cramped strip layout. A section can also
  carry `TextBlocks` (Key/Label/Formatter, via `mksection`'s 4th arg) for
  signals that need decoding into a multi-line description rather than a
  single value/code — currently just the FECU fault register, decoded by
  `decodeFecuErrors.m` and shown as plain text (colored red/amber/green
  by severity) instead of a raw number. A `Sections`-based tab can *also*
  carry real time-series `Plots` (the Errors tab does, see below) — both
  layouts share the same `buildPlotAxes` helper for creating axes/cursor
  pairs, so `refreshPlots`/`updateAtTime` need no special-casing between
  the two tab styles. Add a new `Sections`-based tab the same way if you
  want another diagnostics-style view.
- **Dual-scale plots (raw + derived unit).** `mkplot`'s optional 6th
  column, `RightAxis` (built via the `mkrightaxis(factor, unit,
  leftLimits)` helper), adds a second Y-axis on the right of a plot cell,
  linearly tied to the left axis (`rightValue = leftValue * factor`,
  `leftLimits` pins the left axis's range so the two sides can't drift
  out of sync under autoscaling). Implemented with `yyaxis` on the
  `uiaxes` (confirmed working in R2026a). Used for: the Vehicle/ECU
  "Pedals" plot (left = raw 0-65535 counts, right = 0-100%) and the
  Motor/Drive "Motor Torque" plot (left = Nm, right = raw counts, kept
  visible since the Nm scale is inferred, not firmware-confirmed — see
  below). The per-plot numeric readout column also appends the
  right-axis-converted value in parentheses when `RightAxis` is set (see
  `updatePlotValues`).
- **Categorical (enum) plots.** `mkplot`'s optional 5th column, `YValMap`
  (an `Nx2` cell `{rawValue,label}`), replaces a plot's numeric Y-tick
  labels with the enum's text — used for the Vehicle/ECU tab's "Drive
  Mode" plot (`ECO`/`Sport`/`Snow`) so the mode's time course reads
  directly instead of as a raw `0`/`2`/`3` step trace. This plot replaced
  the old "12V Rail" gauge+plot on that tab (`Voltage_12V` is still
  unconfirmed raw counts and wasn't very informative — see below).
- **Errors tab fault-code plot.** In addition to the Section panels
  (which only show the fault code at the currently-scrubbed instant), the
  Errors tab now also plots `FECU_error`'s raw bitmask over the whole
  trace. When one fault trips others in a chain reaction they all show up
  in the same scrubbed-instant snapshot with no way to tell which came
  first — the plot's first rising edge (in time) answers that.
- **Scrubbing model:** on load, every decoded signal is plotted in full
  across the whole trace once; the **cursor slider** moves an `xline`
  cursor on every plot and re-samples gauges/lamps/status labels/text
  blocks at the scrubbed time using **zero-order hold**
  (`interp1(...,'previous')`) — i.e. "last value actually received," not
  interpolation. Gauges/lamps/text for the *currently selected tab only*
  are recomputed on scrub (cheap); cursor lines move on all tabs
  regardless (also cheap, no data lookup).
- **Per-plot numeric readout.** Every plot cell (`buildPlotAxes`) is an
  axes plus a narrow value column on the right — one label per line in
  that plot (`Label: value unit`), updated by `updatePlotValues` in lock
  step with the cursor slider, same zero-order-hold sampling as gauges.
  Label font color is set to match its line's plotted color (grabbed off
  the `plot()` return handle in `refreshPlots`); a key missing from the
  current trace shows gray `N/A` instead. Value formatting prefers the
  decoded signal's own `ValMap` (DBC `VAL_` enum) over the plot's
  `YValMap` over a plain `%g <unit>` number, so e.g. the Drive Mode plot's
  readout shows `Sport` rather than a raw `2`. Only recomputed for the
  *currently selected tab* (called from `updateTabValues`), same
  cost model as gauges/lamps — not on every tab regardless of scrub.
- **Windowed view (two-slider range select):** below the cursor slider is
  a second row with two independent `uislider`s (`app.RangeLowSlider` /
  `app.RangeHighSlider`) — MATLAB has no built-in two-handle range slider
  in `uifigure`, so the "range slider" is just two plain sliders over the
  same `[0 tEnd]` limits, kept from crossing by a minimum-gap clamp in
  `onRangeSlide`. Moving either one sets `app.ViewRange`, which is applied
  as `XLim` on every plot axis (`updateAxesXLim` — cheap, no replot) and
  as the cursor slider's `Limits`; if the cursor was scrubbed outside the
  new window it gets clamped back in. This is the "select a time range,
  then scrub the cursor within it" behavior.
- **Real-time playback + single-frame step.** Left of the cursor slider are
  three buttons: step-back (⏮), play/pause (▶/⏸), and step-forward (⏭).
  Play drives the cursor slider via a `timer` (`app.PlayTimer`,
  `fixedSpacing`, 50 ms period); each tick sets the slider to
  `app.PlayStartTraceTime + toc(app.PlayStartTic)` rather than incrementing
  by a fixed step per tick, so playback tracks real wall-clock time
  regardless of tick jitter or slow callback execution (verified headlessly
  — after MATLAB's normal JIT/graphics warm-up, slider time tracks wall
  time 1:1). Playback runs within the current windowed view
  (`app.TimelineSlider.Limits`, i.e. `app.ViewRange`) and auto-stops
  (button reverts to ▶) when it reaches the window's high end. Any manual
  interaction with the cursor slider while playing (`onSlide`) auto-pauses
  it first, so a user drag never fights the timer. The step buttons
  (`stepFrame(±1)`) jump the cursor to the next/previous frame's *own*
  timestamp in `app.Trace.Time` — not a fixed time increment — so "one
  step" always means exactly one logged CAN message, clamped at the
  current view's edges. The figure's `CloseRequestFcn` stops/deletes the
  timer before closing so no orphaned timer object survives the app.
- **CAN output tab (PEAK adapter replay).** A dedicated "CAN Ausgabe
  (PEAK)" tab, built directly in `buildUI` rather than through
  `buildSignalGroups`/`app.Groups` (it doesn't show decoded signals, so
  it's deliberately left out of `app.TabList`/`app.TabHandles` — the
  `onTabChanged`/`updateAtTime` loops key off `app.TabList`, and a lookup
  that doesn't match it is a harmless no-op), lets the loaded trace's raw
  frames be retransmitted onto a real CAN bus through a PEAK-System USB
  adapter (Vehicle Network Toolbox: `canChannel('PEAK-System', device,
  channel)`), so a diagnostic display wired to the adapter can be tested
  without the vehicle. It reuses the *same* Play/Pause/step-forward/
  step-back controls as on-screen scrubbing — there is no separate replay
  transport. Device list (`canChannelList`, filtered to `Vendor ==
  "PEAK-System"`) and bit rate (dropdown, default 125000 — SAM's bus is
  125 kbit/s; no bitrate is recorded in `SAM_CAN.dbc`'s `BS_:` line
  itself, this default is just the vehicle's known real setting) are
  chosen, then "Verbinden" calls `configBusSpeed`/`start`. If no
  PEAK-System device is detected (no adapter plugged in, or the
  PCAN-Basic driver isn't installed), the dropdown falls back to whatever
  `canChannelList` does return (in practice the MathWorks Virtual CAN
  channels) with a status note, rather than leaving Connect dead —
  this is also what the headless test suite connects to (`Virtual 1`
  channel 1, sniffed from channel 2) since no physical adapter exists in
  the dev/CI environment; the underlying `canChannel(vendor,device,
  channel)` call is identical for any vendor Vehicle Network Toolbox
  supports.
  - **Armed, not just connected.** A separate "Senden bei Play/Schritt
    aktivieren" checkbox gates actual transmission — connecting alone
    never sends anything. This is a deliberate safety rail: plugging into
    a real vehicle's bus and hitting Play by habit shouldn't blast frames
    onto it.
  - **`app.LastTxTime`** is the "already transmitted up to" watermark.
    `onPlayTick` transmits every trace row with `Time` in
    `(app.LastTxTime, newT]` each tick (`txFramesInRange`) — not one
    frame per tick — so bursts of same-tick messages (several IDs due in
    one 50 ms window) all go out, in original order, via a single
    `transmit(app.CanChannel, msgArray)` call. Every cursor-moving action
    updates `app.LastTxTime`, even when it doesn't itself transmit
    (`onSlide`, `onRangeSlide`) — otherwise resuming Play after a manual
    seek would burst-replay every frame skipped over. `startPlayback`
    resets it to the resume point for the same reason. Arming the
    checkbox mid-trace also resets it to the current cursor position, so
    ticking "armed" doesn't instantly dump the whole trace-so-far.
  - **Step = exactly one message, either direction.** `stepFrame` already
    knows the exact trace row index it's moving the cursor to (needed for
    the on-screen step feature itself); the CAN tab reuses that same row
    index to transmit exactly that one frame via `sendFrameIndices`,
    forward *or* backward — a "step back" on a real bus can't literally
    un-send a frame, but resending the message you land on is what's
    actually useful for exercising a diagnostic display frame-by-frame.
  - **Verified without hardware.** No PEAK adapter is available in this
    dev environment, so the transmit path was validated end-to-end
    against MATLAB's Virtual CAN loopback (`canChannel('MathWorks',
    'Virtual 1',1)` transmitting, a second channel on `2` receiving) —
    single-step, play-burst ordering/IDs/data, disarm, and disconnect all
    matched expected trace content exactly. Since `canChannel`/
    `transmit`/`configBusSpeed` are called identically regardless of
    vendor, this exercises the same code path a real PEAK-System device
    would take — only the actual USB/PCAN-Basic driver layer is
    untested. Worth a real-hardware smoke test before relying on it.
- **Two supported trace formats, one "Load trace file" button.** Besides
  PCAN-View `.trc`, the SAMPlay logger's `.TXT` export is also accepted
  (rows like `01402.859488,      02b0,   8,   00,00,00,00,00,00,00,00,
  DC` — comma-separated, no header, always 8 data-byte fields regardless
  of DLC, trailing channel name ignored). `parseTraceFile` (plain helper
  at the bottom of `CanTraceViewer.m`) dispatches between `parseTRC.m` and
  `parseSAMPlay.m` by **sniffing the first non-empty line's content**, not
  the file extension — SAMPlay exports use a plain `.txt` extension that
  wouldn't otherwise distinguish them from anything else. The file picker
  filter accepts both `*.trc` and `*.txt`.
- **`parseSAMPlay.m` bug found & fixed after initial ship:** the first cut
  extracted each row's 8 comma-separated data-byte tokens with
  `sscanf(dataStr, '%2x')`. `sscanf` only skips *whitespace* between
  conversions, not literal characters like `,` — so on input like
  `00,00,00,09,00,1b,00,00` it read byte 0 (`00`) and then stopped dead at
  the first comma, leaving bytes 1-7 at their zero-initialized default.
  Byte 0 happens to be `00` in nearly every real row here, so DLC/ID/row
  counts all checked out and this passed initial smoke testing — it only
  surfaced when cross-checking `ECU_Drive_mode_ECU_status.FECU_error`
  (bytes 5-7) against the raw file for `SAMPlay_Logs/Maarten/LOG_C001
  (1).TXT`, which decoded to a constant `0` for every one of its 389
  frames despite the raw bytes visibly varying (`0x01`..`0x40` in byte 5).
  Fixed by extracting byte tokens with
  `regexp(...,'[0-9A-Fa-f]{2}','match')` instead of `sscanf`, which
  doesn't care what the separator is. Re-verified against the raw text of
  all three `SAMPlay_Logs/Maarten/*.TXT` example files after the fix.
  **Practical impact:** this silently zeroed every signal living outside
  byte 0 of its message, for every SAMPlay `.txt` trace — i.e. essentially
  all of them, not just `FECU_error`.
- **"No BMS on CAN (after 2s)" (`FECU_error` bit `0x00200`) still never
  appears in any of the 3 example SAMPlay files, even post-fix** — checked
  directly against the raw bytes (not just the decoded value), so this is
  *not* the same bug: bytes 5-7 of every `0x292` frame in `LOG_C001
  (1).TXT`/`(2).TXT` really are `00 00 00` whenever they're not something
  else. Both of those files have zero frames from any genuine
  BMS-*originated* message (`0x186`/`0x206`/`0x286`/`0x306`/`0x386`/
  `0x406`/`0x486`/`0x506`/`0x705` are all absent) — only `0x205`/`BMS`
  frames appear, and per the DBC that message's sender is `SAM_ECU`, i.e.
  it's the dashboard commanding the BMS's contactors, not a BMS heartbeat,
  so its presence doesn't actually prove the BMS is alive. Despite that,
  the real fault register never sets the bit in either capture. `can_io.c`
  (parent folder) only implements the STM32 dashboard's CAN *receive*
  handling, not the FECU's own fault-detection state machine, so there's
  no source here to check that bit's actual trigger condition against — it
  may need a precondition (e.g. an HV/PC-close request actually being
  made) that these two clips never reached. Worth revisiting if a firmware
  source for the FECU fault state machine itself ever turns up.
- **Efficiency map ("Effizienz-Kennfeld") tab.** Not scrub-driven either
  (same reasoning as the CAN output tab), built directly in `buildUI` and
  left out of `app.TabList`/`app.TabHandles`. X = `Skai_Motor_data.
  Motor_speed` (rpm), Y = `Skai_Motor_Torque_Voltage.skai_torque` ("Ist
  Moment", Nm), color = overall efficiency, `eta = P_mech / P_batt`:
  - `P_mech = skai_torque [Nm] * (Motor_speed [rpm] * 2*pi/60)` -- shaft power.
  - `P_batt = -(Battery_voltage [V] * Battery_current [A])` -- power OUT
    of the battery. The minus sign comes from `can_io.c`'s energy-
    consumption accumulator (`EnergySinceLastTick = currentCounter *
    mainVoltage * -0.00000108507 / currentAdded`, ~line 1283), which
    negates raw `current*voltage` (from the same raw field
    `Battery_current` is decoded from) to get a *positive* "energy used"
    number while driving -- i.e. raw `Battery_current` is negative while
    discharging/driving, positive while charging. With that flip, `P_mech`
    and `P_batt` land on the same sign together in both quadrants
    (motoring: both positive; regen braking: both negative), so `eta`
    comes out positive in both without special-casing direction.
  - One point per **Ist-Moment sample** (`skai_torque`'s own timestamps)
    -- Speed is zero-order-hold sampled there (`sampleSeriesAtTimes`),
    battery V/I are linearly interpolated (`interpSeriesAtTimes`). Points
    with `|P_batt| < 100 W` (after aux subtraction) are dropped -- not a
    real efficiency reading, just a ratio blowing up near a division by ~0.
  - **Corrections (2026-09-27, from an analysis of all PEAK + Durs
    driving logs).** Each is a popup option, stored per dataset (`K`,
    `KInfo`, `AuxInfo`, `CurrInfo`, shown in the dataset row + tooltip):
    - **Current from 0x386, not 0x186.** 0x186 is sent at only **1 Hz by
      both BMS variants**; zero-order-held against the 10 Hz torque it
      gave ~6.1 pp median per-cell scatter (250 rpm x 2.5 Nm cells)
      vs ~0.9 pp with 0x386 interpolated (Durs car: 2.5 -> 0.7 pp).
      Cross-correlation lag of 0x386 vs P_mech: 0 ms (new BMS), 50 ms
      (original BMS), so no lag compensation. 0x386's boot glitch
      (-1300 A) is filtered with `|I| <= 1000 A`. 0x186 is only the
      fallback when 0x386 is missing.
    - **Torque gain k (`estimateTorqueGain`, "Spiegelpunkt").**
      Uncorrected, the median motoring eta was 0.95 (own car, p90 ~1.0)
      and **1.20** (Durs car) -- impossible, `skai_torque` is the
      controller's *estimate* (tracks `requested_torque` within ~1.5 %).
      At equal speed and |torque| the losses are about the same motoring
      and braking, so per cell `P_batt = k*P_mech,reported + L` fits both
      quadrants: slope = k, intercept = loss. Results: **own car k ≈ 0.946**
      (0.93-0.955 per trip, same before/after Enc1100), **Durs car k ≈
      0.71** (0.70-0.73) -- the two controllers are parametrised
      differently. After correction eta_motor and eta_generator agree per
      cell (e.g. 2000 rpm / 8-12 Nm: 0.90 / 0.89). Cell edges are relative
      to the trace's 99th-percentile speed/|torque|, so it works for other
      vehicles too. Needs >= 2 cells with >= 30 motoring AND >= 30 regen
      points; traces without regen (e.g. `03082026_EZW-PES`, Durs
      `LOG_C009`) fall back to the manual k, flagged in `KInfo`.
    - **Aux base load (`estimateAuxPower`).** Standstill samples
      (`|n| < 5 rpm`, `|M| < 0.3 Nm`) are pure aux load (30-210 W). If the
      DCDC 12 V current explains them (r >= 0.5) it's modelled as
      `a + b*I_12V` (Durs ~15 W/A, own car ~18.6 W/A with r = 0.98 *per
      trip* -- pooled over trips there's no correlation because of
      per-trip offsets), else the constant standstill median.
    - Remaining known issue: at low torque (< 8 Nm) above ~4000 rpm the
      own car still shows cells > 100 % after all corrections (~10 % of
      motoring points) -- probably a torque offset in the estimate.
    - Not implemented, but seen in the data: warm winding (> 45 °C)
      shows 2-4 pp *higher* apparent eta than cold (< 35 °C) in the same
      cell -- consistent with magnet flux dropping with temperature and
      the torque estimate not compensating. A winding-temperature band
      filter would be the next step.
  - Computation only runs on "Aus aktueller Messung berechnen..." (button
    press), never automatically on load/scrub -- it's an `interp1` pass
    over the whole trace's torque-signal sample count (thousands of
    points, cheap in practice, but explicitly opt-in per the user's
    request rather than firing on every load).
  - **Settings/confirmation popup (`showKennfeldSettingsDialog`).** The
    button press doesn't compute anything itself -- it opens a small
    modal `uifigure` (`WindowStyle` = `modal`, blocked on via
    `uiwait`/`uiresume`, not `uiconfirm`, which can't host custom controls
    like checkboxes/edit fields) showing the sample count and the steady-
    state filter controls together, and nothing runs until "Berechnen" is
    clicked there ("Abbrechen" or closing the window aborts). This
    replaced two earlier, separate things: a permanently-visible steady-
    state panel taking up tab space at all times, and a plain
    `uiconfirm` gate with no way to change settings from it -- combining
    them means reviewing what's about to be computed and choosing the
    filter are the same step, and the tab body itself stays uncluttered
    when the popup isn't open. The dialog remembers whatever was
    confirmed last (`app.KennfeldSSEnabledDefault`/`WindowDefault`/
    `MaxDSpeedDefault`/`MaxDTorqueDefault`) as its defaults next time it
    opens, so repeated calculations with the same filter don't need
    re-entering it.
  - **Optional steady-state filter**, set in that popup: a checkbox
    ("Nur Steady-State-Punkte auswerten") plus three fields (window in
    seconds, max |Δ Drehzahl| in rpm, max |Δ Moment| in Nm) -- the fields
    are disabled whenever the checkbox is off, so it's visually obvious
    they're inert. When enabled, a point is kept only if Speed AND Torque
    both stay within their max-delta band over a `+-window/2` time window
    centered on that sample (`computeSteadyStateMask`, a two-pointer
    sliding-window scan over the sorted `skai_torque` timestamps -- O(n)
    despite the non-uniform CAN message spacing, since both window edges
    only move forward as the center advances). **On by default since
    2026-09-27** (1 s / 150 rpm / 2 Nm, keeps ~30-80 % of points): the
    fastest 10 % of torque changes carried 3-8 pp extra apparent loss and
    about twice the scatter. This is a *transient*
    filter (drops points where the drivetrain is mid-acceleration/
    braking), not the spatial/temporal *averaging* still tracked under
    "Possible next steps" below -- the two are independent and can both
    land eventually.
  - **Combining multiple measurements.** Each computed dataset is stored
    under a `Label` (the source trace's filename) in `app.KennfeldSets`,
    with its own `Visible` flag; re-clicking "Berechnen" for an already-
    loaded trace *replaces* that trace's dataset in place (keeping its
    current show/hide state) rather than duplicating points. Loading a
    different trace file and clicking "Berechnen" again *adds* a second
    dataset. "Speichern..."/"Laden..." persist/restore `app.KennfeldSets`
    to/from a `.mat` file (variable `kennfeldSets`) so a combined map can
    be built up across separate app sessions -- loading merges into the
    current in-memory list by the same replace-by-`Label` rule, rather
    than overwriting it. Files saved before the `Visible` field existed
    are handled on load (`~isfield(loaded,'Visible')` -> default all to
    visible); files saved before the corrections get `K = 1` and a
    "(alte Datei, ohne Korrekturen berechnet)" note.
  - **Batch load ("Mehrere Messungen laden...", `onKennfeldMultiLoadButton`).**
    Multi-select file picker -> the same settings popup, extended with a
    scrollable checkbox list of the picked files (Alle/Keine buttons,
    already-present datasets flagged "wird ersetzt") -> each ticked file is
    parsed, decoded and turned into a dataset one at a time, *only* for the
    Kennfeld: `app.Trace`/`app.Decoded` are never touched, so the scrub
    tabs keep the previously loaded measurement. Cancelable progress
    dialog; files that fail (missing signals, no frames, parse error) are
    listed in one summary alert at the end. The math lives in the plain
    helper `computeKennfeldSet` (shared with the single-trace button).
  - **Dataset list scrolling:** `Scrollable` must be set on the inner
    `uigridlayout`, not the `uipanel` -- a grid always fills its parent
    panel, so the panel never scrolls and rows beyond its height were
    simply cut off.
  - **Per-dataset show/hide, no permanent selection step.** The dataset
    list (`app.KennfeldDatasetPanel`, a scrollable `uipanel`,
    `updateKennfeldDatasetPanel`) renders one row per dataset -- a
    checkbox (`Label (N Punkte)`, toggles that dataset in/out of the plot
    immediately via `onKennfeldVisibilityToggled`) plus its own
    "Entfernen" button (deletes that dataset outright,
    `onKennfeldRemoveDataset`) -- replacing an earlier design that used a
    single multi-select listbox with one shared "Entfernen" button
    (select-then-click). `refreshKennfeldPlot`/`onKennfeldScaleButton`
    both only look at datasets with `Visible == true`; the plot title
    reports "N Punkte, X von Y Messungen sichtbar" so it's clear when
    something is hidden rather than absent.
  - Color scale is fixed to `[0, 100]` % (`clim`) regardless of the actual
    data range, so points outside a sane efficiency range (sensor timing
    mismatch between the 3 source messages, non-driving states, etc.)
    still plot -- just clipped to the colormap's end colors -- instead of
    being silently dropped or blowing out the color scale for everything
    else.
  - **Readability at high point counts.** Marker size shrinks
    automatically past 5k/20k points, and markers are drawn at 55% opacity
    (`MarkerFaceAlpha`) so overlapping points in frequently-visited
    operating regions read as denser/darker rather than one flat blob.
    Dotted reference lines at `Drehzahl = 0` and `Moment = 0`
    (`xline`/`yline`) separate the forward/reverse and motoring/regen
    quadrants at a glance. "Achsen auf Daten skalieren" sets
    `XLim = [0, max Drehzahl]` / `YLim = [0, max Moment]` over whatever's
    currently *visible* -- a fixed `[0, max]` crop as requested, not an
    auto-fit to the actual (possibly negative, e.g. regen/reverse) data
    range.
  - Ideas considered but not (yet) implemented: a data-cursor/tooltip
    showing a point's exact N/T/eta on hover; letting extreme (best/worst
    efficiency) points draw on top of the mass of average ones instead of
    plain z-order-by-dataset. Neither seemed worth the extra UI complexity
    yet -- revisit if the raw scatter still feels cluttered once real
    multi-trip data has been tried.
- **3D Kennfeldfläche popup (binned/averaged surface).** "3D-
  Kennfeldfläche..." (next to "Achsen auf Daten skalieren") opens a
  separate, non-modal `uifigure` (`showKennfeld3DPopup` /
  `onKennfeld3DButton`) -- this is the "second step" flagged as future
  work when the raw 2D scatter first shipped: nearby (Drehzahl, Moment)
  points averaged together and rendered as a connected surface, rather
  than the raw unaveraged points. Non-modal on purpose: it's a pure
  viewer with nothing to hand back to the caller, so the user can keep
  working in the main window, rotate/zoom it freely, and even open it
  several times with different bin widths side by side.
  - **Gridding (`binKennfeldPoints`).** Points from every currently
    *visible* dataset (same set the 2D scatter uses) are combined, then
    gridded onto a regular Drehzahl x Moment mesh with user-settable bin
    width in each axis (defaulted to `range/30` per axis so there's
    always a reasonable-looking mesh to start from) and averaged
    (`accumarray` sum/count -> mean) per cell -- this is literally the
    "nearby XY values merged as a mean" step. A cell is left `NaN` (a gap
    in the surface -- `surf` simply skips `NaN` vertices) unless it has at
    least "Min. Punkte / Zelle" raw samples, so a lone stray point can't
    fabricate a plateau; default is 1 (every non-empty cell counts) but
    raising it trades coverage for reliability.
  - **Outlier exclusion specific to the averaged surface.** Unlike the 2D
    scatter (where an extreme efficiency ratio -- see "sensor timing
    mismatch" note above -- only clips that one point's *color*, never
    touches the underlying number), an unfiltered outlier folded into a
    cell's *mean* would fabricate a bogus spike/pit that doesn't reflect
    the cell's real, typical value. So only points with
    `0 <= eta <= 1` feed the grid/surface here; the popup's title reports
    how many were excluded this way. The 2D scatter tab is untouched --
    still shows everything, unfiltered.
  - **Rendering: connected quads on a shared corner grid (2026-09-27).**
    Each filled cell is one `patch` quad whose 4 corners come from
    `kennfeldCornerHeights`: a corner's height = mean of all filled cells
    touching it (up to 4, diagonal neighbours included), so adjacent
    cells share corners and form one continuous surface
    (`FaceColor = 'interp'`), while an isolated cell gets its own mean at
    all 4 corners (flat tile). Replaces flat per-cell tiles at their mean
    height (disconnected "staircase"). Diagonal-only neighbours touch at a
    single shared corner point.
  - **"Rohpunkte einblenden"** overlays the same (outlier-filtered) points
    as a semi-transparent `scatter3` on top of the surface, for a visual
    sanity check of how well the averaged surface actually represents the
    raw data at a glance.
  - **"Aktualisieren"** re-bins and redraws from the current field values
    without closing/reopening the popup -- cheap (`accumarray` over a few
    thousand points), so re-gridding at a different resolution is instant.
  - **Guard against a too-coarse grid.** `surf()` needs at least a 2x2
    cell grid to form any surface patch -- a bin width close to (or
    larger than) the data's whole range collapses one or both grid
    dimensions to a single bin, which `surf()` rejects outright ("Z must
    be a matrix, not a scalar or vector") rather than drawing something
    degenerate. Caught explicitly (`size(Zc,1) < 2 || size(Zc,2) < 2`)
    and shown as the same kind of "nothing to draw yet, adjust the
    settings" placeholder text used for the zero-filled-cells case,
    instead of erroring out. **Found by headless testing** (an
    aggressively widened bin from the test script), not by inspection --
    worth remembering as a general lesson for any future `surf`/`mesh`
    use in this app.
- **Cell internal resistance ("Zell-Innenwiderstand") tab.** Whole-trace
  analysis on button press (same non-scrub pattern as the Kennfeld tab,
  built in `buildUI`, not in `app.TabList`). UI in
  `buildCellResistanceTabContent`/`refreshCellResResults`, math in the
  plain helper `computeCellResistance` (+ `robustSlopeThroughOrigin`,
  `holdSample`). Output: sortable `uitable` (R, 95% CI, deviation from the
  cell median, R², pair count, mean/min voltage, rating), a bar chart of
  each cell's **deviation from the median in %** (absolute mOhm on a
  0-based axis made all 36 bars look identical -- the cells only differ by
  a few %), the ΔU/ΔI scatter of the selected cell (table row or bar
  click), and the lag-scan curve. CSV export (`;`-separated).
  Findings from the real traces that shaped the method (checked
  2026-09-27 on the 17.09./18.09. trips):
  - **0x406 cycles through 37 slots, not 36** -- slot 37 always reports
    0 mV (filler) -- so a cell is refreshed every **3.7 s**, not 3.6 s.
    `decodeMessages.m` already only splits out 1-36.
  - **Current source: 0x386** (`BMS_Dynamic_Current_Limits.Battery_current`,
    10 Hz). 0x186's `Battery_current` is only sent at 1 Hz; it is only
    used as a fallback.
  - **The cell voltages lag the current by ~1 s.** Cross-correlating ΔU
    against ΔI over a lag range peaks at 0.95-1.0 s, identically for all
    36 cells (so it is *not* "one snapshot trickled out over 3.7 s", which
    would give a lag that depends on the cell's position in the cycle).
    Using the newest current instead (lag 0) drops the correlation from
    ~0.96 to ~0.74 and underestimates R by ~25%. A 1 s box-average of the
    current fits slightly better than a pure delay on one trace but not on
    the others, so a plain delay is used; auto-estimated per trace
    (−0.5...3 s, 50 ms steps), overridable in the UI.
  - **R is estimated from consecutive pairs of the same cell** (ΔU/ΔI,
    ~3.7 s apart), fitted through the origin, not from U/I: the unknown
    open-circuit voltage (and its SoC drift) cancels out in the
    difference.
  - **BMS startup garbage** must be filtered: first frames after BMS boot
    carry 0 mV cells, one current frame of −1300 A, and one cycle where
    cells 7-11 read ~740 mV and cell 12 ~1990 mV. Unfiltered, a single
    such pair tripled cells 1-12's result on the morning trips (looked
    like a cold-battery effect, wasn't). Filters: plausibility window
    (1500-5000 mV, |I| ≤ 1000 A), isolated-spike rejection (> 500 mV from
    both neighbours of the same cell), and MAD-based outlier rejection in
    the fit.
  - Typical result: **~0.67-0.70 mOhm per cell** (sum ~24-25 mOhm), R² ≈
    0.95, per-cell 95% CI ≈ ±0.02 mOhm (±3%), cell spread (std) ~4%. At
    this spread the per-cell ranking only partly reproduces between
    trips/halves of a trip -- no cell currently stands out clearly; a
    genuinely degraded cell (+15% and more, default threshold) would.
  - It is an *effective* resistance over ~1-4 s (includes fast
    polarisation), not the 1 kHz AC resistance of a cell datasheet, and
    it is temperature-dependent. 0x406's cell temperatures read a flat
    21-22 °C in the new-BMS traces, so no temperature correction is
    applied (the range is shown in the summary instead).
  - The new BMS's own reported resistances (0x306, `BMS_State_of_health`:
    min/avg/max all 1.0 "Ohm" at factor 0.1, cell 1 as both best and
    worst) look like placeholder values; shown for reference only. The
    original BMS sends real values -- see "Two BMS variants" below.
  - Charging traces (constant current) contain no usable ΔI -- the tab
    says so instead of showing numbers.
  - **Two BMS variants (user info, 2026-09-27).** All PEAK `.trc` logs
    (`Normale Fahrten`) come from the user's own car with a **newly
    developed BMS** (modelled on the original, not identical). The SAMPlay
    logs in `SAMPlay_Logs/Durs` come from a car with the **original BMS**.
    The findings above (placeholder 0x306, flat 22 °C, 37-slot cycle with
    slot 37 = 0 mV, boot garbage) are from the *new* BMS. Differences seen
    in the Durs logs (original BMS), all handled by the same code path:
    - 0x406 filler slot is **cell 0** instead of 37 (same 3.7 s cycle);
      `decodeMessages.m` only splits out 1-36, so both are ignored.
    - 0x186/0x206/0x286/0x306 at 1 Hz (new BMS: 0x206/0x306 at 10 Hz);
      0x386 still 10 Hz.
    - Lag vs 0x386 again ~0.9-1.1 s (corr 0.92-0.94); 0x186 fits about as
      well at ~0.1-0.3 s lag. Hence the "Strom" dropdown (Auto/0x386/0x186):
      Auto runs a lag scan per source and takes 0x186 only if its peak
      correlation beats 0x386 by > 0.02 -- in practice Auto picked 0x386
      in every driving log of both cars, and 0x186 gave results within
      ~±2%.
    - **Real 0x306 values and real cell temperatures** (14-19 °C, 12
      sensors) while driving; at standstill/charging 0x306 falls back to
      0.8 / cell 1 placeholders. The summary now shows the BMS's min/avg/max
      plus the *most frequent* best/worst cell (a median of cell indices is
      meaningless), and the bar chart labels the BMS's worst cell.
    - R ≈ 1.8-2.5 mOhm per cell (~3x the new-BMS car, varies per trip with
      temperature/SoC), BMS's own average 0.9-1.4 (unit presumably mOhm,
      different method -> lower absolute value).
    - **Consistent outliers across all 5 driving logs:** cell 10 (+28% vs
      median on average), 19 (+17%), 28 (+13%), 12 (+10%). Cells 10 and
      19 are also the BMS's own most frequent "highest resistance cell" --
      independent confirmation that the method finds real differences.
    - Lower currents (typ. < 70 A, max ~150 A) -> ~50 pairs per cell per
      trip, CI ±7% (vs ±3% on the new-BMS car).
    - Spike filter threshold raised from 500 to 800 mV so a real load step
      on this higher-resistance pack (~2.6 mOhm * 150 A = 390 mV) can't be
      mistaken for a glitch (boot glitches are >= 1700 mV off).
    - Temperature range shown as 5th-95th percentile: the new BMS's boot
      cycle reports 0 °C on some sensors.
- **Missing signals degrade gracefully.** If a signal isn't present in a
  given trace (e.g. charging-only messages during a driving trace), its
  gauge disables (`Enable='off'`), lamp goes gray, status label shows
  `N/A`, and its plot shows "no data in this trace" — nothing errors.

## Signal-decode corrections (the important part)

The original DBC was hand/reverse-engineered and had real bugs. These were
found by cross-referencing against `can_io.c` (the actual STM32 dashboard
firmware's CAN RX handler, given by the user mid-session) and are documented
inline in `SAM_CAN.dbc` as `CM_` comments. Summary:

**Firmware-confirmed fixes** (high confidence — code doesn't lie):
- `BO_390` `Battery_voltage`, `Battery_current`: unsigned → signed
- `BO_902` `Battery_current`: unsigned → signed; `dynamic_max_charge_current`,
  `dynamic_max_discharge_Current`: signed → unsigned
- `BO_1168` `Wicklungstemperatur`, `Temperatur_T1`, `Temperatur_T3`: unsigned → signed
- `BO_912` `Motor_speed`: unsigned → signed — **this was the cause of the
  bogus ~65535 rpm spikes** originally reported
- `BO_448` `Charger_temperature`, `Charger_heatsink_temperature`: unsigned →
  signed int8; `VoltageLV`: factor `1` → `0.00625` V/count (found directly
  in a firmware threshold check, confirmed correct — now reads ~13.8V)
- `BO_704` `DCDC_HV_Current`, `DCDC_12V_Current`: signed → unsigned
- `BO_960` `Ustopcharge`, `Outside_temp`, `Inside_temp`: unsigned → signed.
  Also: this CAN ID is multiplexed in firmware between 3 sub-messages
  selected by flag bits in byte 1; `decodeMessages.m` now filters to keep
  only the sub-message this DBC layout matches, and masks off byte 1's top
  2 bits before decoding `Ustopcharge` (firmware does `RxData[1] &= ~0xc0`
  because those bits are the mux flags, not data)
- `BO_657` `Voltage_12V`: signed → unsigned (firmware reads it as plain `uint8_t`)
- `BO_390` `SoC`/`remaining_capacity`: firmware comments say these are NOT
  used on the real vehicle — the app now reads `SoC` from `BO_1158`
  (`BMS_dynamic_regen_Current`) and remaining energy from `BO_774`
  (`BMS_State_of_health`) instead, per firmware's own preference
- `BO_400` was previously "`Skai_unknown_01`" with fabricated placeholder
  signal names. Replaced entirely with the real content per firmware
  (`case 0x190`): `Skai_enabled`, `Skai_powerModuleError`,
  `Skai_hardwareError`, `Skai_driveError`, `Skai_driveWarning`. Renamed to
  `Skai_Status_Errors`. This is now the backbone of the Errors tab's Motor
  Controller section.
- `BO_658` `FECU_error`: not a plain little-endian 24-bit field at all.
  `can_io.c` (`case 0x292`) builds it as
  `(*(uint16_t*)&RxData[6]) | (RxData[5]<<16)`, which on this
  little-endian target expands to `RxData[6] | (RxData[7]<<8) |
  (RxData[5]<<16)` — byte 5 is the MSB, byte 6 the LSB, and byte 7 the
  middle byte, i.e. **bytes 6 and 7 are swapped** relative to a plain
  Intel 24-bit read. The old `SG_` (`byte5|byte6<<8|byte7<<16`) decoded a
  completely different value — verified against all 5 driving traces,
  every frame decoded as `0x00020` under the old byte order vs. the real
  `0x200000` under the firmware-correct one. This exactly matched a user
  report of the app showing fault `20` when the real logged fault was
  `200000`. Because this byte permutation can't be expressed as one
  contiguous `SG_`, `FECU_error` no longer has a DBC signal line at all —
  `decodeMessages.m` reconstructs it directly from the raw bytes for
  message `658`. **Re-verified 2026-08-05:** the Errors tab's raw
  fault-code plot and the decoded FECU Fault Register text block both key
  off the exact same decoded map entry
  (`ECU_Drive_mode_ECU_status.FECU_error`), so they were already
  guaranteed to show the same value — confirmed headlessly by comparing
  the plot's source values against what's fed into `decodeFecuErrors` for
  a full trace (`0x200000` in both, matching).

**User-confirmed** (from the vehicle owner directly, not derived from
firmware source or data regression):
- `BO_657` `trip_km`: factor `1` → `0.1`. Raw value is stored/sent in
  100m steps; user confirmed this 2026-08-05, so the value is now
  divided by 10 to read true km. Range widened accordingly (was already
  correct in km terms, just off by 10x).

**Inferred, not firmware-confirmed** (flagged in the DBC comment and worth
revisiting if you find better source):
- `BO_401` `requested_torque` (Motor/Drive "Motor Torque (cmd)", the
  ECU's *Sollmoment* command to the SKAI motor controller) and `BO_656`
  `skai_torque` ("Motor Torque (actual)", SKAI's reported delivered
  torque): factor `1` → `0.005` Nm/count. `can_io.c` never builds/reads
  `0x191` (`ECU_Skai_Control`) at all — it's a different ECU board's
  message — and while it does read `0x290`'s raw `int16` torque field
  (`case 0x290`, `skai.torque = *((int16_t*) RxData)`), it applies no
  scale of its own. The scale was inferred instead from the raw data: the
  16-bit signed raw value clips at exactly `±10000` in every one of the 5
  available driving traces, regardless of route or driver — a classic
  torque-limiter clamp signature, not something that would land on a
  suspiciously round number by chance. The user confirmed the vehicle's
  real torque tops out at ~50Nm, so `±10000` counts = `±50Nm` gives a
  clean `0.005` Nm/count. Applied identically to both the commanded and
  actual signals (same 16-bit field layout, same message pairing). Unlike
  `VoltageHV`/`skai_DC_Link_Voltage` above, there's no independent second
  sensor to regress this against, so both torque plot/gauges keep the raw
  count visible alongside Nm (see "Dual-scale plots" in Architecture)
  rather than being treated as fully confirmed.
- `BO_960` `Inside_temp`/`Outside_temp`: factor `1` → `0.1`. At factor 1 the
  values read 280–377 "°C" (impossible). At 0.1 they read 28–38°C, which is
  physically plausible for the trace's actual date (early August). No
  explicit `*0.1` constant was visible in `can_io.c` — it's likely applied
  in separate display-formatting code not included in what was provided.
- `BO_657` `acceleration_Pedal`, `break_pedal`: signed → unsigned.
  `can_io.c`'s `case 0x291` only reads bytes 4–5 (`ignitionKey`/
  `v12BusVoltage`) and never touches bytes 0–3, so this one has **no**
  firmware confirmation — it's inferred purely from trace data. Evidence:
  in all 5 available driving traces, the raw `uint16` for
  `acceleration_Pedal` ramps smoothly through the *entire* 0–65535 range
  every time the pedal is pressed noticeably (28–45% of frames land
  ≥32768 in every trace); decoded as signed, that produces a discontinuous
  jump from ~+32767 to ~−32768 every time the raw count crosses that
  boundary — this was reported as the "Pedals" plot showing wild square-wave
  spikes on the accel trace while brake stayed clean. `break_pedal` shares
  the identical field layout in the same message and was fixed for
  consistency, even though no trace so far presses the brake hard enough
  (raw stayed under ~25000 everywhere) to actually hit the wraparound.
- `BO_656` `skai_DC_Link_Voltage` (Motor tab "DC Link Voltage"): factor `1`
  → `0.1`. `can_io.c` doesn't build message `0x290` at all (it's
  motor-controller → dashboard telemetry the logger just records), so no
  firmware source exists for this scale either. Found by comparing against
  `BMS_Battery_voltage_current_SoC.Battery_voltage` — a motor inverter's DC
  link should read close to pack voltage whenever the main contactor is
  closed. Ratio (BMS voltage / raw DC-link count) measured **0.0997 ± 0.002**
  over ~36k samples across all 5 trips, i.e. essentially exactly `1/10`.
  This was reported as displaying `1280` instead of `128.0 V`.
- `BO_448` `VoltageHV` (Charger tab): factor `1` → `0.0625`. Also compared
  against BMS pack voltage: ratio measured **0.06211 ± 0.00001** across the
  same 36k samples — essentially exactly `1/16`, which is the *same*
  per-count scale `Battery_voltage` itself already uses (`0.0625` V/count),
  and exactly `10×` the firmware-confirmed `VoltageLV` factor (`0.00625`).
  The ~0.6% gap between the raw ratio and a clean `1/16` is well within the
  tolerance expected from two independent voltage sensors (charger ADC vs.
  BMS shunt) plus zero-order-hold resample timing between two different
  CAN messages. No longer shown as "(raw)"/amber — treated as confirmed.
- `BO_704` `DCDC_12V_Current`: factor `1` → `0.0625` A/count, by analogy
  with the `0.0625`-per-count family above (no independent current
  reference exists in this DBC to regress against directly). Cross-checked
  via power balance against the firmware-confirmed `VoltageLV` (~13.8V):
  `13.8V × (raw × 0.0625)` gives a DCDC output power with **median ~160W,
  range ~95–215W** across all 5 trips during normal driving — matching the
  vehicle's known typical DCDC load almost exactly. No longer flagged
  amber/uncertain.
- `BO_704` `DCDC_HV_Current`: same `0.0625` A/count factor applied *by
  symmetry only* (identical 16-bit field layout, same message, right next
  to `DCDC_12V_Current`) — genuinely **unconfirmed**. It reads exactly `0`
  in all ~36k samples across all 5 driving traces, so there is no non-zero
  data point to validate any scale against. It may not even be the DCDC's
  own HV-side draw — it could be the AC mains charging current instead,
  which would only be nonzero during an actual charge session. Still
  rendered amber/"(unconfirmed)" — see "Known limitations" below (no
  usable charging trace exists to check this).

**Left unconfirmed / shown as raw counts** — these render with an amber
italic label and `(raw)`/`(unconfirmed)` in the name so they're not
misread as calibrated physical units:
- `Charger_status_2nd_PDO.DCDC_HV_Current` (scale applied by symmetry with
  `DCDC_12V_Current` only, see above — reads 0 in every trace so far)
- `ECU_Pedals_ignition_12V.Voltage_12V`
- `ECU_Pedals_ignition_12V.acceleration_Pedal`, `break_pedal` (sign fixed,
  see above, but no known scale/offset to turn raw counts into % pedal
  travel)
- `Charger_informations.Ustopcharge` (mux-flag masking was fixed, but the
  resulting raw value's scale is still unknown)

**Not touched — no firmware evidence either way:**
`ECU_Skai_Control` (`BO_401`/`0x191`: `requested_torque`, `requested_speed`,
`Skai_enable`, `Torque_or_Speed_Control`) is never built or read by
`can_io.c` — that file is the *dashboard* node, and this message is sent by
a different ECU board. Taken as given in the original DBC.

## Known limitations

- **Only PCAN-View `.trc` v2.0 is supported.** The older files in the
  parent folder (`Charging_did_not_Start.trc`, etc.) are `v1.1` format
  (different column layout, no `DT` token) and will parse to zero rows —
  the app shows a "no CAN data frames found" alert rather than crashing,
  but nothing will be decoded. Only the newer `Normale Fahrten\*.trc`
  files (PCAN-View v6, `v2.0` format) are supported. If v1.1 support is
  ever needed, `parseTRC.m` would need a second code path.
- **`Charger_information_2` (`BO_1216`) may not reflect how the vehicle
  actually transmits it.** The firmware's RTC time-sync packet appears to
  be multiplexed into `0x3C0`/960 (same ID as `Charger_informations`)
  rather than sent as a separate `0x4C0`/1216 message. Not currently
  displayed in any tab, so low priority.
- **`BMS_Flags.error_precence` semantics are unverified** — shown as a
  simple "nonzero = active" lamp in the Errors tab; no firmware source
  confirms whether that's the right interpretation (e.g. it might use a
  specific sentinel for "no error" rather than zero).
- The old `BatteryCanViewer.mlapp` (broken, plain-text-as-`.mlapp`) is
  still in the parent folder, untouched.

## How this was tested

No interactive display was available for automated testing, so everything
was verified headlessly via `matlab -batch`, calling
`CanTraceViewer('path\to\file.trc')` (the optional-argument form) and then
driving the returned `app` struct's callbacks directly (`ValueChangedFcn`,
`SelectionChangedFcn`, etc.) to simulate scrubbing and tab switching,
checking gauge/lamp/status values against hand-decoded raw bytes. Real
visual layout/polish has only been checked by the user running it
interactively — flag anything cramped or misaligned.

The efficiency map tab's calculation button opens a modal settings popup
(`showKennfeldSettingsDialog`, blocked on via `uiwait`) before anything is
computed. A plain `ButtonPushedFcn` on that popup's own "Berechnen" button
can't be invoked directly from outside while `uiwait` is blocking the
caller -- but a MATLAB `timer` **does** still fire during `uiwait` (it
keeps the graphics/event queue alive), so the full path was verified
headlessly anyway: a `fixedSpacing` timer polls for the popup figure
(`findall(0,'Type','figure','Name','Kennfeld berechnen')`) and clicks its
"Berechnen" button's `ButtonPushedFcn` once the dialog exists, while the
main test script's call to `app.KennfeldCalcButton.ButtonPushedFcn(...)`
is still blocked inside `uiwait` waiting for exactly that click. Confirmed
this way: popup -> confirm -> calculation -> plot end-to-end (same point
count as the direct-call version tested before the popup existed);
per-dataset visibility checkbox (hide -> placeholder text, show -> scatter
back); per-dataset "Entfernen". Separately, without the popup: the
`computeSteadyStateMask` two-pointer algorithm against synthetic data with
a known transient region, and the `.mat` save/load round trip. Real visual
layout/polish still only checked by the user running it interactively.

Useful validation snippet (checks every `buildSignalGroups.m` key actually
exists in the DBC — run this after editing either file):

```matlab
addpath(pwd);
dbc = parseDBC('SAM_CAN.dbc');
validKeys = {};
for m = 1:numel(dbc)
    for s = 1:numel(dbc(m).signals)
        validKeys{end+1} = [dbc(m).name '.' dbc(m).signals(s).name];
    end
end
groups = buildSignalGroups();
% ...then check every Gauges/Plots/Lamps/StatusLabels/Sections{*}.Key
% against validKeys; see conversation history for the full script.
```

## Possible next steps

- Efficiency map: **spatial** binning/averaging landed (see "3D
  Kennfeldfläche popup" above -- `binKennfeldPoints`, a separate
  gridded-surface popup rather than changing the main 2D scatter tab,
  which still shows the unaveraged raw cut by design). **Temporal**
  averaging/resampling (e.g. onto a fixed-rate time grid before spatial
  binning, so a long idle/steady period doesn't just contribute one point
  per CAN message while a fast transient contributes many) is still not
  implemented -- worth adding if particular regions still look
  over/under-weighted by how often the vehicle happened to sit there.
- Add `.trc` v1.1 support if the older log files matter — the only
  available charging-session traces (`Charging_did_not_Start.trc`, etc.)
  are v1.1, so `DCDC_HV_Current` (currently 0 in every drivable trace)
  can't be validated without either v1.1 support or a fresh v2.0 charging
  capture
- Pin down real scale factors for `DCDC_HV_Current`, `Voltage_12V`,
  `Ustopcharge` (would need either more firmware source, e.g. the display
  code that formats these for the dashboard, or a known-good reference
  reading to back-calculate the constant)
- Firmware-confirm the `0.005` Nm/count torque scale (`requested_torque`/
  `skai_torque`) if a SKAI motor-controller firmware/CAN spec source ever
  turns up — currently inferred purely from the raw `±10000` clip point
  matching the vehicle's known ~50Nm max, see "Inferred, not
  firmware-confirmed" above
- Proper multiplex decode for `Charger_information_2`/time-sync if charger
  diagnostics become more important
- Consider adding an event log (not just live lamps) for the Errors tab —
  a scrolling list of "fault X went active at t=…" would need edge
  detection across the whole trace, not just point-sampling at the
  scrubbed time
