# DriverHub PS v2.0

Windows PowerShell 5.1 (Administrator), PowerShell-only driver scanning, staged installation and Wi-Fi diagnostics.

## Quick start

Review [DriverHub.ps1](./DriverHub.ps1) before running it. In **Windows PowerShell as Administrator**:

```powershell
irm https://raw.githubusercontent.com/jhayeroe/driverhub-ps/main/DriverHub.ps1 | iex
```

## Menus

**1. Scan missing drivers / device problems (Windows Update)**

- Detects present PnP devices with Device Manager errors (including missing driver Code 28).
- Queries the Windows Update Agent for available driver packages.
- Stays on the results screen until you choose: install all, multi-select, deep scan, re-scan, or main menu.
- If Windows Update has no applicable driver packages, explicitly offers Deep Scan.

**2. Deep Scan (outside Windows Update)**

- Scans present device problems, network adapter error statistics, and WLAN/System event log warnings.
- Checks compatible manufacturer driver CLI catalogs if already installed:
  - Dell Command | Update: driver-only scanning and application.
  - HP Image Assistant (selected supported business models): auto-installable drivers only, if HPIA is installed.
  - Lenovo System Update: driver-only package filter.
- Offers numbered choices:
  1. Install all eligible drivers **including** Windows Update.
  2. Install all eligible external OEM / local drivers **excluding** Windows Update.
  3. Multi-select Windows Update drivers, imported local INF packages, and OEM **batch** updates.
- The OEM batch utility does **not** expose each individual OEM package as a numbered selection in this script.
- Settings offers a confirmed winget installation of Dell Command Update or Lenovo System Update on a compatible manufacturer's system. HP Image Assistant must currently be installed from HP support.
- Supports manually imported **official manufacturer INF folders** installed via Windows PnPUtil.

**3. Settings** — Backup, restore-point attempt, OEM setup, local INF import, CSV reports.

**4. Wi-Fi diagnostics and repair** — Event logs, network adapter error counters, manual Wi-Fi device restart, hardware rescan. This repair menu does not automatically uninstall drivers or reset network configuration.

**5. Exit**

## Safety and limitations

- Before the first installation pass of a session, backs up existing third-party driver packages via `pnputil /export-driver` (enabled by default), and tries a Windows restore point when enabled. A restore point may fail if System Protection is not configured or because of OS throttling.
- Backup is of **third-party driver store packages**, not a whole-system image.
- Excludes BIOS, UEFI, firmware and beta packages from Windows Update driver installations.
- Only signed publisher-verified OEM CLI executables are launched automatically.
- OEM catalog support is **not universal**. PCs without a compatible installed manufacturer utility or extracted OEM INF folder cannot fetch driver downloads outside Windows Update using this script.
- Windows Update availability does not prove a driver matches a specific Code 28 issue; verify hardware status after updating.
- A Wi-Fi instability event does not conclusively prove the driver is out of date; signal, router, power settings, TCP/IP, or interference could also be responsible.
- Does not intentionally trigger a reboot, but vendor installers can have their own behavior, and reboots may be required to finish driver updates.
- Requires internet for online scans. OEM installation and Wi-Fi device restart may temporarily disconnect the network.
- Not tested against the user's PC. Use the scan and diagnostics options first.

## Local data

Logs, session transcripts, CSV reports, driver exports and local INF repository are placed under:

`C:\ProgramData\DriverHubPS\`

## Official reference documentation

- [Microsoft PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)
- [Windows Update Agent Search](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search)
- [Dell Command Update CLI](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-command-line-interface)
- [Lenovo System Update CLI](https://docs.lenovocdrt.com/guides/sus/su_dg/su_dg_ch5/)
- [HP Image Assistant documentation](https://ftp.hp.com/pub/caps-softpaq/cmit/whitepapers/HPIAUserGuide.pdf)
