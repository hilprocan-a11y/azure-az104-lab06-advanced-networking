# Reproduction guide — Windows CMD

Run commands from the repository root. This guide separates the tested baseline/recovery deployments from the documented fresh Block 3 path. Do not interpret a successful local compile as proof of a fresh Azure deployment.

## Prerequisites and setup

Azure CLI, Bicep, an authenticated Azure subscription, two existing SSH public keys, and resource-creation permissions are required. Block 3 also requires role-assignment permissions. Private keys stay on the operator's computer; never pass them to a template or commit them.

Check current regional availability and vCPU quotas before deploying. The observed size was Standard_B2pts_v2 with Ubuntu 24.04 ARM64 in Central US. If changing size, keep it compatible with the image architecture. The default image uses latest; record an exact version for a pinned reproduction. Bastion Developer region support must also be checked.

```cmd
az login
set "LAB06_SUBSCRIPTION=REPLACE_WITH_YOUR_SUBSCRIPTION_ID"
set "LAB06_RG=rg-hn-az104-lab06-networking"
for /f "usebackq delims=" %K in ("%USERPROFILE%\.ssh\lab06-a.pub") do set "LAB06_SSH_A=%K"
for /f "usebackq delims=" %K in ("%USERPROFILE%\.ssh\lab06-b.pub") do set "LAB06_SSH_B=%K"
```

Adapt both public-key paths. Use `%K` at the CMD prompt, `%%K` inside a batch file. Do not commit environment-specific parameter files.

The VMs, disks, DNS zones and Private Endpoint can incur charges. Bastion Developer was used instead of a paid dedicated tier. No NAT Gateway or paid Bastion upgrade is part of this guide. Recheck current prices and your subscription offer before provisioning; no fixed cost ceiling is claimed.

## 1. Baseline / Block 1

```cmd
az group create --subscription "%LAB06_SUBSCRIPTION%" --name "%LAB06_RG%" --location centralus --tags Environment=Training Lab=Lab06 Project=AZ104 Owner=Hilaire
az bicep build --file bicep\main.bicep
az deployment group validate --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --template-file bicep\main.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%"
az deployment group what-if --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --template-file bicep\main.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%"
```

After reviewing the prediction, deploy:

```cmd
az deployment group create --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name lab06-baseline --template-file bicep\main.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%" --query "{State:properties.provisioningState,Outputs:properties.outputs}" --output json
az network vnet peering list --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --vnet-name vnet-lab06-a --output table
az network vnet peering list --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --vnet-name vnet-lab06-b --output table
```

Use returned VM IPs in every diagnostic below; examples assume observed .4 addresses. Require Connected in both peering directions. Test both initiators:

```cmd
az vm run-command invoke --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name vm-lab06-a --command-id RunShellScript --scripts "ping -c 4 -W 2 10.61.1.4" --query "value[].message" --output tsv
az vm run-command invoke --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name vm-lab06-b --command-id RunShellScript --scripts "ping -c 4 -W 2 10.60.1.4" --query "value[].message" --output tsv
```

Expected: 4/4 replies in each direction. To replay the before-peering experiment, start in an empty group with enablePeering=false, test, then deploy with true and repeat unchanged. Setting false in incremental mode does not remove existing peerings.

## 2. UDR, IP and ASG exercises

block2.bicep is a complete baseline variant. Review what-if before each deployment. First adopt the clean baseline with default parameters, then repeat with a single filter enabled. Substitute the relevant parameters into this command:

```cmd
az deployment group create --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name lab06-block2 --template-file bicep\block2.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%" blockWithUdr=false icmpFilterMode=None
```

| Test | Parameters | Expected A-to-B ping |
|---|---|---|
| UDR block | blockWithUdr=true, icmpFilterMode=None | 100% loss |
| Restore route | blockWithUdr=false, icmpFilterMode=None | 4/4 replies |
| Destination IP deny | blockWithUdr=false, icmpFilterMode=Ip | 100% loss |
| Destination ASG deny | blockWithUdr=false, icmpFilterMode=Asg | 100% loss |
| Restore security | blockWithUdr=false, icmpFilterMode=None | 4/4 replies |

