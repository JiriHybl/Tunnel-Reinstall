# Microsoft Tunnel Gateway Troubleshooting Guide

**Microsoft Intune | Enterprise Mobility**  
**April 2026**

This guide provides a structured troubleshooting methodology for Microsoft Tunnel Gateway deployments on Linux servers managed by Microsoft Intune. It covers common failure scenarios during installation, enrollment, certificate management, and ongoing health monitoring.

> **Note**
> This guide is based on Microsoft documentation at `learn.microsoft.com/intune` and reflects best practices for Microsoft Tunnel Gateway v2024+.

## 1. Architecture Overview

Microsoft Tunnel Gateway is a VPN solution built into Microsoft Intune that enables secure access to on-premises resources from iOS and Android devices.

### 1.1 Key Components

The solution includes the following Linux container components:

- `mstunnel-agent` — Intune management connector. Handles enrollment, configuration retrieval, certificate management, and telemetry. Communicates outbound on port 443.
- `mstunnel-server (ocserv)` — VPN gateway process. Handles client connections, IP assignment, and traffic routing.
- `mstunnel_monitor` — Watchdog service that monitors container health and restarts failed services.
- `mst-cli` — Management CLI tool for service control and diagnostics.

### 1.2 Key Files and Directories

| File / Directory | Purpose |
|---|---|
| `/etc/mstunnel/env.sh` | Environment variables for Tunnel installation (proxy, server name, environment). |
| `/etc/ocserv/agent-info.json` | Created after successful enrollment. Contains `AgentId`, `TenantId`, and certificate `RenewalDate`. |
| `/etc/mstunnel/private/agent.p12` | PKCS#12 certificate for agent authentication to Intune. Auto-renewed. |
| `/etc/mstunnel/certs/active.crt` | Active TLS certificate used by VPN server for client connections. |
| `/etc/mstunnel/private/active.key` | Private key for the active TLS certificate. |
| `/etc/mstunnel/certs/site.crt` | TLS certificate imported during `mstunnel-setup`. |
| `/etc/ocserv/ocserv.conf` | VPN server configuration generated from Intune Server Configuration. |
| `/etc/ocserv/admin-settings.json` | Serialized Server Configuration from Intune, created after enrollment. |

### 1.3 Network Requirements

Required outbound connectivity:

- `443/TCP` and `443/UDP` — Intune management communication and VPN client connectivity.
- `80/TCP` — CRL/OCSP certificate revocation checks for TLS validation.
- Access to `*.manage.microsoft.com`, `*.msocsp.com`, and revocation endpoints defined in your TLS certificate.

> **Important**
> Tunnel management uses mutual TLS with Intune. Outbound proxies must **not** perform SSL inspection on these connections.

## 2. Diagnostic Tools and Commands

### 2.1 `mst-cli` Commands

```bash
sudo mst-cli server status     # Check VPN server health
sudo mst-cli agent status      # Check management agent health
sudo mst-cli server restart    # Restart VPN server
sudo mst-cli agent restart     # Restart management agent
sudo mst-cli agent logs        # View agent logs
sudo mst-cli server logs       # View server logs
```

### 2.2 Connectivity Diagnostic Script

```bash
sudo /etc/ocserv/diagnostic/agent/mst-check-agent-connectivity.sh
```

All three tested endpoints should return HTTP 200:

- `MicrosoftTunnelService` — Enrollment and certificate operations.
- `MobileAccessService` — Policy and configuration retrieval.
- `MobileAccessServiceAgents` — Agent registration and telemetry.

### 2.3 Journal Logs

```bash
sudo journalctl -t mstunnel-agent -n 100 --no-pager
sudo journalctl -t mstunnel-agent --since '1 hour ago' --no-pager
sudo journalctl -t mstunnel_monitor -f
sudo journalctl -t ocserv -n 50 --no-pager
```

### 2.4 Enabling Verbose Logging

Before running setup:

```bash
export mst_verbose_log="true"
sudo -E ./mstunnel-setup
```

Permanent setting in `/etc/mstunnel/env.sh`:

```bash
mst_verbose_log="true"
```

