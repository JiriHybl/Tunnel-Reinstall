# Tunnel-scripts

PowerShell scripts for troubleshooting and re-enrolling Microsoft Tunnel Gateway servers from a Windows machine.

## Scripts

### `Invoke-TunnelReinstall.ps1`

Automates the full re-enrollment of a Microsoft Tunnel Gateway server. Supports three connection modes:

| Mode | How it connects | Use when |
|------|----------------|----------|
| `SSH` | Native `ssh.exe` with a private key | Direct network access to the Tunnel server |
| `AzureVM` | Azure VM Run Command (Az PowerShell) | No direct SSH access; VM is in Azure |
| `Bastion` | Azure Bastion + `ssh.exe` | No direct SSH access; Azure Bastion is deployed |

#### What the script does

1. Connects to the Linux Tunnel server
2. Stops Tunnel services (`mst-cli agent/server stop`)
3. Backs up and removes `agent-info.json` and agent certificates to force re-enrollment
4. Backs up the current TLS certificate
5. Downloads the latest `mstunnel-setup` from Microsoft
6. Runs `mstunnel-setup` interactively — you will see the **Entra ID device code** in the console
7. Starts Tunnel services and waits for them to become healthy
8. Runs built-in connectivity diagnostics
9. Optionally queries Intune Graph API for server health status

---

## Prerequisites

### SSH mode

- **Windows 10/11** with OpenSSH Client enabled (built-in since version 1809)
  - To verify: `ssh -V` in PowerShell
  - To enable if missing: *Settings → System → Optional Features → Add a feature → OpenSSH Client*
- An **SSH private key** for the Tunnel server (see below)
- Direct network connectivity to the Tunnel server on port 22

### AzureVM mode

- Az.Compute PowerShell module: `Install-Module Az.Compute -Scope CurrentUser`
- An active Azure session: `Connect-AzAccount`

### Bastion mode

- Azure CLI: https://aka.ms/installazurecliwindows
- Bastion extension: `az extension add --name bastion`
- OpenSSH Client (same as SSH mode above)
- An SSH private key for the Tunnel server

---

## How to get an SSH key for the Tunnel server

SSH mode requires **key-based authentication**. Password authentication is not supported (Windows `ssh.exe` has no non-interactive password flag).

### Option A — Generate a new key pair and copy the public key to the server (recommended)

Run these steps **on your Windows machine**:

```powershell
# 1. Generate an ED25519 key pair (modern, fast, secure)
ssh-keygen -t ed25519 -C "tunnel-admin" -f "$env:USERPROFILE\.ssh\tunnel_id_ed25519"
# When prompted for a passphrase, press Enter for no passphrase (or set one for extra security)

# 2. Copy the public key to the Tunnel server
#    Replace 10.0.0.15 and username with your values
$pubKey = Get-Content "$env:USERPROFILE\.ssh\tunnel_id_ed25519.pub"
& ssh username@10.0.0.15 "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
# This step will prompt for your password ONE time

# 3. Test key-based login (should connect without a password prompt)
ssh -i "$env:USERPROFILE\.ssh\tunnel_id_ed25519" username@10.0.0.15 "echo connected"
```

### Option B — Use an existing key

If the server already has your public key in `~/.ssh/authorized_keys`, just point `-SshKeyPath` at your existing private key file (e.g. `~/.ssh/id_rsa` or a `.pem` file).

### Option C — Export key from Azure (if VM was created in Azure)

If the VM was created in the Azure portal with an SSH key pair, you can download the private key from:  
*Azure Portal → Virtual Machines → [your VM] → Connect → SSH → Download private key*

---

## Usage

### SSH mode

```powershell
.\Invoke-TunnelReinstall.ps1 `
    -ConnectionMode SSH `
    -SshHost 10.0.0.15 `
    -SshUser username `
    -SshKeyPath "$env:USERPROFILE\.ssh\tunnel_id_ed25519"
```

### AzureVM mode

```powershell
.\Invoke-TunnelReinstall.ps1 `
    -ConnectionMode AzureVM `
    -AzureSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -AzureResourceGroup "rg-tunnel" `
    -AzureVmName "TUNNEL1"
```

### Bastion mode

```powershell
.\Invoke-TunnelReinstall.ps1 `
    -ConnectionMode Bastion `
    -BastionName "XXXXXXX" `
    -BastionResourceGroup "rg-XXXXX" `
    -BastionTargetResourceId "/subscriptions/xxxx/resourceGroups/rg-tunnel/providers/Microsoft.Compute/virtualMachines/TUNNEL1" `
    -BastionUsername "username" `
    -BastionSshKeyPath "C:\Users\me\.ssh\tunnel_id_ed25519"
```

### Optional parameters

| Parameter | Description |
|-----------|-------------|
| `-MstunnelSetupPath` | Path to `mstunnel-setup` on the Linux server (default: `/home/admin/mstunnel-setup`) |
| `-SkipIntuneHealthCheck` | Skip the final Intune Graph API health check |
| `-IntuneClientId` | Azure AD App Client ID for Graph API health check |
| `-IntuneTenantId` | Entra ID Tenant ID for Graph API health check |

---

## During the run — Entra ID device code authentication

When `mstunnel-setup` runs, it will display something like:

```
To sign in, use a web browser to open the page https://microsoft.com/devicelogin
and enter the code ABCD1234 to authenticate.
```

Open the URL in a browser, enter the code, and sign in with an account that has **Intune Administrator** or **Global Administrator** rights. The script will proceed automatically after successful authentication.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Permission denied (publickey)` | Wrong key or key not in `authorized_keys` | Re-run Option A above to copy the public key |
| `Connection refused` | Port 22 not open or wrong IP | Check firewall / NSG rules for port 22 |
| `ssh.exe not found` | OpenSSH Client not installed | Enable via Windows Optional Features |
| `mstunnel-setup exited with code 1` | Setup failed — check output above | Look for certificate or network errors in the console output |
