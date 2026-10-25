# Deploy and Renew a Microsoft Tunnel TLS Certificate Issued by a Private CA

This customer-ready guide describes how to use an organization-owned private certification authority (CA) for the TLS certificate presented by Microsoft Tunnel Gateway. It also covers certificate trust, Certificate Revocation List (CRL) design, deployment, renewal, validation, and rollback.

> [!IMPORTANT]
> Validate this procedure in a non-production environment first. Adapt certificate templates, approval workflows, file-transfer methods, maintenance windows, and key-protection controls to your organization’s PKI and security standards.

## 1. Purpose and scope

Microsoft Tunnel Gateway uses a TLS certificate to identify the Tunnel service to connecting devices and protect the client-to-gateway TLS session.

A private CA can issue this certificate. Unlike a certificate from a publicly trusted CA, a private-CA certificate requires the organization to establish trust on every client platform that connects to Microsoft Tunnel.

This guide covers the **Microsoft Tunnel server TLS certificate**. It does not describe user/device authentication certificates used by applications, SCEP, PKCS, Wi-Fi, or VPN authentication.

## 2. Solution overview

The certificate flow is:

```text
Organization Root CA
        ↓ signs
Organization Issuing CA
        ↓ issues
Microsoft Tunnel TLS certificate
        ↓ installed on
Microsoft Tunnel Gateway
```

Client trust is established separately:

```text
Intune trusted certificate profiles
        ↓ deploy
Root CA and required intermediate CA certificates
        ↓ trusted by
Managed iOS/iPadOS and Android devices
```

The operational lifecycle is:

```text
Generate private key and CSR
        ↓
Private CA signs CSR
        ↓
Build complete certificate chain
        ↓
Copy certificate and private key to Microsoft Tunnel
        ↓
Import, restart, and validate
        ↓
Monitor expiry and CRL availability
        ↓
Renew before expiration
```

## 3. Design decisions

Before requesting the certificate, agree on the following items with the PKI, network, security, and endpoint-management teams.

### 3.1 Tunnel DNS name

Define the public Fully Qualified Domain Name (FQDN) used by clients, for example:

```text
tunnel.contoso.com
```

Use this value throughout this document as:

```text
<TUNNEL_FQDN>
```

The certificate Subject Alternative Name (SAN) must contain the DNS name clients use to reach Microsoft Tunnel.

### 3.2 Certificate hierarchy

Identify:

- Root CA
- Issuing/intermediate CA
- Certificate template or issuance policy
- Certificate validity period
- Renewal lead time
- Certificate owner
- Approval and revocation process

Avoid issuing service certificates directly from an offline root CA unless the organization’s PKI design explicitly requires it.

### 3.3 Certificate properties

The issued certificate should meet the organization’s TLS policy and include:

- SAN: `DNS:<TUNNEL_FQDN>`
- A private key matching the certificate
- Server Authentication Extended Key Usage (EKU), OID `1.3.6.1.5.5.7.3.1`
- A supported key algorithm and size defined by organizational policy
- A complete and valid chain to the organization’s trusted root CA
- CRL Distribution Point (CDP) information, and Authority Information Access (AIA) information if required by the PKI design

> [!NOTE]
> The Common Name can also contain the Tunnel FQDN, but modern TLS validation is based on the SAN. Do not rely on the Common Name alone.

## 4. CRL and revocation planning

### 4.1 What a CRL does

A CA can revoke a certificate before its normal expiration, for example after a private-key compromise. The CA publishes revoked certificate serial numbers in a Certificate Revocation List (CRL). A relying party retrieves the CRL from a CRL Distribution Point (CDP) identified in the certificate.

Revocation is not instantaneous on all devices. Validation depends on publication, network reachability, refresh intervals, and local caching.

### 4.2 CRL availability requirement

For a private-CA Tunnel certificate, design the CRL location so that relevant clients can retrieve revocation information when validating the Tunnel server certificate.

**Customer design recommendation:** publish the CRL through a highly available HTTP endpoint that is reachable from the client networks on which Tunnel connections are initiated. Do not make the only CRL endpoint dependent on an already-established Tunnel connection, because certificate validation occurs while the client is establishing trust in the Tunnel endpoint.

Example CDP:

```text
http://pki.contoso.com/crl/Contoso-Issuing-CA.crl
```

Do not use a server name or LDAP-only location that Internet-based mobile devices cannot resolve or reach unless the target platforms and PKI design are explicitly validated for that dependency.

### 4.3 CRL publication checklist

Confirm with the PKI team that:

- The current base CRL is published before the Tunnel certificate is issued.
- The certificate contains the intended CDP URL.
- The CDP is reachable from representative corporate, home, and mobile networks.
- The web server returns the CRL without interactive authentication.
- CRL publication is automated and monitored.
- The next-update value leaves sufficient time to recover from a publication failure.
- Old CDP locations remain available for certificates already issued with those locations.
- If delta CRLs are used, both base and delta CRLs are published and tested.
- Firewall, proxy, DNS, and content-filtering rules permit the required access.

### 4.4 Inspect the CDP in the issued certificate

After receiving the certificate, inspect its CRL Distribution Points:

```bash
openssl x509 \
  -in tunnel-server.crt \
  -noout -text | grep -A 6 "CRL Distribution Points"
```

Review the complete output when necessary:

```bash
openssl x509 -in tunnel-server.crt -noout -text
```

### 4.5 Test CRL retrieval

If the certificate contains an HTTP CDP, test it from representative networks using the exact URL embedded in the certificate.

Example from Linux:

```bash
curl -I http://pki.contoso.com/crl/Contoso-Issuing-CA.crl
```

A successful HTTP response confirms retrieval, but not the validity or freshness of the CRL. Download and inspect the CRL when performing PKI validation:

```bash
curl -o issuing-ca.crl http://pki.contoso.com/crl/Contoso-Issuing-CA.crl
```

For a DER-encoded CRL:

```bash
openssl crl -inform DER -in issuing-ca.crl -noout -issuer -lastupdate -nextupdate
```

For a PEM-encoded CRL:

```bash
openssl crl -inform PEM -in issuing-ca.crl -noout -issuer -lastupdate -nextupdate
```

Use the encoding produced by the organization’s CA.

## 5. Deploy CA trust to managed devices

A certificate issued by a private CA is not automatically trusted by mobile devices. Deploy the required CA certificates through Intune before switching Microsoft Tunnel to the private-CA certificate.

Create Intune **Trusted certificate** profiles for the supported platforms and deploy:

1. The root CA certificate.
2. Each intermediate/issuing CA certificate required to build the chain.

Assign the profiles to the same device/user population that receives the Microsoft Tunnel application and VPN profile.

Recommended rollout sequence:

1. Deploy the root and intermediate CA trust profiles.
2. Confirm successful installation on pilot devices.
3. Test certificate-chain construction on each supported platform.
4. Install the private-CA certificate on a pilot Tunnel gateway or during an approved maintenance window.
5. Validate Tunnel connectivity before broad deployment.

> [!CAUTION]
> Changing the Tunnel TLS certificate before clients trust the private CA can make the service appear untrusted and prevent connections.

## 6. Create the private key and CSR

The following OpenSSL example generates the private key on the Tunnel server so the private key does not need to be transported from another system.

Create a restricted working directory:

```bash
sudo install -d -m 700 /root/mstunnel-cert
```

Create an OpenSSL request configuration:

```bash
sudo tee /root/mstunnel-cert/tunnel-request.cnf > /dev/null <<'EOF'
[ req ]
default_bits = 3072
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = <TUNNEL_FQDN>
O = <ORGANIZATION_NAME>
C = <COUNTRY_CODE>

[ req_ext ]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = <TUNNEL_FQDN>
EOF
```

Replace all placeholders before continuing.

Generate the private key and certificate signing request (CSR):

```bash
sudo openssl req \
  -new \
  -newkey rsa:3072 \
  -nodes \
  -keyout /root/mstunnel-cert/site.key \
  -out /root/mstunnel-cert/tunnel-server.csr \
  -config /root/mstunnel-cert/tunnel-request.cnf
```

Restrict private-key permissions:

```bash
sudo chmod 600 /root/mstunnel-cert/site.key
```

Inspect the CSR:

```bash
sudo openssl req \
  -in /root/mstunnel-cert/tunnel-server.csr \
  -noout -text -verify
```

Confirm that the SAN contains `<TUNNEL_FQDN>` and the requested EKU is appropriate.

> [!IMPORTANT]
> The CA controls the final certificate. Some enterprise CAs ignore requested CSR extensions and apply settings from a certificate template. Always inspect the issued certificate rather than assuming the CSR settings were retained.

## 7. Submit the CSR to the organization’s CA

Transfer only this file to the PKI team or enrollment system:

```text
/root/mstunnel-cert/tunnel-server.csr
```

Do not transfer or disclose:

```text
/root/mstunnel-cert/site.key
```

Request the resulting certificate and CA chain in PEM/Base64 format where possible:

- Issued Tunnel server certificate
- Issuing/intermediate CA certificate(s)
- Root CA certificate, for chain validation and client trust deployment

The exact enrollment workflow depends on the customer’s CA, such as Active Directory Certificate Services (AD CS), a hardware security module-backed PKI, or another enterprise CA platform.

## 8. Validate the issued certificate

Save the files with clear names, for example:

```text
tunnel-server.crt
issuing-ca.crt
root-ca.crt
```

Inspect the server certificate:

```bash
openssl x509 \
  -in tunnel-server.crt \
  -noout -subject -issuer -serial -dates -ext subjectAltName -ext extendedKeyUsage
```

Confirm:

- The certificate is within its validity period.
- The SAN contains `<TUNNEL_FQDN>`.
- The EKU includes Server Authentication.
- The issuer is the expected issuing CA.
- The CDP points to the approved CRL location.

Verify that the certificate matches the generated private key:

```bash
openssl x509 -in tunnel-server.crt -pubkey -noout | openssl sha256
```

```bash
sudo openssl pkey -in /root/mstunnel-cert/site.key -pubout | openssl sha256
```

The two SHA-256 values must match.

Verify the chain:

```bash
cat issuing-ca.crt root-ca.crt > ca-chain.crt
```

```bash
openssl verify -CAfile ca-chain.crt tunnel-server.crt
```

Expected result:

```text
tunnel-server.crt: OK
```

## 9. Build the Microsoft Tunnel certificate chain

Create `site.crt` with the certificates in this order:

1. Tunnel server certificate
2. Issuing/intermediate CA certificate(s), beginning with the CA that issued the server certificate
3. Root CA certificate, if required by the customer’s validated chain-delivery design

Example:

```bash
cat tunnel-server.crt issuing-ca.crt root-ca.crt > site.crt
```

Confirm that the file contains multiple certificates:

```bash
grep -c -e "-----BEGIN CERTIFICATE-----" site.crt
```

The result should represent the complete chain included in the file.

## 10. Back up the current Microsoft Tunnel certificate

Before replacing the certificate, create timestamped backups:

```bash
sudo cp /etc/mstunnel/certs/site.crt \
  /etc/mstunnel/certs/site.crt.$(date +%Y%m%d-%H%M%S).bak
```

```bash
sudo cp /etc/mstunnel/private/site.key \
  /etc/mstunnel/private/site.key.$(date +%Y%m%d-%H%M%S).bak
```

Keep private-key backups protected and retain them only for the period required by the approved rollback and key-management process.

## 11. Install the private-CA certificate on Microsoft Tunnel

Copy the complete chain:

```bash
sudo cp site.crt /etc/mstunnel/certs/site.crt
```

Copy the matching unencrypted private key:

```bash
sudo cp /root/mstunnel-cert/site.key /etc/mstunnel/private/site.key
```

Apply restrictive permissions:

```bash
sudo chown root:root /etc/mstunnel/certs/site.crt /etc/mstunnel/private/site.key
```

```bash
sudo chmod 640 /etc/mstunnel/certs/site.crt
```

```bash
sudo chmod 600 /etc/mstunnel/private/site.key
```

## 12. Import and activate the certificate

Import the certificate:

```bash
sudo mst-cli import_cert
```

A successful validation should include:

```text
/etc/ocserv/certs/site.crt: OK
```

Restart the Tunnel server:

```bash
sudo mst-cli server restart
```

Check service health:

```bash
sudo mst-cli server status
```

```bash
sudo mst-cli agent status
```

## 13. Validate the active certificate

Inspect the certificate activated by Tunnel:

```bash
sudo openssl x509 \
  -in /etc/ocserv/certs/active.crt \
  -noout -subject -issuer -serial -dates -ext subjectAltName
```

From an external Windows system, confirm that the configured Tunnel TLS port is reachable:

```powershell
Test-NetConnection <TUNNEL_FQDN> -Port <TUNNEL_PORT>
```

Then test a real connection from each supported client platform and network type.

Validation should cover:

- DNS resolution
- TCP reachability
- TLS trust and hostname validation
- Root/intermediate certificate deployment
- CRL retrieval
- Intune Tunnel application and profile assignment
- Connection establishment
- Access to intended internal resources

## 14. Renewal procedure

Begin renewal early enough to complete PKI approval, pilot validation, deployment, and rollback before the existing certificate expires.

1. Generate a new private key and CSR, or follow the organization’s approved key-reuse policy.
2. Request a new server certificate with the same required SAN and EKU.
3. Validate the new certificate, chain, CDP, and CRL reachability.
4. Confirm that clients still trust the CA hierarchy.
5. Back up the current Tunnel certificate and key.
6. Replace `/etc/mstunnel/certs/site.crt` and `/etc/mstunnel/private/site.key`.
7. Run:

```bash
sudo mst-cli import_cert
```

8. Restart and validate:

```bash
sudo mst-cli server restart
```

9. Confirm the new active certificate:

```bash
sudo openssl x509 \
  -in /etc/ocserv/certs/active.crt \
  -noout -subject -issuer -serial -dates
```

