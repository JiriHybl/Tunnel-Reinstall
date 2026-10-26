# Configure Microsoft Defender on Android as the Microsoft Tunnel Client

This customer-ready guide explains how to deploy Microsoft Defender for Endpoint on Android Enterprise devices and configure it as the client application for Microsoft Tunnel. It includes the required Intune objects, recommended values, where each value comes from, example configurations, assignment guidance, and validation steps.

> [!IMPORTANT]
> This guide covers **enrolled Android Enterprise devices using Microsoft Tunnel through Mobile Device Management (MDM)**. Microsoft Tunnel for Mobile Application Management (MAM) on unenrolled devices uses a different configuration model.

## 1. Architecture and terminology

On Android Enterprise, **Microsoft Defender is the Microsoft Tunnel client application**. Microsoft Intune deploys:

1. The Microsoft Defender app.
2. A Microsoft Tunnel VPN profile that identifies the Tunnel site and connection behavior.
3. Optionally, an Android Enterprise device restrictions profile for always-on VPN and lockdown behavior.
4. Optionally, Defender app configuration and permission policies for Defender security features and a lower-touch onboarding experience.

The high-level flow is:

```text
Android Enterprise device
        ↓
Microsoft Defender app
        ↓
Intune Microsoft Tunnel VPN profile
        ↓
Selected Microsoft Tunnel Site
        ↓
Tunnel Gateway public FQDN/IP and port
        ↓
Internal corporate resources
```

Microsoft Tunnel uses Microsoft Entra ID authentication and can be integrated with Conditional Access. Microsoft Tunnel supports per-app and device-wide connections, always-on VPN, split tunneling, and Strict Tunnel Mode on supported Android enrollment types.

## 2. Supported Android Enterprise scenarios

Use this guide for:

- Personally owned devices with a work profile (BYOD)
- Corporate-owned devices with a work profile (COPE)
- Corporate-owned, fully managed user devices (COBO)

Microsoft Tunnel is not supported on Android Enterprise dedicated devices for the Microsoft Tunnel connection type.

## 3. Information to collect before configuration

Collect the following information before creating policies.

| Required value | Example | Where to find or define it |
|---|---|---|
| Target Android enrollment type | Corporate-owned, fully managed | Intune admin center > Devices > Android > Android enrollment; confirm the enrollment profile used by the target devices. |
| Microsoft Tunnel Site | `Prague-Tunnel-Site` | Intune admin center > Tenant administration > Microsoft Tunnel Gateway > Sites. Select the site that contains the Tunnel server intended for these users. |
| Tunnel public FQDN or IP | `tunnel.contoso.com` | Open the selected Tunnel Site. The Site contains the public IP address or FQDN used as the client connection point. The VPN profile normally obtains this through the selected Site. |
| Tunnel server port | `443` | Intune admin center > Tenant administration > Microsoft Tunnel Gateway > Server configurations. Open the Server configuration assigned to the selected Site and review **Server port**. |
| Internal DNS servers | `10.20.0.10`, `10.20.0.11` | The Server configuration assigned to the Tunnel Site. These values should be supplied by the customer's network/DNS team. |
| Tunnel routes | Example include route `10.20.0.0/16` | The Server configuration assigned to the Site. Routes must be designed with the network team and must not conflict with the Tunnel client IP range. |
| Apps requiring Tunnel | Managed Edge, line-of-business apps | Confirm with application owners. Locate each app under Intune admin center > Apps > All apps. The app must be managed by Intune to be selected in the per-app VPN list. |
| Target assignment group | `GRP-Android-Tunnel-Pilot` | Microsoft Entra admin center or Intune group picker. Create a dedicated pilot group before broad deployment. |
| Defender Android package ID | `com.microsoft.scmx` | The Managed Google Play listing for Microsoft Defender. This value is relevant when a device restrictions profile asks for a custom VPN client package ID. |
| Private CA trust chain, if used | Root and issuing CA certificates | Obtain from the PKI team. Deploy with Intune Trusted certificate profiles before using a privately issued Tunnel TLS certificate. |

## 4. Recommended policy design

Use separate policies so each layer has a clear purpose:

| Policy/object | Purpose | Recommended assignment |
|---|---|---|
| Microsoft Defender Managed Google Play app | Installs the Tunnel client | Required to the Tunnel pilot/production user group |
| Defender app configuration policy | Configures permissions and Defender onboarding/security behavior | Same user group as the Defender app, after validating the selected options |
| Microsoft Tunnel VPN profile | Selects the Tunnel Site and defines per-app/device-wide behavior | Same pilot/production group |
| Device restrictions profile | Configures Android always-on VPN and optional lockdown behavior when required for the enrollment type/design | Same devices/users as the VPN profile, with only one always-on VPN client per device |
| Trusted certificate profiles | Establishes trust for a private-CA Tunnel TLS certificate | Same population as the Tunnel VPN profile; deploy before switching the server certificate |
| Compliance and Conditional Access policies | Control access based on device state and risk | Design separately and pilot carefully |

> [!IMPORTANT]
> Only one VPN client can be configured as always-on on an Android device. Check for existing Defender Web Protection, third-party VPN, or other always-on VPN policies before assignment.

## 5. Add Microsoft Defender from Managed Google Play

In the Microsoft Intune admin center:

1. Go to **Apps > All apps > Add**.
2. Select **Managed Google Play app**.
3. Search for **Microsoft Defender**.
4. Select the Microsoft Defender app.
5. Approve/select the app and synchronize Managed Google Play.
6. Return to **Apps > All apps** and confirm Microsoft Defender is listed.
7. Open the app > **Properties > Assignments**.
8. Assign the app as **Required** to the pilot group.

### Recommended application values

| Setting | Recommended value | Explanation |
|---|---|---|
| App | Microsoft Defender | Microsoft Defender is the Android client for Microsoft Tunnel. |
| Installation intent | Required | Ensures that the VPN client is installed before the VPN profile is expected to work. |
| Assignment scope | Dedicated pilot user group first | Reduces risk and makes troubleshooting easier. Expand only after validation. |
| Managed Google Play updates | Allow automatic updates | Keeps the supported Defender client current through Managed Google Play. |

## 6. Create the Microsoft Tunnel VPN profile

In the Intune admin center:

1. Go to **Devices > Configuration > Create > New policy**.
2. Platform: **Android Enterprise**.
3. Select the profile type that matches the enrollment model:
   - **Fully Managed, Dedicated, and Corporate-Owned Work Profile**, or
   - **Personally-Owned Work Profile**.
4. Select the **VPN** template/settings experience.
5. Create the policy using the values below.

### Core VPN settings

| Intune setting | Recommended value | Example | Where the value comes from / implementation note |
|---|---|---|---|
| Profile name | Descriptive and environment-specific | `Android - Microsoft Tunnel - Per App - Production` | Defined by the Intune administrator. Include platform, technology, scope, and environment. |
| Connection type | **Microsoft Tunnel** | Microsoft Tunnel | Select directly in the VPN profile. This causes Intune to expose the Microsoft Tunnel-specific Site selection. |
| Connection name | Friendly user-facing name | `Contoso Secure Access` | Defined by the customer. Users can see this name in Android VPN/Defender connection information. Avoid internal project codes. |
| VPN server address/FQDN | Use the public Tunnel FQDN if the template requests it | `tunnel.contoso.com` | Obtain from **Tenant administration > Microsoft Tunnel Gateway > Sites > selected Site**. The value must match the Tunnel TLS certificate SAN. In a Microsoft Tunnel profile, the selected Site directs clients to the Site public IP/FQDN. |
| Microsoft Tunnel Site | Select the production or pilot Site | `Prague-Tunnel-Site` | Select an existing Site from the Intune picker. Find Sites under **Tenant administration > Microsoft Tunnel Gateway > Sites**. Do not type an arbitrary site name. |
| Authentication method | Use the Microsoft Tunnel/Entra flow exposed by the profile | Microsoft Entra authentication | Microsoft Tunnel clients authenticate through Microsoft Entra ID and are evaluated against applicable Conditional Access. Do not add a separate client certificate unless the selected profile explicitly requires one for another purpose. |
| Proxy | Not configured unless explicitly required | Not configured | Configure only if the application/network architecture requires a proxy. For Android, proxy support depends on Android version and profile settings. Validate before production use. |

## 7. Choose per-app or device-wide Tunnel

This is the most important client design choice.

### Recommended default: per-app VPN

Use per-app VPN when only selected business applications require access to internal resources.

