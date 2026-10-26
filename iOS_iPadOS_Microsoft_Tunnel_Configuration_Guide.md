# Configure Microsoft Defender on iOS/iPadOS as the Microsoft Tunnel Client

This customer-ready guide explains how to deploy Microsoft Defender to enrolled iOS/iPadOS devices and configure it as the client application for Microsoft Tunnel. It includes recommended values, where administrators obtain each value, example configurations, assignments, validation, and troubleshooting.

> [!IMPORTANT]
> This guide covers **Intune-enrolled iOS/iPadOS devices using Microsoft Tunnel through Mobile Device Management (MDM)**. Microsoft Tunnel for Mobile Application Management (MAM) on unenrolled devices uses a different architecture and must not be mixed with the MDM Tunnel configuration on the same enrolled device.

## 1. Architecture

For enrolled iOS/iPadOS devices, Microsoft Intune deploys:

1. Microsoft Defender as the Microsoft Tunnel client app.
2. An iOS/iPadOS VPN profile with **Microsoft Tunnel** as the connection type.
3. Optional per-app VPN associations between the VPN profile and managed apps.
4. Optional Microsoft Defender app configuration, including **TunnelOnly** mode.
5. Trusted CA certificates when the Tunnel Gateway TLS certificate is issued by a private CA.

```text
iOS/iPadOS device
        ↓
Microsoft Defender
        ↓
Intune Microsoft Tunnel VPN profile
        ↓
Selected Microsoft Tunnel Site
        ↓
Tunnel Gateway public FQDN/IP and port
        ↓
Internal corporate resources
```

Microsoft Tunnel uses modern authentication with Microsoft Entra ID and can participate in Conditional Access. The VPN profile can be associated with selected managed apps or used as a broader device connection, depending on the approved design.

## 2. Choose MDM Tunnel or MAM Tunnel

Before creating policies, select one management model.

| Scenario | Recommended technology | Key point |
|---|---|---|
| Device enrolled in Intune and organization manages the VPN profile | Microsoft Tunnel through MDM | Use this guide. Deploy Defender and an Intune iOS/iPadOS VPN profile. |
| Device isn't enrolled and only protected applications need Tunnel | Microsoft Tunnel for MAM | Requires the MAM Tunnel design and applicable Intune add-on licensing. On iOS, the VPN is provided through the Tunnel for MAM SDK integrated into supported apps. |
| Enrolled device already using MAM Tunnel for target apps | Choose MDM or MAM, not both | An enrolled device must not use MDM Tunnel for some apps and MAM Tunnel for other apps. |

## 3. Information to collect

| Required value | Example | Where to find or define it |
|---|---|---|
| Enrollment type | Automated Device Enrollment; device enrollment; user enrollment | Intune admin center > Devices > iOS/iPadOS > iOS/iPadOS enrollment. Confirm how the target device is enrolled. User enrollment supports only per-app VPN. |
| Microsoft Tunnel Site | `EU-Production-Tunnel` | Intune admin center > Tenant administration > Microsoft Tunnel Gateway > Sites. Select the Site containing the intended Tunnel Gateway server. |
| Tunnel public FQDN or IP | `tunnel.contoso.com` | Open the selected Site under Microsoft Tunnel Gateway. The VPN profile obtains the endpoint through the selected Site. The FQDN must match the Tunnel TLS certificate SAN. |
| Tunnel server port | `443` | Tenant administration > Microsoft Tunnel Gateway > Server configurations. Open the configuration associated with the Site and review **Server port**. |
| Internal DNS servers | `10.20.0.10`, `10.20.0.11` | The Server configuration assigned to the Site. Confirm with the DNS/network team. |
| Internal routes | `10.20.0.0/16` | The Server configuration assigned to the Site. Confirm with the network team and ensure routes don't conflict with the Tunnel client IP pool. |
| Managed apps requiring Tunnel | Microsoft Edge; internal business application | Apps > All apps. The target app must be present in Intune before it can be associated with a per-app VPN profile. |
| App bundle ID | Example: obtain from Intune, don't guess | Apps > All apps > Columns > select **App identifier** > Apply. The App identifier column shows the bundle ID. |
| Assignment group | `GRP-iOS-Tunnel-Pilot` | Create or select a Microsoft Entra group. Use a dedicated pilot group before production rollout. |
| Private CA root/intermediate certificates | Customer PKI chain | Obtain from the PKI team and deploy through Intune Trusted certificate profiles before switching the Gateway to a private-CA TLS certificate. |

