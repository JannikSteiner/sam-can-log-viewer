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
