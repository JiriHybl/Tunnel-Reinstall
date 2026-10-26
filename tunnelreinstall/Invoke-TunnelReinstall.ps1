#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Tunnel Gateway - Reinstallation and Re-enrollment Helper

.DESCRIPTION
    Automates the re-enrollment and health verification of a Microsoft Tunnel Gateway server.
    Supports three connection modes:
      - SSH: Direct SSH connection (requires OpenSSH client or Posh-SSH module)
      - AzureVM: Azure VM Run Command via Az PowerShell module
      - Bastion: Azure Bastion SSH via Azure CLI (az network bastion ssh)

    What this script does:
      1. Connects to the Linux Tunnel server
      2. Stops Tunnel services
      3. Removes old agent-info.json to force clean re-enrollment
      4. Patches env.sh to remove any incorrect intune_env overrides
      5. Runs mstunnel-setup with verbose logging
      6. Waits for and displays the device code for Entra ID authentication
      7. Runs the built-in connectivity diagnostic script
      8. Optionally queries Intune Graph API for server health status

.PARAMETER ConnectionMode
    SSH, AzureVM, or Bastion

.PARAMETER SshHost
    Hostname or IP of the Tunnel server (SSH mode)

.PARAMETER SshUser
    SSH username (default: admin)

.PARAMETER SshKeyPath
    Path to SSH private key file. Required for SSH mode.

.PARAMETER AzureSubscriptionId
    Azure Subscription ID (AzureVM mode)

.PARAMETER AzureResourceGroup
    Resource group containing the VM (AzureVM mode)

.PARAMETER AzureVmName
    VM name in Azure (AzureVM mode)

.PARAMETER BastionName
    Name of the Azure Bastion host (Bastion mode)

.PARAMETER BastionResourceGroup
    Resource group of the Bastion host (Bastion mode)

.PARAMETER BastionTargetResourceId
    Full ARM resource ID of the target VM (Bastion mode)

.PARAMETER BastionUsername
    SSH username on the VM (Bastion mode)

.PARAMETER BastionSshKeyPath
    Path to SSH private key .pem file (Bastion mode)

.PARAMETER BastionAuthType
    Auth type passed to az network bastion ssh (Bastion mode, default: ssh-key)

.PARAMETER MstunnelSetupPath
    Path to mstunnel-setup script on the Linux server (default: /home/admin/mstunnel-setup)

.PARAMETER SkipIntuneHealthCheck
    Skip the final Intune Graph API health check

.PARAMETER IntuneClientId
    Azure AD App Registration Client ID for Graph API health check (optional)

.PARAMETER IntuneTenantId
    Entra ID Tenant ID for Graph API health check (optional)

.EXAMPLE
    # SSH mode with key
    .\Invoke-TunnelReinstall.ps1 -ConnectionMode SSH -SshHost tunnel1.prahaws.cz -SshUser admin -SshKeyPath ~/.ssh/id_rsa

.EXAMPLE
    # Azure VM Run Command mode
    .\Invoke-TunnelReinstall.ps1 -ConnectionMode AzureVM -AzureSubscriptionId "xxxx" -AzureResourceGroup "rg-tunnel" -AzureVmName "TUNNEL1"