## 4. Recommended policy/object design

| Object | Purpose | Recommended assignment |
|---|---|---|
| Microsoft Defender iOS/iPadOS app | Installs the Microsoft Tunnel client | Required to the pilot user/device group |
| Microsoft Tunnel VPN profile | Selects the Site and configures VPN behavior | Same pilot population |
| Managed app VPN association | Makes selected apps use the per-app VPN | Associate each required managed app with the VPN profile |
| Defender app configuration | Configures Defender behavior, including optional TunnelOnly mode | Same intended user population |
| Trusted certificate profiles | Establishes trust for a private CA | Deploy before Tunnel use to the same population |
| Compliance/Conditional Access | Controls access using device and identity signals | Design and pilot separately |

## 5. Add Microsoft Defender to Intune

1. In the Intune admin center, go to **Apps > All apps > Add**.
2. Select **iOS store app** or use the applicable Apple app deployment integration in the tenant.
3. Search for and select **Microsoft Defender**.
4. Add the app to Intune.
5. Open the app > **Properties > Assignments**.
6. Assign it as **Required** to the pilot group.

### Recommended app deployment values

| Setting | Recommended value | Explanation |
|---|---|---|
| App | Microsoft Defender | Microsoft Defender is the Microsoft Tunnel client app on enrolled iOS/iPadOS devices. |
| Installation intent | Required | Ensures the Tunnel client is installed before the VPN profile is expected to operate. |
| Assignment | Dedicated pilot group first | Supports controlled validation and limits rollout risk. |
| App updates | Keep current through the selected Apple app distribution method | Maintains a supported Tunnel client version. |

## 6. Create the Microsoft Tunnel VPN profile

In the Intune admin center:

1. Go to **Devices > Configuration > Create > New policy**.
2. Platform: **iOS/iPadOS**.
3. Profile type/template: **VPN**.
4. Configure the profile using the settings below.

### Core settings

| Intune setting | Recommended value | Example | Where the value comes from / implementation note |
|---|---|---|---|
| Profile name | Descriptive, platform-specific name | `iOS - Microsoft Tunnel - Per App - Production` | Defined by the Intune administrator. Include platform, technology, traffic scope, and environment. |
| Connection type | **Microsoft Tunnel** | Microsoft Tunnel | Select from the connection-type list. This exposes the Microsoft Tunnel Site selector. |
| Connection name | Friendly user-facing name | `Contoso Secure Access` | Defined by the customer. This name is visible in the VPN connection information. Avoid internal-only codes. |
| Microsoft Tunnel Site | Select the intended Site | `EU-Production-Tunnel` | Select from the picker. Find existing Sites under Tenant administration > Microsoft Tunnel Gateway > Sites. Don't type an arbitrary name. |
| Server address/FQDN | Use the Site endpoint if the UI requests it | `tunnel.contoso.com` | Obtain from the selected Site. It must match the Subject Alternative Name of the Tunnel Gateway TLS certificate. |
| Authentication | Use the Microsoft Tunnel Microsoft Entra flow presented by Intune | Microsoft Entra authentication | Microsoft Tunnel integrates with Microsoft Entra ID. A generic per-app VPN article might mention trusted/SCEP/PKCS certificates, but Microsoft Tunnel and ZPA integrate with Entra ID and don't require those authentication certificate profiles for that flow. |
| Proxy | Not configured unless explicitly required | Not configured | Configure only when the application/network design requires it and after validating proxy reachability and bypass requirements. |

## 7. Recommended design: per-app VPN

Per-app VPN connects automatically when an associated managed app requires the VPN. Only traffic from associated apps uses the per-app VPN.

### VPN profile values