### 2.5 Intune Admin Center Health Dashboard

Go to:  
`Tenant administration > Microsoft Tunnel Gateway > Health status > [Server] > Health check`

Key metrics include:

- Management agent certificate expiration
- TLS certificate expiration and revocation status
- Internal network accessibility
- Server configuration application status
- Server version and upgradeability

## 3. Common Issues and Resolutions

### 3.1 Server Reported as Unhealthy in Intune

Common root cause: TLS certificate revocation check failures (`RevocationStatusUnknown`), often due to blocked CRL/OCSP access.

#### Symptoms

- Intune shows server as **Unhealthy** or TLS revocation as **Unhealthy**.
- Agent logs contain:
  - `Certificate is missing BasicConstraints extension, checking KeyUsage to determine if CA.`
  - `CheckRevocationOnFullChain: Revocation check failed. RevocationStatusUnknown or OfflineRevocation.`

#### Diagnostic Steps

```bash
# Identify OCSP/CRL endpoints in TLS cert
sudo openssl x509 -in /etc/mstunnel/certs/active.crt -text -noout | \
grep -A3 'OCSP\|CRL\|Authority Information'

# Test endpoint connectivity
curl -v http://<ocsp-or-crl-endpoint> 2>&1 | head -20

# Test DNS resolution
dig <ocsp-hostname>
dig @8.8.8.8 <ocsp-hostname>
```

#### Resolution

- Ensure outbound port 80 is open.
- Verify DNS resolution for CRL/OCSP endpoints from the server.
- If using internal CA certs with `ldap://` CRL URLs, replace with a public CA cert using HTTP-based CRL/OCSP.
- For Let's Encrypt, ensure connectivity to required OCSP domains.

> **Tip**
> Let's Encrypt is supported. Use `fullchain.pem` (not `cert.pem`) and ensure the server FQDN exists in the certificate SAN.

### 3.2 TLS Certificate Replacement

#### Certificate File Locations

- `/etc/mstunnel/certs/site.crt` — Certificate chain (PEM, fullchain)
- `/etc/mstunnel/private/site.key` — Private key (PEM)
- `/etc/mstunnel/certs/active.crt` — Active certificate (managed by agent)
- `/etc/mstunnel/private/active.key` — Active private key (managed by agent)

#### Replacement Procedure

```bash
# Copy new certificate files
sudo cp /path/to/fullchain.pem /etc/mstunnel/certs/site.crt
sudo cp /path/to/privkey.pem /etc/mstunnel/private/site.key

# Import cert (preferred)
sudo mst-cli import_cert

# Or re-run setup
sudo /path/to/mstunnel-setup
```

After replacement, the agent uploads the new cert to Intune on the next heartbeat. Confirm in logs with `TLS certs upload successful`.

### 3.3 Agent Enrollment Failure

Enrollment failures often appear as `Certificate: null` in `agent-info.json` and HTTP 400 from `MicrosoftTunnelService`.

#### Symptoms

- `agent-info.json` is missing or shows `Certificate: null`.
- Diagnostic script shows `MicrosoftTunnelService ... HTTP/1.1 400`.
- Agent logs show no successful MicrosoftTunnelService communication.

#### Re-run Enrollment

```bash
export mst_verbose_log="true"
sudo -E /path/to/mstunnel-setup
```

Authenticate when prompted:

- `https://login.microsoft.com/device`
- Enter the displayed code and sign in with an Intune Administrator or Global Administrator account.

> **Important**
> Device codes expire quickly. Authenticate immediately when shown.

#### Verify Enrollment

```bash
# Certificate should not be null
sudo cat /etc/ocserv/agent-info.json

# Verify agent cert details
sudo openssl pkcs12 -in /etc/mstunnel/private/agent.p12 -nokeys -passin pass: 2>/dev/null | \
openssl x509 -text -noout | grep -E 'Issuer:|Subject:|Not After'
```

Expected:

- Issuer includes `CN = Microsoft Tunnel Agent CA`
- Subject matches the Server ID in Intune

## 4. Server Configuration Issues

### 4.1 Server Configuration Could Not Be Applied

This status means configuration was received from Intune but failed to apply locally.