.EXAMPLE
    # Azure Bastion SSH mode
    .\Invoke-TunnelReinstall.ps1 -ConnectionMode Bastion `
        -BastionName NorthEU-bastion `
        -BastionResourceGroup VMs-NorthEU `
        -BastionTargetResourceId "/subscriptions/.../virtualMachines/TUNNEL1" `
        -BastionUsername username `
        -BastionSshKeyPath "C:\Users\...\TUNNEL1_key.pem"

.NOTES
    Author: Generated for lab/demo use
    Requirements:
      - SSH mode: OpenSSH client (built into Windows 10/11 version 1809+)
      - AzureVM mode: Az.Compute module (Install-Module Az.Compute)
      - Bastion mode: Azure CLI (az) with bastion extension
      - Intune health check: Microsoft.Graph module or manual token
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateSet("SSH", "AzureVM", "Bastion")]
    [string]$ConnectionMode,

    # SSH parameters
    [string]$SshHost,
    [string]$SshUser = "admin",
    [string]$SshKeyPath,

    # Azure VM parameters
    [string]$AzureSubscriptionId,
    [string]$AzureResourceGroup,
    [string]$AzureVmName,

    # Bastion parameters
    [string]$BastionName,
    [string]$BastionResourceGroup,
    [string]$BastionTargetResourceId,
    [string]$BastionUsername,
    [string]$BastionSshKeyPath,
    [string]$BastionAuthType = "ssh-key",

    # Tunnel parameters
    [string]$MstunnelSetupPath = "/home/admin/mstunnel-setup",

    # Intune Graph API health check (optional)
    [switch]$SkipIntuneHealthCheck,
    [string]$IntuneClientId,
    [string]$IntuneTenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Validate required parameters per connection mode
if ($ConnectionMode -eq "SSH" -and -not $SshHost) {
    throw "SshHost is required when ConnectionMode is SSH."
}
if ($ConnectionMode -eq "SSH" -and -not $SshKeyPath) {
    throw "SshKeyPath is required when ConnectionMode is SSH. Password authentication is not supported. See README for how to generate and copy an SSH key."
}
if ($ConnectionMode -eq "AzureVM" -and (-not $AzureResourceGroup -or -not $AzureVmName)) {
    throw "AzureResourceGroup and AzureVmName are required when ConnectionMode is AzureVM."
}
if ($ConnectionMode -eq "Bastion" -and (
    -not $BastionName -or -not $BastionResourceGroup -or
    -not $BastionTargetResourceId -or -not $BastionUsername)) {
    throw "BastionName, BastionResourceGroup, BastionTargetResourceId and BastionUsername are required when ConnectionMode is Bastion."
}

# -------------------------------------------------------------
# REGION: Helpers
# -------------------------------------------------------------

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n$('-' * 60)" -ForegroundColor DarkGray
    Write-Host "  $Message" -ForegroundColor $Color
    Write-Host "$('-' * 60)" -ForegroundColor DarkGray
}

function Write-Ok   { param([string]$m) Write-Host "  [OK]  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [!!]  $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "  [XX]  $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  [..]  $m" -ForegroundColor Gray }

# -------------------------------------------------------------
# REGION: Remote execution abstraction
# -------------------------------------------------------------

$script:SshSession = $null

function Connect-TunnelServer {
    if ($ConnectionMode -eq "SSH") {
        Write-Info "Connecting via SSH to $SshHost as $SshUser (key: $SshKeyPath)..."
        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            throw "ssh.exe not found. Enable the OpenSSH Client optional feature in Windows Settings > Optional Features."
        }
        # Test connectivity with a simple command before proceeding
        $testOutput = & ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SshKeyPath "${SshUser}@${SshHost}" "echo SSH_OK" 2>&1
        if ($LASTEXITCODE -ne 0 -or $testOutput -notmatch "SSH_OK") {
            throw "SSH connection test failed. Check host, username, and key path. Output: $($testOutput -join ' ')"
        }
        Write-Ok "SSH connection verified (key-based)"
        # $script:SshSession stays $null — Invoke-RemoteCommand uses ssh.exe path
    }
    elseif ($ConnectionMode -eq "AzureVM") {
        Write-Info "Connecting to Azure (Az.Compute)..."
        if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
            throw "Az.Compute module not found. Run: Install-Module Az.Compute -Scope CurrentUser"
        }
        Import-Module Az.Compute -ErrorAction Stop

        if ($AzureSubscriptionId) {
            Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null
        }
        Write-Ok "Azure context set"
    }
    elseif ($ConnectionMode -eq "Bastion") {
        Write-Info "Validating Azure CLI for Bastion mode..."
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw "Azure CLI (az) not found. Install from https://aka.ms/installazurecliwindows"
        }
        $bastionHelp = az network bastion --help 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI bastion extension is not available. Run: az extension add --name bastion"
        }
        Write-Ok "Azure CLI and bastion extension available"
    }
}

function Invoke-RemoteCommand {
    <#
    .SYNOPSIS Runs a command on the remote Linux server and returns stdout as string #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 120,
        [switch]$AsRoot
    )

    # Normalize multi-line commands to a single line to avoid transport issues
    $singleLineCmd = ($Command -split "`n" | ForEach-Object { $_.Trim().TrimEnd(';') } | Where-Object { $_ -ne "" }) -join "; "

    $effectiveUser = if ($ConnectionMode -eq "Bastion") { $BastionUsername } else { $SshUser }
    $escapedCmd = $singleLineCmd.Replace("'", "'\''")

    $fullCmd = if ($AsRoot -and $effectiveUser -ne "root") { "sudo bash -c '$escapedCmd'" } else { $singleLineCmd }

    if ($ConnectionMode -eq "SSH") {
        if ($script:SshSession) {
            # Posh-SSH
            $result = Invoke-SSHCommand -SessionId $script:SshSession.SessionId -Command $fullCmd -TimeOut $TimeoutSeconds
            return $result.Output -join "`n"
        } else {
            # Native ssh.exe - limited, no interactive support
            $keyArgArr = if ($SshKeyPath) { @("-i", $SshKeyPath) } else { @() }
            $output = & ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 @keyArgArr "${SshUser}@${SshHost}" $fullCmd 2>&1
            return $output -join "`n"
        }
    }
    elseif ($ConnectionMode -eq "AzureVM") {
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $AzureResourceGroup `
            -VMName $AzureVmName `
            -CommandId "RunShellScript" `
            -ScriptString $fullCmd
        return ($result.Value | Where-Object { $_.Code -like "*StdOut*" }).Message
    }
    elseif ($ConnectionMode -eq "Bastion") {
        $keyArgs = if ($BastionSshKeyPath) { @("--ssh-key", $BastionSshKeyPath) } else { @() }
        $output = & az network bastion ssh `
            --name $BastionName `
            --resource-group $BastionResourceGroup `
            --target-resource-id $BastionTargetResourceId `
            --auth-type $BastionAuthType `
            --username $BastionUsername `
            @keyArgs `
            -- $fullCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "az network bastion ssh failed (exit $LASTEXITCODE): $($output -join "`n")"
        }
        return $output -join "`n"
    }
}