| Setting | Recommended value | Example | Where to find the value |
|---|---|---|---|
| Per-app VPN | Enabled by adding managed apps | Microsoft Edge plus a line-of-business app | In the VPN profile, select **Add** under per-app VPN and choose apps from the Intune managed-app list. |
| Apps that use Tunnel | Only applications that require private access | Edge, SAP client, internal field app | Confirm with application owners. The apps must exist in **Apps > All apps** before they can be selected. |
| Public Microsoft 365 apps | Exclude unless they require specific internal destinations | Outlook bypasses Tunnel | Keep Internet/SaaS traffic direct where possible. This avoids unnecessary latency and aligns with split-tunnel design. |

When an app in the per-app list starts, its traffic is associated with the VPN connection. Microsoft Tunnel VPN profiles support selecting managed apps for this purpose.

### Device-wide VPN

Use device-wide Tunnel only when the approved requirement is to route all device traffic through Tunnel.

| Setting | Recommended value | Explanation |
|---|---|---|
| Per-app application list | Empty | For an always-on Tunnel profile, no defined apps results in Tunnel access for all device network traffic. |
| Split-tunnel server routes | Explicitly designed and tested | The Tunnel Server configuration determines which destinations are included/excluded. Device-wide client association does not remove the need for correct server-side routing. |
| Microsoft 365/SaaS bypass | Recommended where architecture permits | Prevents unnecessary backhaul of Internet SaaS traffic. |

> [!CAUTION]
> Device-wide VPN has a larger traffic and outage impact. Test DNS, Microsoft 365 connectivity, captive portals, Android OS services, application updates, and performance before broad rollout.

## 8. Always-on VPN and Strict Tunnel Mode

Always-on and Strict Tunnel Mode are related but not identical:

- **Always-on VPN** continuously tries to connect/reconnect the VPN.
- **Strict Tunnel Mode** blocks network traffic when the Tunnel connection drops, preventing traffic from bypassing Tunnel.

### Recommended values

| Setting | Recommended baseline | When to use another value | Where configured |
|---|---|---|---|
| Always-on VPN | **Enabled** for corporate-managed Tunnel deployments after pilot testing | Leave not configured for early manual-connect troubleshooting or when another VPN must own Android always-on | VPN profile and, where required by the Android enrollment configuration, an Android Enterprise device restrictions > Connectivity profile. Assign both required profiles. |
| Always-on VPN client | Microsoft Tunnel / Microsoft Defender | Never configure two always-on VPN clients on the same device | The Microsoft Tunnel VPN profile identifies Microsoft Tunnel. If a custom package is requested in a device-restrictions workflow, Defender package ID is `com.microsoft.scmx`. |
| Strict Tunnel Mode / Lockdown | **Disabled or Not configured during pilot**, then enable only for an explicit fail-closed requirement | Enable for high-security use cases where loss of all network access during Tunnel failure is acceptable | In the supported Android Microsoft Tunnel/always-on configuration. Validate exact UI wording for the selected Android Enterprise profile type. |
| User disconnect | Prevented by always-on behavior where enforced | Permit manual connect/disconnect for troubleshooting or optional-access scenarios | Result of the always-on policy; the Defender Tunnel status toggle becomes unavailable when the organization requires an always-on connection. |

> [!WARNING]
> Strict Tunnel Mode can block all Internet access if the Tunnel connection fails. Do not enable it broadly until DNS, routes, server capacity, certificate trust, Conditional Access, captive portal behavior, and recovery procedures have been tested.

## 9. Defender app configuration and permissions

The Tunnel VPN profile is the object that directs Defender to the Tunnel Site. A separate Defender app configuration policy is used for Defender security/onboarding behavior.

Create it under:

**Apps > App configuration policies > Add > Managed devices**

Select:

- Platform: **Android Enterprise**
- Profile type: match the target enrollment model
- Target app: **Microsoft Defender** / **Microsoft Defender: Antivirus** as shown in the tenant

### Recommended Defender values