If actual VM IPs differ, pass sourcePrivateIpv4 and destinationPrivateIpv4. These templates own the route/rule arrays, so the restoring values remove those test entries. This is different from simply omitting a separately declared resource.

Inspect VM A's effective routes and VM B's effective security rules to explain the selected route and winning NSG rule. Keep only one filtering mechanism enabled at a time. Retain ASG membership after recovery. Save results and clean up the group before starting an independent block.

## 3. DNS and endpoint comparison — portal first

Restore the baseline if the group was deleted. Through the portal, enable system-assigned identities on both VMs, assign Storage Blob Data Reader to each at storage-account scope, create a private container endpoint-tests, and upload data/endpoint-test.txt. Use a globally available storage account name; the original name is historical.

Reproduce the comparison in this order:

1. Create lab06.internal, link both VNets with autoregistration enabled, and test both VM FQDNs with getent hosts and ping.
2. Create public zone lab06.example and www A 192.0.2.10, TTL 60. Query a name server actually returned by this zone with nslookup. This direct query does not delegate the reserved domain on the Internet.
3. With storage public access initially enabled for all networks and the private blob seeded, verify both VM identity reads return HTTP 200.
4. Enable Microsoft.Storage on subnet A, restrict storage to that subnet, remove bypass exceptions, and repeat. Expect A HTTP 200 and B HTTP 403 through the public endpoint.
5. Create pe-lab06-blob targeting blob, with NIC nic-pe-lab06-blob in VNet B/subnet-workload. Integrate privatelink.blob.core.windows.net and link both VNets, autoregistration disabled. Expect the ordinary storage hostname to resolve to the PE private IP, and both reads to return 200.
6. Disable storage public network access, then repeat both reads. Expect private resolution and HTTP 200.

Adapt the default LAB06_STORAGE_ACCOUNT value in scripts/test-storage-endpoint.sh to your account before invoking it. Do not print bearer tokens.

```cmd
az vm run-command invoke --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name vm-lab06-a --command-id RunShellScript --scripts @scripts/test-storage-endpoint.sh --query "value[].message" --output tsv
az vm run-command invoke --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name vm-lab06-b --command-id RunShellScript --scripts @scripts/test-storage-endpoint.sh --query "value[].message" --output tsv
```

Python 3 must be available in the VM. Read DNS_IPV4, BLOB_HTTP_STATUS and BLOB_CONTENT; management command success is not sufficient.

### Adopt the portal-built Block 3 configuration

Use block3.bicep with the current public keys and the actual storageAccountName. Read current VM principal IDs, role assignment GUIDs and portal-generated connection/DNS names before writing a private parameter file. Do not reuse the original deleted identities or assignments.

| Parameter | Adoption requirement |
|---|---|
| storageAccountName | Existing account |
| existingBlobReaderRoleAssignmentNames | Object with a and b keys containing the actual existing assignment GUIDs |
| blobDnsLinkBName | Existing B VNet link name |
| blobPrivateLinkConnectionName | Existing PE connection name |
| blobDnsConfigName | Existing zone-group DNS configuration name |
| storageAccessMode | PrivateOnly for the final state |

Compile, validate and review what-if with these parameters before create. Preserve current identities and existing assignment names; a different GUID for the same principal/role/scope may fail with RoleAssignmentExists. Verify both private reads, DNS and public-access Disabled after adoption.

### Fresh Block 3 path — not yet tested end to end

The source supports fresh identities using deterministic role assignment names when existingBlobReaderRoleAssignmentNames is empty. Choose an available storageAccountName, a new B DNS link name, and retain the connection/config defaults unless you deliberately change them. The container is declared, but the payload is not.