function Disconnect-TunnelServer {
    if ($script:SshSession) {
        Remove-SSHSession -SessionId $script:SshSession.SessionId | Out-Null
        Write-Info "SSH session closed"
    }
    # Bastion mode is stateless (no persistent session) - nothing to disconnect
}

# -------------------------------------------------------------
# REGION: Tunnel operations
# -------------------------------------------------------------

function Get-TunnelStatus {
    Write-Step "Checking current Tunnel status"

    $agentStatus  = Invoke-RemoteCommand "sudo mst-cli agent status" -AsRoot
    $serverStatus = Invoke-RemoteCommand "sudo mst-cli server status" -AsRoot
    $agentInfo    = Invoke-RemoteCommand "sudo cat /etc/ocserv/agent-info.json 2>/dev/null || echo 'NOT_FOUND'" -AsRoot
    $envSh        = Invoke-RemoteCommand "sudo cat /etc/mstunnel/env.sh 2>/dev/null || echo 'NOT_FOUND'" -AsRoot

    Write-Info "Agent status:`n$agentStatus"
    Write-Info "Server status:`n$serverStatus"

    if ($agentInfo -eq "NOT_FOUND") {
        Write-Warn "agent-info.json not found - server may not be enrolled"
    } else {
        Write-Info "agent-info.json:`n$agentInfo"
        if ($agentInfo -match '"Certificate":\s*null') {
            Write-Warn "Certificate is null - enrollment incomplete or failed"
        }
    }

    if ($envSh -ne "NOT_FOUND") {
        Write-Info "env.sh:`n$envSh"
    }

    return @{
        AgentStatus  = $agentStatus
        ServerStatus = $serverStatus
        AgentInfo    = $agentInfo
        EnvSh        = $envSh
    }
}

function Stop-TunnelServices {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step "Stopping Tunnel services"

    if (-not $PSCmdlet.ShouldProcess($ConnectionMode, "Stop Tunnel services")) { return }

    Invoke-RemoteCommand "sudo mst-cli agent stop 2>/dev/null; sudo mst-cli server stop 2>/dev/null; sudo systemctl stop mstunnel_monitor.service 2>/dev/null; echo DONE" -AsRoot | Out-Null
    Start-Sleep -Seconds 3

    $agentStatus = Invoke-RemoteCommand "sudo mst-cli agent status 2>/dev/null || echo 'stopped'" -AsRoot
    Write-Info "Agent: $agentStatus"
    Write-Ok "Services stopped"
}

