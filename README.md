# SAM CAN Log Viewer

A MATLAB app for browsing and decoding PCAN-View `.trc` CAN bus traces from the SAM electric vehicle, decoded against a DBC file (`SAM_CAN.dbc`). Load a trace, scrub through it on a timeline, and watch gauges, plots, lamps, and status panels for Battery, Motor, Charger, Vehicle, and Errors update live.

The timeline has real-time play/pause and single-message step forward/back controls. A separate "CAN Ausgabe (PEAK)" tab can replay the loaded trace's raw frames onto a real CAN bus through a PEAK-System USB adapter, using those same play/step controls — useful for testing a diagnostic display without the vehicle. This tab requires the MATLAB Vehicle Network Toolbox and the PEAK PCAN-Basic driver; it degrades gracefully (falls back to MATLAB's Virtual CAN channels) if no PEAK adapter is detected.

A third standalone tab, "Effizienz-Kennfeld", builds a motor efficiency map (speed vs. torque, colored by overall efficiency computed from actual torque, speed, and battery power) from the currently loaded trace on button press, and can save/load/combine maps from multiple trace files. By default it uses the 10 Hz battery current (0x386), a steady-state filter, subtracts the auxiliary base load, and corrects the motor controller's torque estimate with a per-trace gain k estimated from motoring vs. regen points at equal speed and torque (no reference measurement needed). See [`PROJECT_NOTES.md`](PROJECT_NOTES.md) for the efficiency formula and sign-convention details.

The "Zell-Innenwiderstand" tab estimates each of the 36 cells' effective internal resistance from its voltage drop under load (ΔU/ΔI between consecutive readings of the same cell, current from 0x386 shifted by the auto-detected ~1 s voltage measurement lag), shown as a sortable table plus a per-cell deviation-from-median bar chart. Method and data findings are in [`PROJECT_NOTES.md`](PROJECT_NOTES.md).

## Download

A ready-to-run Windows installer is included: [`CanTraceViewer_Setup.exe`](CanTraceViewer_Setup.exe). It downloads and installs the free MATLAB Runtime (R2026a) during setup (internet connection required), so no MATLAB installation is required to run the app.

## Running from source (requires MATLAB)

```matlab
CanTraceViewer                       % opens empty, use "Load .trc file" button
CanTraceViewer('path\to\file.trc')   % opens and immediately loads a file
```

## Supported trace formats

- PCAN-View `.trc` (v2.0)
- SAMPlay logger `.TXT` exports

## Project layout

| File | Purpose |
|---|---|
| `CanTraceViewer.m` | The app: UI construction, load/decode pipeline, scrub/update logic |
| `SAM_CAN.dbc` | DBC describing the vehicle's CAN messages/signals |
| `parseDBC.m` | Generic DBC parser |
| `parseTRC.m` | Parser for PCAN-View `.trc` files |
| `parseSAMPlay.m` | Parser for SAMPlay logger `.TXT` exports |
| `decodeSignalRaw.m` | Bit-level signal extraction (Intel/Motorola, signed/unsigned) |
| `decodeMessages.m` | Decodes every DBC signal present in a parsed trace |
| `buildSignalGroups.m` | Defines which signals appear on which UI tab |
| `decodeFecuErrors.m` | Decodes the FECU fault bitmask into human-readable text |

See [`PROJECT_NOTES.md`](PROJECT_NOTES.md) for full architecture notes, the reasoning behind every signal-decode correction (many were reverse-engineered and cross-checked against vehicle firmware), and known limitations.
