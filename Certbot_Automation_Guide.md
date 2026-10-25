# Automate Certbot Renewal for Microsoft Tunnel Gateway

This guide shows how to automate certificate renewal with Certbot and, after a successful renewal, automatically copy the renewed certificate into Microsoft Tunnel Gateway, import it, and restart the Tunnel service.

The target audience is administrators who manage Microsoft Intune and Azure but may not work with Linux daily.

> [!IMPORTANT]
> Test the complete workflow in a non-production environment before enabling unattended certificate deployment. Certificate issuance and Microsoft Tunnel activation are separate operations; both must succeed.

## 1. How the automation works

Certbot stores renewal configuration for certificates it manages and `certbot renew` reuses that configuration during future renewal attempts. A scheduled systemd timer or cron job can invoke the renewal command without an interactive administrator.

For Microsoft Tunnel, successful certificate renewal is only the first part of the workflow. A Certbot **deploy hook** can run after a certificate is successfully issued or renewed. This is the appropriate hook type for copying renewed files and notifying a dependent service because it runs only after successful renewal.

The resulting design is:

```text
systemd timer / scheduler
        ↓
certbot renew
        ↓
ACME validation
        ↓
Certificate renewed
        ↓
Certbot deploy hook
        ↓
Copy fullchain.pem → Microsoft Tunnel site.crt
Copy privkey.pem   → Microsoft Tunnel site.key
        ↓
mst-cli import_cert
        ↓
mst-cli server restart
```

## 2. Important consideration for standalone HTTP-01

When Certbot uses the `standalone` authenticator with HTTP-01, Certbot temporarily runs its own HTTP listener. The Certificate Authority must be able to reach the server over TCP port 80 during validation.

This means unattended renewal with HTTP-01 requires TCP/80 to be available whenever a renewal occurs.

For a production design, consider two options:

### Option A: Keep HTTP-01 available

Permit the required Internet-to-server TCP/80 path according to the organization's security policy. Certbot only needs its temporary listener during challenge validation, but the network path must be available when the scheduled renewal runs.

### Option B: Use DNS-01

Use an ACME DNS plugin/API integration so validation is performed through a DNS TXT record rather than an inbound HTTP connection. This can remove the requirement for inbound TCP/80, but requires secure management of DNS automation credentials.

The exact DNS plugin and configuration depend on the authoritative DNS provider and are intentionally outside the scope of this generic guide.

## 3. Confirm Certbot manages the certificate

List managed certificates:

```bash
sudo certbot certificates
```

Confirm the target certificate is shown and note its certificate name.

Certbot keeps renewal configuration under:

```text
/etc/letsencrypt/renewal/
```

The certificate files used after renewal are normally available under:

```text
/etc/letsencrypt/live/<TUNNEL_FQDN>/fullchain.pem
/etc/letsencrypt/live/<TUNNEL_FQDN>/privkey.pem
```

## 4. Check whether Certbot is already scheduled

Do not create a second scheduler before checking the existing installation.

For a package-based installation:

```bash
sudo systemctl status certbot.timer
```

For a snap-based installation:

```bash
sudo systemctl status snap.certbot.renew.timer
```

You can also list matching timers:

```bash
sudo systemctl list-timers --all | grep certbot
```

Different Certbot installation methods can provide different scheduler units, so use the scheduler installed with the local Certbot package rather than creating a duplicate.

## 5. Test Certbot renewal before adding Tunnel automation

Run:

```bash
sudo certbot renew --dry-run
```

The dry run exercises the renewal path against the ACME staging environment rather than replacing the production certificate.

Resolve any validation, DNS, firewall, or authentication problem before proceeding.

## 6. Create the Microsoft Tunnel deploy hook

Certbot supports executable scripts in its deploy-hook directory. Deploy hooks run after successful issuance or renewal, which prevents Tunnel from being restarted merely because a scheduled renewal check ran when no certificate needed renewal.

Create the hooks directory if necessary:

```bash
sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
```