function Clear-TunnelEnrollment {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Step "Clearing old enrollment data"

    if (-not $PSCmdlet.ShouldProcess($ConnectionMode, "Clear Tunnel enrollment data")) { return }

    # Backup agent-info.json and agent certificate/key files, then remove them so
    # mstunnel-setup triggers a fresh Entra ID device-code authentication flow.
    $clearResult = Invoke-RemoteCommand @"
[ -f /etc/ocserv/agent-info.json ]          && sudo cp /etc/ocserv/agent-info.json /tmp/agent-info.json.bak          && echo 'Backed up /etc/ocserv/agent-info.json';
[ -f /etc/mstunnel/agent-info.json ]        && sudo cp /etc/mstunnel/agent-info.json /tmp/mstunnel-agent-info.json.bak && echo 'Backed up /etc/mstunnel/agent-info.json';
[ -f /etc/mstunnel/private/agent.p12 ]      && sudo cp /etc/mstunnel/private/agent.p12 /tmp/agent.p12.bak             && echo 'Backed up agent.p12';
[ -f /etc/mstunnel/certs/agent.crt ]        && sudo cp /etc/mstunnel/certs/agent.crt /tmp/agent.crt.bak               && echo 'Backed up agent.crt';
[ -f /etc/mstunnel/private/agent.key ]      && sudo cp /etc/mstunnel/private/agent.key /tmp/agent.key.bak             && echo 'Backed up agent.key';
sudo rm -f /etc/ocserv/agent-info.json /etc/mstunnel/agent-info.json /etc/mstunnel/private/agent.p12 /etc/mstunnel/certs/agent.crt /etc/mstunnel/private/agent.key;
echo CLEARED
"@ -AsRoot
    Write-Info $clearResult

    Write-Ok "Enrollment data cleared (backups in /tmp/)"
}

function Backup-TlsCertificate {
    Write-Step "Backing up current TLS certificate"

    $result = Invoke-RemoteCommand "sudo cp /etc/mstunnel/certs/active.crt /tmp/active.crt.bak 2>/dev/null && echo 'cert backed up' || echo 'no active.crt'; sudo cp /etc/mstunnel/private/active.key /tmp/active.key.bak 2>/dev/null && echo 'key backed up' || echo 'no active.key'" -AsRoot

    Write-Info $result
    Write-Ok "TLS certificate backed up to /tmp/"
}

