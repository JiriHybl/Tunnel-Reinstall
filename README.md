# Microsoft Tunnel Operations Toolkit

This repository contains customer-ready Microsoft Tunnel operational guides and an automation script for Microsoft Tunnel Gateway re-enrollment.

## Repository structure

### Script and runbook

- [`tunnelreinstall/`](./tunnelreinstall/)
  - [`Invoke-TunnelReinstall.ps1`](./tunnelreinstall/Invoke-TunnelReinstall.ps1) — PowerShell automation for Tunnel Gateway re-enrollment
  - [`README.md`](./tunnelreinstall/README.md) — full usage instructions, prerequisites, and troubleshooting for the script

### Gateway operations guides

- [`Microsoft_Tunnel_Troubleshooting_Guide.md`](./Microsoft_Tunnel_Troubleshooting_Guide.md) — architecture, diagnostics, common issues, and resolution runbooks
- [`Private_CA_Microsoft_Tunnel_Guide.md`](./Private_CA_Microsoft_Tunnel_Guide.md) — deploying and renewing a Microsoft Tunnel TLS certificate issued by a private CA
- [`Certbot_Automation_Guide.md`](./Certbot_Automation_Guide.md) — automated Let’s Encrypt renewal + Tunnel certificate import workflow

### Client configuration guides

- [`Microsoft_Tunnel_Client_Configuration_Guide_Android.md`](./Microsoft_Tunnel_Client_Configuration_Guide_Android.md) — customer-ready Android Enterprise client setup with Microsoft Defender + Microsoft Tunnel
- [`Microsoft_Tunnel_Client_Configuration_Guide_iOS_iPadOS.md`](./Microsoft_Tunnel_Client_Configuration_Guide_iOS_iPadOS.md) — customer-ready iOS/iPadOS client setup with Microsoft Defender + Microsoft Tunnel

## Suggested reading order

1. Start with [`Microsoft_Tunnel_Troubleshooting_Guide.md`](./Microsoft_Tunnel_Troubleshooting_Guide.md).
2. Choose certificate lifecycle guidance:
   - Private CA: [`Private_CA_Microsoft_Tunnel_Guide.md`](./Private_CA_Microsoft_Tunnel_Guide.md)
   - Public CA automation: [`Certbot_Automation_Guide.md`](./Certbot_Automation_Guide.md)
3. Use the platform client guide:
   - Android: [`Microsoft_Tunnel_Client_Configuration_Guide_Android.md`](./Microsoft_Tunnel_Client_Configuration_Guide_Android.md)
   - iOS/iPadOS: [`Microsoft_Tunnel_Client_Configuration_Guide_iOS_iPadOS.md`](./Microsoft_Tunnel_Client_Configuration_Guide_iOS_iPadOS.md)
4. Use script automation from [`tunnelreinstall/`](./tunnelreinstall/) when re-enrollment is required.