| Setting | Recommended value | Why |
|---|---|---|
| Per-app VPN | Enabled | Limits private-network access to approved managed apps. |
| On-demand/connect automatically | Enabled for the per-app design | Allows the VPN to start when an associated app is used. |
| Safari URLs | Configure only when Safari itself must trigger per-app VPN for specific internal URLs | Avoid broad entries unless required. For managed browsing, Microsoft Edge is often easier to scope as a managed app. |
| Provider type | Use the Microsoft Tunnel value supplied/exposed by the profile | Don't substitute settings from another vendor's packet/app proxy implementation. |

### Associate managed apps with the VPN profile

For each app that requires Tunnel:

1. Go to **Apps > All apps**.
2. Open the managed app.
3. Open **App configuration** or the app's assignment/properties area that exposes VPN association.
4. Select the created per-app VPN profile.
5. Save the association.

The exact Intune UI can change, but the resulting relationship is:

```text
Managed app → associated per-app VPN profile → selected Microsoft Tunnel Site
```

### Selecting the correct app

| Value | How to determine it |
|---|---|
| App name | Apps > All apps; verify platform is iOS/iPadOS and publisher is correct. |
| Bundle ID/App identifier | Apps > All apps > Columns > App identifier > Apply. Use the displayed value rather than guessing it. |
| Managed instance | Ensure the tested app is the Intune-managed app receiving the VPN association. |
| Business justification | Confirm with the application owner that the app requires private-resource access. Don't add public SaaS applications without a requirement. |

### Recommended app examples

| App scenario | Recommendation |
|---|---|
| Microsoft Edge needs internal intranet access | Associate managed Microsoft Edge with the per-app Tunnel profile. |
| Line-of-business app connects to an internal API | Add/manage the app in Intune, verify the bundle ID, and associate it with the profile. |
| Outlook uses public Microsoft 365 endpoints only | Usually keep it outside Tunnel to avoid unnecessary backhaul and latency. Validate customer requirements. |
| Safari needs only selected internal sites | Evaluate Safari URL/domain-triggered VPN settings and test carefully. |

## 8. Device-wide connection considerations

Microsoft Tunnel can provide device-wide access when no apps are defined for an always-on Tunnel profile. In this model, all device network traffic is associated with Tunnel, subject to server routes and split-tunnel design.

| Setting/design item | Recommended baseline |
|---|---|
| Device-wide use | Use only for an approved requirement that can't be met with per-app VPN. |
| Server routes | Explicitly design include/exclude routes in the Microsoft Tunnel Server configuration. |
| Microsoft 365 traffic | Bypass Tunnel where possible through split tunneling to avoid unnecessary latency. |
| Enrollment | Confirm the enrollment model supports the intended VPN settings. User enrollment is limited to per-app VPN. |
| Pilot validation | Test captive portals, Apple services, app updates, Microsoft 365, DNS, and loss-of-Tunnel behavior. |

> [!CAUTION]
> Device-wide VPN increases the outage and performance impact of Tunnel, DNS, or routing failures. Prefer per-app VPN when only selected business applications require private access.

## 9. Defender mode: full Defender or TunnelOnly

On iOS/iPadOS, Microsoft Defender can operate with its security functionality or in **TunnelOnly** mode.

| Mode | Recommended use | User experience |
|---|---|---|
| Full Defender functionality | Use when Defender for Endpoint protection and Microsoft Tunnel are both required | Defender security functionality remains available together with Tunnel. Follow the current Defender onboarding and permission guidance. |
| `TunnelOnly = true` | Use when the customer wants Defender to provide only Microsoft Tunnel capabilities | Defender security functionality is disabled, leaving Tunnel capabilities. For per-app VPN, users don't need to open/sign in to Defender when a valid Microsoft Entra token is available through Company Portal or another MFA-capable app. |

### Where to configure TunnelOnly

Create a managed app configuration for Microsoft Defender:

1. Go to **Apps > App configuration policies**.
2. Create an app configuration applicable to iOS/iPadOS and Microsoft Defender.
3. Use the configuration designer and select the documented **TunnelOnly** setting when presented.
4. Set it to `true` only when the design intentionally disables Defender security functionality.
5. Assign the policy to the intended pilot users.