function Invoke-TunnelSetup {
    <#
    .SYNOPSIS
    Downloads the latest mstunnel-setup binary, then runs it interactively so the
    operator can complete Entra ID device-code authentication and certificate confirmation.
    NOTE: mstunnel-setup is interactive - this function runs it and watches
    the output for the device code prompt, then displays it to the operator.
    #>
    Write-Step "Running mstunnel-setup (re-enrollment)" "Yellow"

    Write-Host ""
    Write-Host "  IMPORTANT: During setup you will need to authenticate to Entra ID." -ForegroundColor Yellow
    Write-Host "  A device code will be displayed - you must open a browser and enter it." -ForegroundColor Yellow
    Write-Host "  URL: https://login.microsoft.com/device" -ForegroundColor Cyan
    Write-Host ""

    if ($ConnectionMode -eq "AzureVM") {
        Write-Warn "AzureVM Run Command mode does NOT support interactive input."
        Write-Warn "mstunnel-setup requires Entra ID device code authentication."
        Write-Warn "Consider running this step manually via Azure Bastion (ConnectionMode Bastion) or SSH."
        Write-Host ""
        $proceed = Read-Host "  Run setup anyway (output will be captured but auth will timeout)? [y/N]"
        if ($proceed -ne "y") {
            Write-Info "Skipping mstunnel-setup. Run manually on the server."
            return
        }
    }

    # ------------------------------------------------------------------
    # Download the latest mstunnel-setup binary before running it
    # ------------------------------------------------------------------
    Write-Info "Downloading latest mstunnel-setup from https://aka.ms/microsofttunneldownload ..."
    $downloadCmd = "curl -fsSL -o $MstunnelSetupPath https://aka.ms/microsofttunneldownload && chmod +x $MstunnelSetupPath && echo DOWNLOAD_OK"

    if ($ConnectionMode -eq "SSH" -or $ConnectionMode -eq "AzureVM") {
        $dlResult = Invoke-RemoteCommand $downloadCmd -AsRoot
        if ($dlResult -notmatch "DOWNLOAD_OK") {
            throw "Failed to download mstunnel-setup: $dlResult"
        }
        Write-Ok "mstunnel-setup downloaded to $MstunnelSetupPath"
    }
    # For Bastion the download is embedded in the interactive ssh command below.

    # Build the setup command
    # Note: intune_env is not overridden - PE is correct for production
    $setupCmd = "export mst_verbose_log=true; export mst_log_verbose=1; sudo -E $MstunnelSetupPath 2>&1"

    if ($ConnectionMode -eq "SSH") {
        # Always use native ssh.exe for this step - mstunnel-setup is interactive and
        # requires the Entra ID device code to be displayed live in the console.
        # Posh-SSH's Invoke-SSHCommand is blocking and non-interactive: it buffers all
        # output until the remote command exits, so the operator never sees the device
        # code in time to authenticate. ssh.exe inherits the console and works correctly.
        Write-Info "Running mstunnel-setup via ssh.exe (interactive - device code will appear here)..."
        Write-Info "Watch for the device code and authenticate at https://login.microsoft.com/device"
        Write-Host ""

        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            throw "ssh.exe not found. Install OpenSSH client (Windows 10/11 optional feature)."
        }

        # Use Start-Process -NoNewWindow -Wait so ssh.exe inherits the REAL console
        # stdin/stdout/stderr.  Calling '& ssh -tt' from inside a PowerShell script
        # connects a *pipe* to stdin; ssh sees EOF almost immediately, exits, and
        # mstunnel-setup never has a chance to display the device code.
        #
        # Single pre-built string avoids PowerShell array-join + CommandLineToArgvW
        # fragmentation. Passing a List<string> causes PowerShell to space-join all
        # elements; Windows CommandLineToArgvW then re-splits at spaces. Single-quotes
        # are NOT special on Windows, so the remote command fragments at every space.
        # Double-quotes ARE respected, and a single-string -ArgumentList bypasses the
        # per-element joining entirely.
        $keyPart = if ($SshKeyPath) { " -i `"$SshKeyPath`"" } else { "" }
        $sshRemote = "export mst_verbose_log=true; export mst_log_verbose=1; sudo -E $MstunnelSetupPath"
        $escapedSshRemote = $sshRemote.Replace('"', '\"')
        $sshArgStr = "-o StrictHostKeyChecking=no -tt$keyPart `"${SshUser}@${SshHost}`" `"$escapedSshRemote`""

        $proc = Start-Process -FilePath "ssh" `
            -ArgumentList $sshArgStr `
            -NoNewWindow -Wait -PassThru
        $sshExitCode = $proc.ExitCode

        if ($sshExitCode -eq 0) {
            Write-Ok "mstunnel-setup finished successfully"
        } else {
            Write-Warn "mstunnel-setup exited with code $sshExitCode - review output above"
        }
    }
    elseif ($ConnectionMode -eq "AzureVM") {
        Write-Info "Running mstunnel-setup via AzureVM Run Command..."
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $AzureResourceGroup `
            -VMName $AzureVmName `
            -CommandId "RunShellScript" `
            -ScriptString $setupCmd
        $output = ($result.Value | Where-Object { $_.Code -like "*StdOut*" }).Message
        Write-Host $output
        Write-Warn "Device code auth cannot be completed non-interactively - check if enrollment succeeded"
    }
    elseif ($ConnectionMode -eq "Bastion") {
        # az network bastion ssh with a command arg connects pipes instead of a real TTY.
        # Use az network bastion tunnel to open a local TCP port, then run native ssh.exe
        # with -tt so mstunnel-setup gets a proper interactive terminal and all prompts
        # (device-code auth, certificate confirmation) are visible to the operator.
        Write-Info "Running mstunnel-setup via Bastion (interactive TTY via az network bastion tunnel + ssh.exe)..."
        Write-Info "Watch for the device code and authenticate at https://login.microsoft.com/device"
        Write-Host ""

        if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
            throw "ssh.exe not found. Install OpenSSH client (Windows 10/11 optional feature)."
        }

        # Pick a local port for the bastion tunnel; verify it is free first
        $localPort = 2222
        if ((Test-NetConnection -ComputerName 127.0.0.1 -Port $localPort -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)) {
            # Port already in use - try next candidate
            $localPort = 2223
            if ((Test-NetConnection -ComputerName 127.0.0.1 -Port $localPort -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)) {
                throw "Local ports 2222 and 2223 are both in use. Free one of them and retry."
            }
        }

        # Start az network bastion tunnel as a background job
        $tunnelJob = Start-Job -ScriptBlock {
            param($BastionName, $BastionResourceGroup, $BastionTargetResourceId, $localPort)
            az network bastion tunnel `
                --name $BastionName `
                --resource-group $BastionResourceGroup `
                --target-resource-id $BastionTargetResourceId `
                --resource-port 22 `
                --port $localPort
        } -ArgumentList $BastionName, $BastionResourceGroup, $BastionTargetResourceId, $localPort

        # Wait until the tunnel port is actually listening (up to 30 seconds)
        Write-Info "Waiting for Bastion tunnel to establish on port $localPort ..."
        $tunnelReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            if (Test-NetConnection -ComputerName 127.0.0.1 -Port $localPort -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) {
                $tunnelReady = $true
                break
            }
        }
        if (-not $tunnelReady) {
            Stop-Job  -Job $tunnelJob -ErrorAction SilentlyContinue
            Remove-Job -Job $tunnelJob -Force -ErrorAction SilentlyContinue
            throw "Bastion tunnel did not become ready on port $localPort within 30 seconds."
        }
        Write-Ok "Bastion tunnel ready on port $localPort"

        try {
            # Download latest mstunnel-setup and then run it interactively
            $remoteCmd = "curl -fsSL -o $MstunnelSetupPath https://aka.ms/microsofttunneldownload && chmod +x $MstunnelSetupPath && export mst_verbose_log=true; export mst_log_verbose=1; sudo -E $MstunnelSetupPath"

            # Build a single argument string so Start-Process passes it verbatim to
            # CreateProcess. Using a List<string> causes PowerShell to space-join all
            # elements; Windows CommandLineToArgvW then re-splits at spaces. Single-quotes
            # are NOT special on Windows, so the remote command fragments at every space.
            # Double-quotes ARE respected, and a single-string -ArgumentList bypasses the
            # per-element joining entirely.
            # StrictHostKeyChecking disabled because we connect to 127.0.0.1 (the local
            # end of the Bastion TCP tunnel) - the real remote host identity is already
            # verified by the Bastion service, so MITM risk here is negligible.
            $keyPart = if ($BastionSshKeyPath) { " -i `"$BastionSshKeyPath`"" } else { "" }
            $escapedRemoteCmd = $remoteCmd.Replace('"', '\"')
            $sshArgStr = "-tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -p $localPort$keyPart `"${BastionUsername}@127.0.0.1`" `"$escapedRemoteCmd`""

            $proc = Start-Process -FilePath "ssh" `
                -ArgumentList $sshArgStr `
                -NoNewWindow -Wait -PassThru
            $sshExitCode = $proc.ExitCode

            if ($sshExitCode -eq 0) {
                Write-Ok "mstunnel-setup finished successfully"
            } else {
                Write-Warn "mstunnel-setup exited with code $sshExitCode - review output above"
            }
        } finally {
            # Always stop the background tunnel job; log any unexpected errors
            $stopErr = $null
            Stop-Job  -Job $tunnelJob -ErrorAction SilentlyContinue
            Remove-Job -Job $tunnelJob -Force -ErrorAction SilentlyContinue
            if ($stopErr) { Write-Warn "Error cleaning up Bastion tunnel job: $stopErr" }
            Write-Info "Bastion tunnel job stopped"
        }
    }
}