| Setting | Recommended value | Explanation / where to find it |
|---|---|---|
| Target application | Microsoft Defender | Select from the managed application picker after the Managed Google Play sync. |
| Location access (fine) | Auto grant where supported and required | Available under app permissions in the Defender managed-device app configuration policy. Microsoft documents it for Defender onboarding/features such as Network Protection. Validate privacy requirements. |
| Notification permission (`POST_NOTIFICATIONS`) | Auto grant where supported | Lets Defender present security and connection-related notifications. Android/enrollment support for auto-grant can vary. |
| Low-touch onboarding | Enable for supported corporate-owned deployments if desired | Select from Defender's configuration designer. Reduces onboarding steps but doesn't eliminate all Android user-consent requirements. |
| User UPN | Use Intune's user principal name variable offered by the configuration designer | Do not type one user's UPN. Select the Intune token/variable corresponding to the assigned user identity. |
| Web Protection | Configure according to Defender security requirements | Defender Web Protection uses a local loopback VPN. It is conceptually different from Microsoft Tunnel. Test combined behavior using Microsoft's supported configuration. |
| Verbose logging | Disabled during normal operation | Users/admins can enable it temporarily for diagnostics; disable after troubleshooting. |

## 10. Private CA trust, when applicable

If the Tunnel Gateway TLS certificate is issued by a private CA, deploy the trust chain to Android before assigning the Tunnel VPN profile broadly.

Create Android Enterprise **Trusted certificate** profiles for:

1. The private root CA certificate.
2. Each issuing/intermediate CA certificate needed to build the chain.

Recommended sequence:

1. Assign the Trusted certificate profiles to the pilot group.
2. Confirm successful deployment in Intune.
3. Confirm the device trusts the chain.
4. Assign/test the Tunnel VPN profile.

The Tunnel Site public FQDN must match the TLS certificate SAN.

## 11. Assignments

Use the same pilot population for the dependent objects unless there is a documented reason not to.

| Object | Recommended assignment |
|---|---|
| Defender app | Required to pilot user group |
| Defender app configuration | Pilot user group |
| Microsoft Tunnel VPN profile | Pilot user group or device group, consistently with the enrollment and app design |
| Always-on/device restrictions profile | Same target population as the VPN profile |
| Trusted CA profiles | Same population, deployed before Tunnel use |
| Per-app applications | Required/available assignments according to application rollout plan |

Avoid mixing user and device assignments without understanding how the target Android enrollment type processes each policy.

## 12. Example configurations

### Example A: Corporate-owned fully managed, per-app, always-on

Use case: managed Android devices need internal web applications through Edge and an internal business app.

| Setting | Example value |
|---|---|
| Profile name | `Android COBO - Microsoft Tunnel - Per App - Prod` |
| Connection type | Microsoft Tunnel |
| Connection name | `Contoso Secure Access` |
| Tunnel Site | `EU-Production-Tunnel` |
| Per-app list | Microsoft Edge; Contoso Field App |
| Always-on | Enabled |
| Strict Tunnel Mode | Not configured during pilot; enable only after fail-closed approval/testing |
| Proxy | Not configured |
| Defender app | Required |
| Defender package ID, if requested | `com.microsoft.scmx` |

Expected result: Defender continuously maintains Tunnel availability, but only traffic from the selected apps uses the Tunnel profile.

### Example B: Personally owned work profile, per-app

Use case: BYOD users need the work-profile Edge app to reach internal websites.

| Setting | Example value |
|---|---|
| Profile type | Personally-Owned Work Profile |
| Connection type | Microsoft Tunnel |
| Connection name | `Contoso Work Access` |
| Tunnel Site | `EU-Production-Tunnel` |
| Per-app list | Managed Microsoft Edge in the work profile |
| Always-on | Enable after pilot validation, if required |
| Strict Tunnel Mode | Not configured unless the customer accepts loss of work-profile network access during Tunnel failure |

Expected result: only the managed work-profile application is associated with Tunnel; personal-profile applications aren't selected by the work-profile VPN policy.

### Example C: Device-wide, high-security deployment

Use case: corporate-managed devices must send all network traffic through Tunnel and fail closed.

| Setting | Example value |
|---|---|
| Connection type | Microsoft Tunnel |
| Per-app list | Empty |
| Always-on | Enabled |
| Strict Tunnel Mode | Enabled after full validation |
| Server split routes | Designed to include/exclude destinations according to approved security architecture |
| Operational requirement | 24x7 Tunnel availability, tested recovery, help-desk procedure |

Expected result: always-on without a defined app list provides Tunnel access for all device network traffic. Strict Tunnel Mode blocks network access when Tunnel drops.

## 13. Validation procedure

### Intune-side validation