Create the hook:

```bash
sudo nano /etc/letsencrypt/renewal-hooks/deploy/20-update-microsoft-tunnel.sh
```

Paste the following script and replace `<TUNNEL_FQDN>`:

```bash
#!/bin/sh
set -eu

DOMAIN="<TUNNEL_FQDN>"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
TUNNEL_CERT="/etc/mstunnel/certs/site.crt"
TUNNEL_KEY="/etc/mstunnel/private/site.key"

logger -t mstunnel-cert "Certbot renewed ${DOMAIN}; updating Microsoft Tunnel certificate"

# Make rollback copies of the currently configured Tunnel files.
cp -p "$TUNNEL_CERT" "${TUNNEL_CERT}.pre-renewal.bak"
cp -p "$TUNNEL_KEY" "${TUNNEL_KEY}.pre-renewal.bak"

# Install the certificate chain and matching private key produced by Certbot.
cp "$LE_DIR/fullchain.pem" "$TUNNEL_CERT"
cp "$LE_DIR/privkey.pem" "$TUNNEL_KEY"

chown root:root "$TUNNEL_CERT" "$TUNNEL_KEY"
chmod 640 "$TUNNEL_CERT"
chmod 600 "$TUNNEL_KEY"

# Validate/import the certificate into Microsoft Tunnel.
mst-cli import_cert

# Activate it.
mst-cli server restart

logger -t mstunnel-cert "Microsoft Tunnel certificate update completed for ${DOMAIN}"
```

Make the hook executable:

```bash
sudo chmod 750 /etc/letsencrypt/renewal-hooks/deploy/20-update-microsoft-tunnel.sh
```

> [!NOTE]
> The hook must be non-interactive. Scheduled certificate renewal does not have an administrator sitting at a terminal to answer prompts. Certbot deploy hooks are intended for actions such as synchronizing renewed certificate files or reloading dependent services.

## 7. Test the Tunnel hook separately

Before combining the hook with Certbot, verify the currently available certificate can be deployed:

```bash
sudo /etc/letsencrypt/renewal-hooks/deploy/20-update-microsoft-tunnel.sh
```

Then check Microsoft Tunnel:

```bash
sudo mst-cli server status
```

Inspect the active certificate:

```bash
sudo openssl x509 \
  -in /etc/ocserv/certs/active.crt \
  -noout -subject -issuer -serial -dates
```

If the manual hook fails, fix it before testing automatic renewal.

## 8. Test Certbot and the deployment workflow

First run the ordinary renewal dry run:

```bash
sudo certbot renew --dry-run
```

Then review the Certbot documentation/version installed on the server to determine how that version executes deploy hooks during dry-run testing. Do not assume a successful ACME dry run proves the production deploy hook executed. The Certbot hook model distinguishes the ACME renewal test from execution of post-renewal deployment actions.

Verify the active Tunnel certificate separately after any end-to-end test.

## 9. Verify the scheduler

For an apt/package installation:

```bash
sudo systemctl status certbot.timer
```

For a snap installation:

```bash
sudo systemctl status snap.certbot.renew.timer
```

The timer should be enabled/active according to the installation method. Modern Certbot installations commonly provide a systemd renewal timer, but the exact unit depends on how Certbot was installed.

## 10. Verify logging

Certbot maintains its own log under:

```text
/var/log/letsencrypt/letsencrypt.log
```

Review recent entries with:

```bash
sudo tail -n 100 /var/log/letsencrypt/letsencrypt.log
```

The example hook also writes messages to the system journal using the tag `mstunnel-cert`:

```bash
sudo journalctl -t mstunnel-cert
```

Review the Certbot service journal where systemd is used:

```bash
sudo journalctl -u certbot.service
```

For snap installations, use the relevant snap Certbot service/timer unit present on the server.

## 11. Validate the resulting certificate

After a real renewal, examine the Certbot certificate:

```bash
sudo openssl x509 \
  -in /etc/letsencrypt/live/<TUNNEL_FQDN>/fullchain.pem \
  -noout -subject -issuer -serial -dates
```

Then compare it with Tunnel's active certificate:

```bash
sudo openssl x509 \
  -in /etc/ocserv/certs/active.crt \
  -noout -subject -issuer -serial -dates
```

The active Microsoft Tunnel certificate should correspond to the newly issued certificate.

## 12. Failure behavior

The script uses:

```bash
set -eu
```

so a command error stops subsequent script execution. In particular, if `mst-cli import_cert` returns an error, the restart command that follows it is not executed.

This is intentional: an invalid certificate should not deliberately trigger service activation as though deployment succeeded.

However, copying the new files occurs before `mst-cli import_cert`, so a failed import still requires administrator investigation. The `.pre-renewal.bak` files provide copies of the previously configured inputs for rollback.

### Manual rollback

Restore the previous files:

```bash
sudo cp /etc/mstunnel/certs/site.crt.pre-renewal.bak /etc/mstunnel/certs/site.crt
```

```bash
sudo cp /etc/mstunnel/private/site.key.pre-renewal.bak /etc/mstunnel/private/site.key
```

Re-import and restart:

```bash
sudo mst-cli import_cert
```

```bash
sudo mst-cli server restart
```

Then verify the active certificate and client connectivity.

## 13. Monitoring recommendations

Unattended renewal should be treated as an operational process, not as a configuration that can be forgotten.

At minimum, monitor:

- Certbot renewal failures.
- Certificate expiration date.
- Microsoft Tunnel service health after certificate deployment.
- The serial number/expiry of the externally presented TLS certificate.
- ACME challenge network/DNS dependencies.

A scheduled renewal process can fail because its validation path or dependent service changes even though the scheduler itself remains active. Certbot logs and dry-run testing are therefore useful operational checks.

## 14. Recommended production refinement: DNS-01

For Internet-facing infrastructure where permanently allowing TCP/80 is undesirable, evaluate an automated DNS-01 ACME challenge.

A DNS-01 design typically changes this part of the flow:

```text
HTTP-01
ACME CA → TCP/80 → Tunnel VM
```

to:

```text
DNS-01
Certbot/ACME client → DNS API → temporary TXT record
ACME CA → public DNS lookup → validation
```

The DNS credentials must be treated as secrets and granted the minimum permissions supported by the DNS platform. Follow the security guidance for the selected Certbot DNS plugin and DNS provider.

## 15. Quick checklist

- [ ] `sudo certbot certificates` shows the target certificate.
- [ ] Identify the existing Certbot systemd timer or other scheduler.
- [ ] `sudo certbot renew --dry-run` succeeds.
- [ ] HTTP-01 TCP/80 or DNS-01 validation can run unattended.
- [ ] Create `/etc/letsencrypt/renewal-hooks/deploy/20-update-microsoft-tunnel.sh`.
- [ ] Replace `<TUNNEL_FQDN>` in the hook.
- [ ] Make the hook executable.
- [ ] Run the hook manually and verify Microsoft Tunnel remains healthy.
- [ ] Verify `mst-cli import_cert` and `mst-cli server restart` work non-interactively.
- [ ] Verify the Certbot scheduler is active.
- [ ] Monitor Certbot and Tunnel certificate-deployment logs.
- [ ] After renewal, compare the Certbot and active Tunnel certificate serial/expiry values.
- [ ] Maintain a tested rollback path.

## References

- [Certbot User Guide](https://eff-certbot.readthedocs.io/en/stable/using.html)
- [Certbot command-line reference](https://eff-certbot.readthedocs.io/en/stable/man/certbot.html)
- [Microsoft Tunnel file and command reference](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/ref-file-commands)
- [Let’s Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/)

## Disclaimer

This document is an implementation template. Validate the automation against the current Certbot and Microsoft Tunnel versions, the selected ACME CA, the organization’s DNS/firewall architecture, and change-management requirements before production deployment.