#### Diagnostic Steps

```bash
sudo mst-cli server status
sudo journalctl -t mstunnel-agent --since '30 minutes ago' --no-pager | grep -i 'config\|error\|fail'
sudo cat /etc/ocserv/admin-settings.json
```

#### Resolution Steps

- In Intune:  
  `Tenant administration > Microsoft Tunnel Gateway > Server configurations > [Your Config] > Review + save` to repush.
- Restart services:
  - `sudo mst-cli server restart`
  - `sudo mst-cli agent restart`
- Verify Server configuration references a valid Site and resolvable Site FQDN.

### 4.2 Environment Variables (`env.sh`)

Review:

```bash
sudo cat /etc/mstunnel/env.sh
```

| Variable | Description |
|---|---|
| `intune_env=PE` | Production Environment. Correct for production and trial tenants; do not change. |
| `ServerName=TUNNEL1` | Tunnel server hostname registered in Intune. |
| `LANG=C.UTF-8` | Locale setting for Tunnel containers. |
| `http_proxy` / `https_proxy` | Proxy address if outbound traffic uses proxy. |
| `mst_verbose_log=true` | Verbose diagnostics; remove after troubleshooting. |

> **Note**
> `intune_env=PE` is the default and correct value for standard tenants, including trial tenants.

### 4.3 Server Version Warning

`One update behind` means Tunnel containers are not on the latest release. Keep servers updated for supportability.

- Enable automatic upgrades in Site config (`Automatically upgrade servers at this site = Yes`), or
- Re-run `mstunnel-setup` to pull latest images from `mcr.microsoft.com`.

## 5. Preventive Measures and Best Practices

### 5.1 Certificate Management

- Prefer public CAs (Let's Encrypt, DigiCert) over internal CAs.
- Deploy full chain (`fullchain.pem`), not only the leaf certificate.
- Monitor TLS cert expiration in Intune Health check.
- Automate renewal with `certbot` and a deploy hook.

Example deploy hook:

```bash
#!/bin/bash
# /etc/letsencrypt/renewal-hooks/deploy/tunnel-cert-update.sh
cp /etc/letsencrypt/live/tunnel1.example.com/fullchain.pem /etc/mstunnel/certs/site.crt
cp /etc/letsencrypt/live/tunnel1.example.com/privkey.pem /etc/mstunnel/private/site.key
mst-cli import_cert
```

### 5.2 Network Configuration

- Ensure stable outbound access on ports 443 and 80.
- Ensure DNS can resolve both internal resources and external CRL/OCSP endpoints.
- If using internal DNS in Server Configuration, configure external forwarders.
- Avoid DNS resolvers that hijack NXDOMAIN responses.

### 5.3 Monitoring and Alerting

- Export Tunnel health diagnostics to Azure Monitor or Log Analytics.
- Review health trends regularly to catch slow degradation.
- Alert on management agent certificate expiration (warning threshold: 30 days).

### 5.4 Documentation and Change Management

- Document installation parameters (OS version, FQDN, cert source/renewal, Intune Site/Config names).
- Back up key files before cert changes or rerunning setup:
  - `/etc/mstunnel/certs/active.crt`
  - `/etc/mstunnel/private/active.key`
  - `/etc/ocserv/agent-info.json`
  - `/etc/mstunnel/env.sh`
- Test certificate replacements in a lab before production rollout.

### 5.5 References

- [Install Microsoft Tunnel](https://learn.microsoft.com/intune/protect/microsoft-tunnel-configure)
- [Microsoft Tunnel Prerequisites](https://learn.microsoft.com/intune/protect/microsoft-tunnel-prerequisites)
- [Monitor Microsoft Tunnel](https://learn.microsoft.com/intune/protect/microsoft-tunnel-monitor)
- [Microsoft Tunnel Reference (files and commands)](https://learn.microsoft.com/intune/protect/microsoft-tunnel-reference)
- [Microsoft Tunnel Overview](https://learn.microsoft.com/intune/protect/microsoft-tunnel-overview)

---

Prepared from Microsoft Intune documentation and operational troubleshooting experience (April 2026).
