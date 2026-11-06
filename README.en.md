# Cellmori

[中文](README.md) · [Build guide](docs/BUILDING.md) · [Security](SECURITY.md)

A native menu bar battery manager for Apple Silicon MacBooks. Cellmori supports charge limits, a temporary full charge, discharge targets, battery information and local history.

App/helper version: **0.6.0**. License: **MIT**. This is development software, not a notarized production release.

## Features

- Daily charge ceiling from 40% to 100%, with a five percentage point recharge band.
- Temporary full-charge and plugged-in discharge workflows; stop a workflow to restore the saved daily ceiling.
- Battery percentage and system-reported power source in the menu bar.
- Battery health information, temperature, cycles, local seven-day history and CSV export.
- Authenticated local XPC control, without a password prompt for each daily change.
- Backend status, capability diagnostics, optional Dock visibility and an experimental adapter backend.

Calibration is an observation workflow, not a repair for battery wear or a battery gauge reset. A complete calibration cycle has not been hardware-validated.

## Compatibility

The installer accepts Apple Silicon and macOS 15.x / 26.x. Hardware control depends on the actual firmware and write permissions. Earlier hardware observations were on an M1 MacBook running macOS 15.8.2. The renamed 0.6.0 release has not completed end-to-end hardware acceptance. macOS 26, other models and the experimental adapter mode remain unverified.

## Build

Use an Apple Silicon Mac with Xcode Command Line Tools. The known development toolchain is Swift 6.1.2; no external package dependencies are required.

```sh
bash test.sh
bash build.sh
bash build-installer.sh
```

Outputs: `Cellmori.app` and `dist/Cellmori-0.6.0-arm64.pkg`. Build/test commands do not install a daemon or change charging policies. Tests do not access SMC hardware.

The app and helper use ad-hoc signatures with Hardened Runtime. The PKG is unsigned and unnotarized. Do not disable SIP or system-wide security protections to run it.

## Install and remove

Open the PKG, install on the current boot volume and launch `/Applications/Cellmori.app`. The optional backend is selected by default. A fresh installation leaves charging under system management; select and apply a daily limit explicitly.

Backend identifier: `io.cellmori.helper`. Installing/updating/removing it requires administrator authorization. Daily control uses XPC with code-hash and account checks. Rebuilding the app requires updating its backend binding.

Stopping a temporary workflow restores the saved daily limit. “交还系统管理” returns to settings captured before Cellmori took control. Quitting the GUI leaves the daemon running. Remove the daemon from the backend page before deleting the app.

## Documentation

Detailed guides are currently in Chinese: [usage](docs/USAGE.md), [architecture](docs/ARCHITECTURE.md), [troubleshooting](docs/TROUBLESHOOTING.md), [privacy](PRIVACY.md), [contributing](CONTRIBUTING.md) and [release checklist](docs/RELEASING.md).

Source and original documentation are licensed under [MIT](LICENSE). Preserve copyright and permission notices when distributing copies or substantial portions. Third-party rights and trademark questions are separate. The project is not affiliated with or endorsed by Apple or other battery-management vendors.