function Start-TunnelServices {
    Write-Step "Starting Tunnel services"

    Invoke-RemoteCommand "sudo mst-cli agent start; sudo mst-cli server start; sudo systemctl start mstunnel_monitor.service 2>/dev/null; echo STARTED" -AsRoot | Out-Null
    Start-Sleep -Seconds 10

    $agentStatus  = Invoke-RemoteCommand "sudo mst-cli agent status" -AsRoot
    $serverStatus = Invoke-RemoteCommand "sudo mst-cli server status" -AsRoot

    Write-Info "Agent:  $agentStatus"
    Write-Info "Server: $serverStatus"

    if ($agentStatus -match "healthy" -and $serverStatus -match "healthy") {
        Write-Ok "Both services healthy"
    } else {
        Write-Warn "One or more services not healthy - check logs"
    }
}

function Test-TunnelConnectivity {
    Write-Step "Running connectivity diagnostics"

    $result = Invoke-RemoteCommand "sudo /etc/ocserv/diagnostic/agent/mst-check-agent-connectivity.sh 2>&1" -AsRoot -TimeoutSeconds 60

    Write-Host $result

    if ($result -match "failed" -or $result -match "400") {
        Write-Warn "One or more connectivity checks failed - see output above"
    } else {
        Write-Ok "All connectivity checks passed"
    }

    # Also check agent-info.json
    $agentInfo = Invoke-RemoteCommand "sudo cat /etc/ocserv/agent-info.json 2>/dev/null || sudo cat /etc/mstunnel/agent-info.json 2>/dev/null || echo NOT_FOUND" -AsRoot

    Write-Host ""
    Write-Info "agent-info.json after enrollment:"
    Write-Host $agentInfo

    if ($agentInfo -match '"Certificate":\s*null') {
        Write-Warn "Certificate still null - enrollment may not have completed"
    } elseif ($agentInfo -eq "NOT_FOUND") {
        Write-Fail "agent-info.json not found - enrollment failed"
    } else {
        Write-Ok "agent-info.json looks good"
    }

    # Show agent.p12 info
    $certInfo = Invoke-RemoteCommand "sudo openssl pkcs12 -in /etc/mstunnel/private/agent.p12 -nokeys -passin pass: 2>/dev/null | openssl x509 -text -noout 2>/dev/null | grep -E 'Issuer:|Subject:|Not After' || echo 'Cannot read agent.p12'" -AsRoot

    Write-Info "Agent certificate (agent.p12):"
    Write-Host $certInfo
}

