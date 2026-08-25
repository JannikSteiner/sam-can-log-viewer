# SAM CAN Log Viewer

A MATLAB app for browsing and decoding PCAN-View `.trc` CAN bus traces from the SAM electric vehicle, decoded against a DBC file (`SAM_CAN.dbc`). Load a trace, scrub through it on a timeline, and watch gauges, plots, lamps, and status panels for Battery, Motor, Charger, Vehicle, and Errors update live.

## Download

A ready-to-run Windows installer is included: [`CanTraceViewer_Setup.exe`](CanTraceViewer_Setup.exe). It bundles the MATLAB Runtime, so no MATLAB installation is required to run the app.

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
