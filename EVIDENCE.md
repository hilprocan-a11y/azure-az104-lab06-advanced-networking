# Verification summary

October 17–18, 2026 (Edmonton). This is an English summary of user-provided screenshots and CLI results, not a verbatim transcript. Original evidence is preserved in the private local archive. IP addresses below are historical private or documentation addresses.

## Block 1 — Private connectivity and peering

| Check | Observed result |
|---|---|
| Baseline before peering | A-to-B ping: 4 transmitted, 0 received, 100% loss |
| Peerings | Both Connected, virtual network access enabled |
| Portal/CLI connectivity | Both directions: 4/4 replies, 0% loss |
| Bicep first attempt | Failed on explicit Standard VM security type requiring a subscription feature |
| Correction | Omitted securityProfile with Compute API 2024-11-01; deployment succeeded |
| Bicep connectivity | Both directions: 4/4 replies, 0% loss |
| Final routing/security | A route to 10.61.0.0/16 Active / VNetPeering; NSGs without custom rules; securityProfile null |
| Cleanup | Group existence false |

## Block 2 — UDR, NSG and ASG

| Mechanism | Blocked state | Restored state |
|---|---|---|
| User route to 10.61.0.0/16 / next hop None | A-to-B 100% ping loss | Empty route array, 4/4 replies |
| B inbound ICMP deny using IP addresses | A-to-B 100% ping loss | Rule removed, 4/4 replies |
| B inbound ICMP deny targeting ASG B | A-to-B 100% ping loss | Rule removed, 4/4 replies |

Portal/CLI exercises were reproduced with block2.bicep. Final readback: route table rt-lab06-a remains associated with subnet A but has no routes; both NSGs have no custom rules; NIC B remains a member of asg-lab06-b. Group existence false confirmed cleanup.

## Block 3 — DNS and storage endpoints

| Stage | VM A | VM B |
|---|---|---|
| All networks / valid managed identities and roles | Blob HTTP 200 | Blob HTTP 200 |
| Only subnet A allowed through service endpoint | Public endpoint / HTTP 200 | Same public endpoint / HTTP 403, AuthorizationFailure |
| Private Endpoint and private DNS linked to both VNets | DNS 10.61.1.5 / HTTP 200 | DNS 10.61.1.5 / HTTP 200 |
| Public storage access Disabled | Private address / HTTP 200 | Private address / HTTP 200 |
| After in-place Bicep adoption | Private address / HTTP 200 | Private address / HTTP 200 |

Additional readbacks: Private Endpoint Succeeded / Approved in VNet B's workload subnet; storage public access Disabled, default action Deny, bypass None. Both VM system-assigned identities had Storage Blob Data Reader at account scope and their principal IDs were preserved during adoption.

Private zone lab06.internal had two autoregistration links. Name resolution and ping by VM FQDN passed in both directions. Direct authoritative lookup of www.lab06.example returned 192.0.2.10; no public domain delegation was tested. After Bicep, A-to-B ping by FQDN returned 4/4 replies, 0% loss.

Azure validation succeeded. Adoption what-if: 15 modifications, 12 unchanged, 3 ignored, no resource creation/deletion. Existing role assignment names and portal-generated DNS names were preserved. The deployment succeeded; this was not a fresh empty-group test. Final group existence false confirmed cleanup.

## Block 4 — Bastion and Network Watcher

| Check | Observed result |
|---|---|
| Baseline recreation | Succeeded; VM A 10.60.1.4, VM B 10.61.1.4 |
| Bastion readback | Developer / Succeeded / VNet A |
| Browser SSH | azureuser login succeeded; hostname vm-lab06-a |
| Next hop A to B | VirtualNetworkPeering / System Route |
| IP flow B inbound TCP/22 from A:50000 | Allow / AllowVnetInBound |
| Add deny-ssh-a-to-b, priority 200 | Deny; exact rule and NSG B identified |
| Remove deny rule | Allow / AllowVnetInBound |
| Bicep validate and preview | Succeeded; 7 modify, 4 unchanged, 2 ignored; no create/delete |
| Bicep adoption | Succeeded; Developer and VM private IPs preserved |
| Post-Bicep IP flow | Allow / defaultSecurityRules/AllowVnetInBound |
| Post-Bicep new SSH and ping | Login succeeded; 4/4 replies from B, 0% loss, average RTT 1.548 ms |
| Final cleanup | Group existence false |

## Interpretation limits

Run Command's management success alone does not establish successful data access; the Blob HTTP status and content were checked separately. HTTP 403 is not always a network error. Its interpretation here relies on the controlled before/after comparison.

Ping verifies ICMP, not every protocol. IP flow verify checks Azure rules for a packet description, not an end-to-end SSH handshake. DNS links and network peering serve different purposes. The configured service endpoint can remain on a subnet even when the storage public endpoint is disabled.

The cleanup checks apply to the dedicated lab group, not every subscription resource. Shared regional Network Watcher resources were not claimed as deleted. No final billed amount was established.