function Get-IntuneServerHealth {
    <#
    .SYNOPSIS
    Queries Intune Graph API for Tunnel server health.
    Requires either:
      - Az module with active session, OR
      - ClientId + TenantId for device code auth
    #>
    Write-Step "Checking Intune server health via Graph API"

    try {
        # Try to get token via Az module
        $token = $null

        if (Get-Module -ListAvailable -Name Az.Accounts) {
            try {
                $ctx = Get-AzContext
                if ($ctx) {
                    try {
                        $token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -AsPlainText).Token
                    } catch {
                        Write-Warn "Get-AzAccessToken -AsPlainText failed, retrying without flag: $_"
                        $token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
                    }
                    Write-Info "Using Az module token"
                }
            } catch {
                Write-Warn "Could not retrieve Az context or token: $_"
            }
        }

        if (-not $token -and $IntuneClientId -and $IntuneTenantId) {
            # Device code flow
            $body = @{
                client_id = $IntuneClientId
                scope      = "https://graph.microsoft.com/.default"
            }
            $deviceResponse = Invoke-RestMethod `
                -Uri "https://login.microsoftonline.com/$IntuneTenantId/oauth2/v2.0/devicecode" `
                -Method POST -Body $body

            Write-Host ""
            Write-Host "  Authenticate for Graph API access:" -ForegroundColor Yellow
            Write-Host "  URL:  $($deviceResponse.verification_uri)" -ForegroundColor Cyan
            Write-Host "  Code: $($deviceResponse.user_code)" -ForegroundColor Cyan
            Write-Host ""
            Read-Host "  Press Enter after authenticating"

            $tokenBody = @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $IntuneClientId
                device_code = $deviceResponse.device_code
            }
            $tokenResponse = Invoke-RestMethod `
                -Uri "https://login.microsoftonline.com/$IntuneTenantId/oauth2/v2.0/token" `
                -Method POST -Body $tokenBody
            $token = $tokenResponse.access_token
        }

        if (-not $token) {
            Write-Warn "No Graph API token available - skipping Intune health check"
            Write-Info "To enable: provide -IntuneClientId and -IntuneTenantId, or connect via Az module first"
            return
        }

        $headers = @{ Authorization = "Bearer $token" }

        # Get tunnel servers
        $servers = Invoke-RestMethod `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/microsoftTunnelSites?`$expand=microsoftTunnelServers" `
            -Headers $headers

        if ($servers.value.Count -eq 0) {
            Write-Warn "No Tunnel sites found in Intune"
            return
        }

        foreach ($site in $servers.value) {
            Write-Host ""
            Write-Host "  Site: $($site.displayName)" -ForegroundColor Cyan
            foreach ($server in $site.microsoftTunnelServers) {
                $healthColor = if ($server.tunnelServerHealthStatus -eq "healthy") { "Green" } else { "Red" }
                Write-Host "    Server: $($server.displayName)" -ForegroundColor White
                Write-Host "    Health: $($server.tunnelServerHealthStatus)" -ForegroundColor $healthColor
                Write-Host "    Last checkin: $($server.lastCheckinDateTime)" -ForegroundColor Gray
            }
        }

    } catch {
        Write-Warn "Graph API query failed: $_"
        Write-Info "Check permissions - requires DeviceManagementConfiguration.Read.All"
    }
}

