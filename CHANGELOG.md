# Changelog

All notable changes to PCScope are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [semantic versioning](https://semver.org/).

## [1.0.0] - 2026-11-17

First stable release. Download `PCScope-1.0.0.zip`, extract it and run `PCScope.ps1 -Open`: nothing else to install.

### Inventory
- Read-only collector for Windows PowerShell 5.1: hardware, storage (SMART, BitLocker), battery, Windows (updates, pending restart), security (antivirus, firewall, UAC, Secure Boot, local administrators), network, users and installed software.
- Works without administrator rights; each section is collected independently and failures are reported, not fatal.

### Dashboard
- Self-contained HTML dashboard (no server, no internet, no external libraries) with devices, issues, changes and software views, and a detail page per device.
- English and Spanish, following the browser language, with an ES/EN button and `?lang=` links.
- CSV export from every view; light and dark themes; works on mobile.

### Health rules
- 18 configurable rules in `rules.json`: disk space and health, antivirus, firewall, UAC, Windows updates, unsupported Windows, BitLocker on laptops, battery wear, local administrators, blocked and outdated software, stale inventories and more.

### Whole-office collection
- Remote collection over WinRM (`-ComputerName`, `-ComputerListPath`, `-Credential`), in parallel, with a list of failed computers to retry.
- Scheduled-task installer (`tools/Install-PCScopeTask.ps1`) running as SYSTEM daily, at startup or at logon, writing to a shared folder.

### History and alerts
- History of previous inventories per device and a timeline of changes (software, updates, storage, security, hardware, network, users), with security-relevant changes flagged for review.
- `-ExportCsv` for devices, issues, software and changes (Excel-ready).
- Telegram and email alerts for new critical issues and flagged changes, without repeats; secrets only from environment variables.

### Quality
- More than 130 Pester tests and PSScriptAnalyzer on Windows PowerShell 5.1 in GitHub Actions, including a real WinRM collection.
- Live demo on GitHub Pages with a generated fleet of 25 fictitious devices, rebuilt weekly.

[1.0.0]: https://github.com/DavidGoRi/PCScope/releases/tag/v1.0.0