A proposed seeding path is to deploy with storageAccessMode=AllNetworks, upload data/endpoint-test.txt from the operator's computer using suitable data permissions, then redeploy PrivateOnly and verify both VM reads. VM Blob Data Reader does not authorize the operator's upload. Role propagation can take time. AllNetworks temporarily opens network reachability to the public endpoint, while anonymous Blob access remains disabled.

Private Endpoint and DNS links exist in every mode of this template. Changing storageAccessMode alone does not replay the earlier public-IP service-endpoint comparison. Use the staged portal exercise above for that observation. Fresh Block 3 provisioning/seeding has not been validated by the recorded lab and is not promised as a tested one-command rebuild.

## 4. Bastion Developer and Network Watcher

Start from the baseline in an independent group lifecycle. In the portal, select VM A > Connect > Bastion and choose Developer. Use azureuser and VM A's local private key. Connect to A in its own VNet. Allow the portal connection popup if blocked. Do not select a paid dedicated SKU as a substitute without reviewing its requirements and cost.

Inside the browser SSH session:

```bash
hostname
ip -brief address
ping -c 4 -W 2 10.61.1.4
```

Network Watcher must be enabled in the VM region. Reuse an existing regional watcher; do not create a duplicate or include a shared watcher in the lab cleanup.

In Next hop choose VM A, NIC A, source 10.60.1.4, destination 10.61.1.4. Expect VirtualNetworkPeering / System Route. In IP flow verify choose VM B/NIC B, TCP Inbound, local 10.61.1.4:22, remote 10.60.1.4:50000. Expect AllowVnetInBound.

Add deny-ssh-a-to-b to NSG B: source 10.60.1.4/32, source port *, destination 10.61.1.4/32, TCP destination port 22, Deny, priority 200. Repeat IP flow verify and require that exact deny rule. Remove it and require Allow again. The Bastion session on A is outside this targeted A-to-B rule.

CLI readback and equivalent packet-rule test:

```cmd
az network bastion show --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name vnet-lab06-a-bastion --query "{Name:name,SKU:sku.name,State:provisioningState,VNet:virtualNetwork.id}" --output json
az network watcher test-ip-flow --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --vm vm-lab06-b --nic nic-lab06-b --direction Inbound --protocol TCP --local 10.61.1.4:22 --remote 10.60.1.4:50000 --output json
```

The CLI may offer to install its official bastion extension. Developer does not support the native-client workflow used by paid tiers; these CLI commands inspect configuration rather than open a Bastion SSH tunnel.

Compile, validate and review the prediction, then adopt:

```cmd
az bicep build --file bicep\block4.bicep
az deployment group validate --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --template-file bicep\block4.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%"
az deployment group what-if --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --template-file bicep\block4.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%"
az deployment group create --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --name lab06-block4-bicep --template-file bicep\block4.bicep --parameters sshPublicKeyA="%LAB06_SSH_A%" sshPublicKeyB="%LAB06_SSH_B%" --query "{State:properties.provisioningState,Outputs:properties.outputs}" --output json
```

Require Succeeded, Developer and the expected returned IPs. Repeat IP flow verify, open a new browser Bastion login and repeat the ping. The observed lab passed these checks after adoption.

## Cleanup after each independent block

Save evidence and inspect the dedicated group. The deletion command removes everything in that group, including VMs and their disks. It does not target shared regional watchers outside the group.

```cmd
az resource list --subscription "%LAB06_SUBSCRIPTION%" --resource-group "%LAB06_RG%" --query "[].{Name:name,Type:type}" --output table
az group delete --subscription "%LAB06_SUBSCRIPTION%" --name "%LAB06_RG%" --yes
az group exists --subscription "%LAB06_SUBSCRIPTION%" --name "%LAB06_RG%"
set "LAB06_SSH_A="
set "LAB06_SSH_B="
```

Require false. Reload the public-key variables before a later deployment session. A system-assigned identity is deleted with its VM; recreate roles using the new principal IDs in later sessions. Keep local sources and private keys in their intended locations.