1. Confirm Defender is installed under the app's device/user install status.
2. Confirm the VPN profile reports success for the pilot device.
3. Confirm device restrictions/always-on and trusted certificate profiles report success.
4. Confirm the device is compliant if Conditional Access requires compliance.
5. Confirm the Tunnel Site and servers report healthy in **Tenant administration > Microsoft Tunnel Gateway**.

### Device-side validation

1. Open Microsoft Defender.
2. Sign in with the work account if prompted.
3. Open the **Tunnel** section.
4. Confirm the connection status.
5. Open **Details** and verify:
   - Address matches the expected Site endpoint.
   - Always-on reflects the policy.
   - Device-wide connection reflects the intended design.
   - Apps that use Tunnel match the per-app list.
6. Test an internal FQDN and application.
7. Test direct Internet/Microsoft 365 access according to the split-tunnel design.
8. For Strict Tunnel Mode testing, use an approved maintenance test to verify expected fail-closed behavior.

## 14. Common problems

| Symptom | What to verify |
|---|---|
| Defender is installed but no Tunnel configuration appears | VPN profile assignment, correct Android Enterprise profile type, selected Microsoft Tunnel Site, device sync, and user licensing. |
| Tunnel Site isn't available in the profile picker | A valid Site must exist under Tenant administration > Microsoft Tunnel Gateway, with a Server configuration associated. |
| User can connect manually but always-on doesn't work | Confirm both the VPN profile and required device restrictions/Connectivity always-on configuration are assigned; ensure no second always-on VPN policy exists. |
| Device loses all Internet access | Check whether Strict Tunnel Mode/lockdown is enabled and whether Tunnel authentication, certificate trust, DNS, routes, and server availability are healthy. |
| Internal FQDN doesn't resolve | Check DNS servers and DNS suffix search in the Tunnel Server configuration, plus routing from the Tunnel server to those DNS servers. |
| Internal IP is unreachable | Check include/exclude routes in the Server configuration, on-premises routing/firewalls, and whether the client IP range conflicts with corporate ranges. |
| TLS trust error | Check Site FQDN against certificate SAN, full server certificate chain, private CA Trusted certificate profile deployment, and certificate validity/revocation availability. |
| Per-app traffic doesn't use Tunnel | Confirm the exact managed app was added to the VPN profile and that the correct work/personal profile instance is being tested. |
| Defender Web Protection and Tunnel behavior is unclear | Remember that Defender Web Protection uses a local loopback VPN, while Microsoft Tunnel provides corporate network access. Validate the supported combined configuration and avoid overlapping third-party always-on VPN policies. |

## 15. Recommended baseline summary

| Area | Recommended production starting point |
|---|---|
| Client app | Microsoft Defender, Managed Google Play, Required assignment |
| Connection type | Microsoft Tunnel |
| Site | Select the intended healthy production Site from Intune |
| Connection name | Customer-friendly name such as `Contoso Secure Access` |
| Traffic scope | Per-app VPN for only the apps requiring private connectivity |
| Always-on | Enabled after pilot validation for corporate-managed scenarios |
| Strict Tunnel Mode | Not configured during pilot; enable only for an approved fail-closed requirement |
| Microsoft 365 traffic | Keep direct where possible through split-tunnel design |
| Proxy | Not configured unless required and tested |
| Defender permissions | Auto-grant supported required permissions according to security/privacy requirements |
| Private CA | Deploy root/intermediate trust before Tunnel use |
| Assignment | Dedicated pilot first, staged production rollout second |
| Operational validation | Intune policy status, Defender Tunnel details, internal app access, DNS, Internet bypass, and failure recovery |

## 16. References

- [Microsoft Tunnel overview](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/overview)
- [Configure Microsoft Tunnel](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/install)
- [Android Enterprise VPN settings in Intune](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-vpn-settings-android-enterprise)
- [Deploy Microsoft Defender for Endpoint on Android with Intune](https://learn.microsoft.com/en-us/defender-endpoint/android-intune)
- [Configure Microsoft Defender for Endpoint features on Android](https://learn.microsoft.com/en-us/defender-endpoint/android-configure)
- [Use Microsoft Tunnel on Android](https://learn.microsoft.com/en-us/intune/user-help/vpn/microsoft-tunnel-android)

## Disclaimer

This document is a deployment template. Available settings can differ by Android Enterprise enrollment type, Android version, Intune user interface revision, Defender version, and tenant configuration. Validate the final configuration in a pilot group and against current Microsoft documentation before production rollout.