> [!IMPORTANT]
> Don't enable TunnelOnly if the same users/devices are expected to use Defender for Endpoint security capabilities. TunnelOnly is an architectural choice, not a generic optimization.

## 10. Private CA trust

When the Tunnel Gateway TLS certificate is issued by a private CA, deploy the required trust chain before assigning the Tunnel profile broadly.

Create iOS/iPadOS **Trusted certificate** profiles for:

1. The private root CA certificate.
2. Each issuing/intermediate CA certificate needed to build the chain.

Recommended order:

1. Assign CA trust profiles to pilot devices.
2. Confirm successful profile installation.
3. Confirm the Tunnel Site FQDN matches the server certificate SAN.
4. Test certificate validation and CRL reachability from representative networks.
5. Assign/test the Tunnel VPN profile.

## 11. Assignments

| Object | Recommended assignment |
|---|---|
| Microsoft Defender | Required to the pilot group |
| Microsoft Tunnel VPN profile | Same pilot population |
| App-to-VPN association | Each managed app that requires private access |
| Defender app configuration / TunnelOnly | Same intended user population, only if required by the design |
| Trusted CA profiles | Same population, deployed before use of the private-CA certificate |
| Conditional Access | Staged separately to avoid combining too many variables during initial Tunnel validation |

## 12. Example configurations

### Example A: Supervised corporate device, Edge per-app VPN

Use case: Corporate iPhones and iPads need Microsoft Edge to reach an internal web application.

| Setting | Example value |
|---|---|
| Profile name | `iOS - Microsoft Tunnel - Edge Per App - Prod` |
| Connection type | Microsoft Tunnel |
| Connection name | `Contoso Secure Access` |
| Tunnel Site | `EU-Production-Tunnel` |
| Associated app | Managed Microsoft Edge |
| Connect automatically/on demand | Enabled through per-app association |
| TunnelOnly | `false` when Defender security is also required; `true` only for Tunnel-only design |
| Proxy | Not configured |

Expected result: launching the managed Edge app triggers the Tunnel connection; nonassociated apps don't use this per-app VPN.

### Example B: User-enrolled BYOD device

Use case: An enrolled personal iPhone using Apple user enrollment requires selected managed apps to access internal resources.

| Setting | Example value |
|---|---|
| Enrollment | User enrollment |
| Traffic model | Per-app VPN only |
| Connection type | Microsoft Tunnel |
| Tunnel Site | `EU-Production-Tunnel` |
| Associated apps | Only managed work apps requiring private access |
| TunnelOnly | Use according to whether Defender security capability is in scope |

Expected result: only the managed applications associated with the VPN profile use Tunnel. User enrollment doesn't support a device-wide VPN configuration.

### Example C: Tunnel-only client experience

Use case: The customer wants Defender to provide Microsoft Tunnel connectivity without Defender security features.

| Setting | Example value |
|---|---|
| Defender app | Required |
| VPN profile | Microsoft Tunnel, per-app |
| TunnelOnly | `true` |
| Authentication prerequisite | User has a valid Microsoft Entra authentication token through Company Portal or another MFA-capable app |
| Associated app | Managed Edge/internal application |

Expected result: per-app Tunnel can operate without requiring the user to open and sign in to Defender, while Defender security functionality is disabled.

## 13. Validation

### Intune-side checks

1. Confirm Microsoft Defender installation succeeded.
2. Confirm the VPN profile reports success.
3. Confirm the managed applications are associated with the intended VPN profile.
4. Confirm Trusted certificate profiles succeeded when using a private CA.
5. Confirm the Tunnel Site and servers are healthy under **Tenant administration > Microsoft Tunnel Gateway**.
6. Confirm device compliance and Conditional Access independently.

### Device-side checks

1. Open Microsoft Defender/Microsoft Tunnel.
2. Sign in with the work account if the selected mode requires it.
3. Open **Details** and verify:
   - Address matches the expected Tunnel Site endpoint.
   - **Device-wide connection** matches the intended design.
   - **Connect on demand** is enabled for per-app VPN.
   - **Apps that use Tunnel** lists the expected applications.