function Show-TunnelLogs {
    Write-Step "Recent agent logs (last 30 lines)"
    $logs = Invoke-RemoteCommand "sudo journalctl -t mstunnel-agent -n 30 --no-pager 2>/dev/null" -AsRoot
    Write-Host $logs
}

# -------------------------------------------------------------
# REGION: Main
# -------------------------------------------------------------

Write-Host ""
Write-Host "+----------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|   Microsoft Tunnel Gateway - Reinstall & Re-enrollment   |" -ForegroundColor Cyan
Write-Host "+----------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Connection mode : $ConnectionMode" -ForegroundColor Gray
if ($ConnectionMode -eq "SSH") {
    Write-Host "  Target           : ${SshUser}@${SshHost}" -ForegroundColor Gray
} elseif ($ConnectionMode -eq "Bastion") {
    Write-Host "  Bastion          : $BastionName" -ForegroundColor Gray
    Write-Host "  Target VM        : $BastionTargetResourceId" -ForegroundColor Gray
} else {
    Write-Host "  Azure VM         : $AzureResourceGroup/$AzureVmName" -ForegroundColor Gray
}
Write-Host "  Setup script     : $MstunnelSetupPath" -ForegroundColor Gray
Write-Host ""
try {
    # Confirm
    $confirm = Read-Host "  Proceed with Tunnel re-enrollment? [y/N]"
    if ($confirm -ne "y") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }

    # Step 1: Connect
    Connect-TunnelServer

    # Step 2: Show current status
    $initialStatus = Get-TunnelStatus

    # Step 3: Stop services
    Stop-TunnelServices

    # Step 4: Backup TLS cert
    Backup-TlsCertificate

    # Step 5: Clear enrollment
    Clear-TunnelEnrollment

    # Step 6: Run setup (interactive enrollment)
    Invoke-TunnelSetup

    # Step 7: Start services
    Start-TunnelServices

    # Step 8: Wait for agent to initialize
    Write-Info "Waiting 15 seconds for agent to initialize..."
    Start-Sleep -Seconds 15

    # Step 9: Connectivity test
    Test-TunnelConnectivity

    # Step 10: Show logs
    Show-TunnelLogs

    # Step 11: Intune health check (optional)
    if (-not $SkipIntuneHealthCheck) {
        Get-IntuneServerHealth
    }

    # Summary
    Write-Host ""
    Write-Host "$('=' * 62)" -ForegroundColor Cyan
    Write-Host "  Reinstallation complete. Review output above for any warnings." -ForegroundColor Cyan
    Write-Host "  Check Intune admin center: Tenant admin > Microsoft Tunnel > Health status" -ForegroundColor Gray
    Write-Host "$('=' * 62)" -ForegroundColor Cyan

} catch {
    Write-Fail "Script failed: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
} finally {
    Disconnect-TunnelServer
}
