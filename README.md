# Field'o'Meter — QField Plugin

Geological strike, dip, dip-direction, and plunge measurement plugin for QField with sampling-based averaging, outlier rejection, calibration checks, and feature-form auto-fill.

## What it does

- Samples the phone's compass and accelerometer over a configurable window (default 2 s)
- Rejects outliers (trims top/bottom 10%)
- Reports median values with ± standard deviation as an uncertainty estimate
- Warns when:
  - the phone's compass is uncalibrated
  - magnetic field strength suggests interference (metal nearby)
  - the surface is near horizontal or vertical (dip direction unstable)
- Auto-fills QField feature form fields by name match (case-insensitive)

## Recognized field names (in your QGIS layer)

| Quantity        | Field name variants                                          |
| --------------- | ------------------------------------------------------------ |
| Strike          | `strike`, `strike_rhr`, `strike_ref`                         |
| Dip             | `dip`, `dip_angle`, `dip_ref`, `pendage`                     |
| Dip direction   | `dip_direction`, `dipdirection`, `dip_dir`, `dipdir_ref`     |
| Plunge          | `plunge`, `plongement`                                       |
| Azimuth         | `azimuth`, `azimut`, `heading`                               |
| Dip uncertainty | `dip_err`, `dip_uncertainty`                                 |
| Strike uncertainty | `strike_err`, `strike_uncertainty`                        |

Add any of these as integer (or real for the uncertainty fields) attributes to your structures point layer.

## Installation

1. Zip the contents of this folder (not the folder itself). `main.qml` and `metadata.txt` must be at the root of the zip.
2. Name it e.g. `fieldometer-plugin-v1.0.zip`.
3. Transfer to your phone.
4. In QField: Settings → Plugins → Install plugin from file → choose the zip.
5. Grant permission when prompted.

## Usage

- A button labelled **Field'o'Meter** appears in the QField plugins toolbar.
- The button shows live strike / dip / dip direction in real time.
- Tap the button to start a sampling window. Hold the phone steady on the surface for the duration (default 2 s).
- A dialog shows the median values with uncertainties. Tap **Apply** to write into the feature form, or **Retake** to sample again.
- If a feature form is open when you sample, the values can also auto-fill (toggle on/off in settings).
- **Long-press** the button to open settings (declination, hemisphere, sample duration, auto-fill).

## Status indicator

The button changes colour based on sensor state:

| Colour | Meaning                                              |
| ------ | ---------------------------------------------------- |
| Green  | Sensors look good                                    |
| Orange | Compass needs calibration, or magnetic interference  |
| Red    | Compass calibration very poor — wave phone in figure-8 |
| Blue   | Sampling in progress                                 |

## Honest limitations

- Phone magnetometer accuracy under best conditions is roughly ±2°. Inside a vehicle, near metal, or with poor calibration, it can be much worse.
- Use the uncertainty figures (± values) to judge whether a reading is reliable enough for your purpose.
- For critical structural measurements in publication-quality work, cross-check with a calibrated geological compass.
- Tilt instability near horizontal (dip < 5°) or vertical (dip > 85°) is a fundamental geometric limit — the dialog warns you when you're in that range.

## Credit

The core gravity-vector + azimuth approach to deriving strike/dip is adapted from the open-source [swaxi/compass](https://github.com/swaxi/compass) plugin. Significant additions in this version: sampling and averaging, outlier rejection, calibration and interference detection, persistent settings, uncertainty reporting, tilt-instability warnings, and improved UI.