4. Open an associated application and test an internal resource.
5. Test a nonassociated application and confirm its behavior matches the design.
6. Test direct Microsoft 365/Internet connectivity according to the split-tunnel architecture.

The Tunnel client UI can show uptime, data received/sent, server address, proxy details, device-wide status, connect-on-demand status, and apps that use Tunnel.

## 14. Troubleshooting

| Symptom | What to verify |
|---|---|
| Defender is installed but no Tunnel connection appears | VPN profile assignment, device enrollment type, selected Site, policy sync, and user licensing. |
| Site isn't available in the profile | Verify the Site exists under Tenant administration > Microsoft Tunnel Gateway and has a Server configuration. |
| Associated app doesn't trigger Tunnel | Confirm the exact managed iOS app is associated with the VPN profile; check its App identifier/bundle ID and policy status. |
| Tunnel works manually but not per-app | Verify per-app VPN configuration and app association. In the Tunnel client, check Connect on demand and Apps that use Tunnel. |
| User enrollment profile lacks device-wide settings | Expected: Apple user enrollment is limited to per-app VPN. |
| TLS trust error | Check Site FQDN against certificate SAN, complete server chain, private root/intermediate profile deployment, validity, and CRL reachability. |
| Internal name doesn't resolve | Check DNS servers and DNS suffix search in the Tunnel Server configuration and routing to internal DNS. |
| Internal IP is unreachable | Check Tunnel Server include/exclude routes, network firewalls, return routing, and client-IP-pool overlap. |
| Defender security features are missing | Check whether TunnelOnly is set to `true`; that mode disables Defender functionality and leaves Tunnel capabilities. |
| Status toggle isn't shown | Per-app/on-demand configuration can remove the manual Status toggle. Review Details > Connect on demand and associated apps. |
| Need diagnostic evidence | In the Tunnel client, use Help > Send logs. Users can also control verbose logging in iOS Settings > Microsoft Tunnel; enable it only while troubleshooting. |

## 15. Recommended baseline

| Area | Recommended production starting point |
|---|---|
| Client app | Microsoft Defender, Required assignment |
| Connection type | Microsoft Tunnel |
| Tunnel Site | Select the intended healthy production Site from Intune |
| Connection name | Customer-friendly name such as `Contoso Secure Access` |
| Traffic model | Per-app VPN for managed apps requiring private connectivity |
| App identifier | Obtain from Apps > All apps > Columns > App identifier; don't guess |
| Automatic connection | Use per-app/on-demand behavior |
| Device-wide | Use only for a documented requirement and supported enrollment type |
| TunnelOnly | `false` when Defender security is required; `true` only for an intentional Tunnel-only design |
| Microsoft 365 traffic | Keep direct where possible through split-tunnel routing |
| Private CA | Deploy root/intermediate trust before Tunnel use and validate CRL access |
| Rollout | Dedicated pilot first, staged production rollout second |
| Validation | Intune status, client Details, associated app access, DNS, split routing, and failure recovery |

## 16. References

- [Microsoft Tunnel overview](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/overview)
- [Apple VPN settings in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/templates/ref-vpn-settings-apple)
- [Configure per-app VPN for iOS/iPadOS](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-per-app-vpn-ios)
- [Use Microsoft Tunnel on iOS](https://learn.microsoft.com/en-us/intune/user-help/vpn/microsoft-tunnel-ios)
- [Get application bundle IDs in Intune](https://learn.microsoft.com/en-us/intune/app-management/collect-bundle-ids)
- [Microsoft Tunnel for MAM overview](https://learn.microsoft.com/en-us/intune/device-security/microsoft-tunnel/mam)

## Disclaimer

This document is a deployment template. Available settings and UI labels can differ by iOS/iPadOS version, enrollment type, Intune user-interface revision, Defender version, and tenant configuration. Validate the final configuration in a pilot group and against current Microsoft documentation before production rollout.