10. Complete client testing and document the new serial number and expiration date.

## 15. Revocation procedure

If the Tunnel certificate’s private key is compromised or the certificate must no longer be trusted:

1. Issue and install a replacement certificate and private key.
2. Validate the replacement on Microsoft Tunnel and representative clients.
3. Ask the PKI team to revoke the superseded certificate using the approved reason code.
4. Publish an updated CRL.
5. Verify that the current CRL is available at every CDP included in the revoked certificate.
6. Validate revocation behavior from representative client networks, accounting for platform caching and CRL refresh behavior.
7. Securely remove compromised private-key material and unnecessary backups according to the incident-response and key-destruction process.

> [!IMPORTANT]
> Revoking the old certificate before a replacement is active can cause an outage. During a confirmed key compromise, the security incident-response owner must balance service continuity against the risk of continued trust in the compromised key.

## 16. Rollback

If the replacement certificate causes connectivity failures:

1. Restore the previous `site.crt` and `site.key` backup files.
2. Run:

```bash
sudo mst-cli import_cert
```

3. Restart Microsoft Tunnel:

```bash
sudo mst-cli server restart
```

4. Confirm the active certificate and client connectivity.
5. Investigate CA trust deployment, chain order, SAN, EKU, certificate/key matching, CRL availability, and network reachability before retrying.

Rollback is possible only while the old certificate remains valid and trusted.

## 17. Troubleshooting

### `mst-cli import_cert` reports verification failure

Check the certificate dates:

```bash
openssl x509 -in /etc/mstunnel/certs/site.crt -noout -dates
```

Check the SAN and EKU:

```bash
openssl x509 \
  -in /etc/mstunnel/certs/site.crt \
  -noout -ext subjectAltName -ext extendedKeyUsage
```

Check how many certificates are in the chain file:

```bash
grep -c -e "-----BEGIN CERTIFICATE-----" /etc/mstunnel/certs/site.crt
```

Verify the certificate and private key match by comparing their public-key hashes.

### Clients report an untrusted certificate

Confirm that:

- Intune Trusted certificate profiles installed the correct root and intermediate CA certificates.
- Profiles are assigned to the affected users/devices.
- The server sends the required intermediate chain.
- The client connects using a DNS name present in the SAN.
- Device date and time are correct.

### Clients fail when CRL cannot be reached

Confirm the exact CDP URL in the issued certificate, then test DNS, HTTP reachability, CRL freshness, and proxy/firewall behavior from the affected network.

Do not solve the problem by disabling revocation checking without explicit PKI and security approval. Restore reliable CRL publication and retrieval instead.

## 18. Operational checklist

### Before deployment

- [ ] Tunnel FQDN and port approved
- [ ] Certificate SAN and Server Authentication EKU confirmed
- [ ] CA hierarchy documented
- [ ] Root and intermediate certificates exported
- [ ] CRL/CDP design approved
- [ ] CRL reachable from representative client networks
- [ ] Intune Trusted certificate profiles deployed
- [ ] Pilot devices confirm CA trust
- [ ] Maintenance and rollback plans approved

### During deployment

- [ ] CSR and private key created securely
- [ ] Issued certificate inspected
- [ ] Certificate/private-key match verified
- [ ] Full chain assembled in `site.crt`
- [ ] Existing Tunnel certificate and key backed up
- [ ] New files copied with restricted permissions
- [ ] `mst-cli import_cert` returns `site.crt: OK`
- [ ] Tunnel server restarted

### After deployment

- [ ] Active certificate subject, serial, and expiration verified
- [ ] Server and agent status healthy
- [ ] External TLS reachability tested
- [ ] iOS/iPadOS pilot connection tested, where applicable
- [ ] Android pilot connection tested, where applicable
- [ ] CRL retrieval tested from representative networks
- [ ] Monitoring and renewal owner documented
- [ ] Certificate inventory updated

## 19. References

- [Install Microsoft Tunnel Gateway and update its TLS certificate](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/install)
- [Microsoft Tunnel file and command reference](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/ref-file-commands)
- [Microsoft Intune Cloud PKI deployment models and trust-chain planning](https://learn.microsoft.com/en-us/intune/cloud-pki/deployment-models)
- [Bring your own certificate authority with Microsoft Cloud PKI](https://learn.microsoft.com/en-us/intune/cloud-pki/configure-byoca)
- [Revoke certificates and publish CRLs in Active Directory Certificate Services](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/operate-certificate-revocation-crl-cdp)

## Disclaimer

This document is a deployment template and not a replacement for the customer’s PKI policy, security architecture, or change-management process. Certificate behavior can vary by operating system, client application, CA configuration, revocation configuration, and Microsoft Tunnel version. Validate the final design and procedure in the target environment.
