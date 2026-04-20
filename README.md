# Azure Cloud NGFW — Forced Tunneling via S2S BGP

Terraform deployment demonstrating forced internet tunneling through Palo Alto Networks Cloud NGFW (Strata Cloud Manager managed) via BGP-over-IPsec S2S VPN. Covers both the **Hub VNet** and **Virtual WAN** CNGFW deployment models in a single configuration.

An external BGP peer (simulating on-premises) advertises `0.0.0.0/0` over IKEv2 S2S tunnels to both the Hub VNet VNG and the vWAN Hub VPN Gateway, causing internet-bound traffic from Azure workloads to egress through the on-premises path via CNGFW inspection.

---

## Architecture

```
                    External BGP Peer
                    remote_peer_public_ike_ip / remote_peer_asn
                    Advertises 0.0.0.0/0
                         │
              IKEv2 S2S  │  IKEv2 S2S (×2 active-active)
         ┌───────────────┼───────────────────┐
         │                                   │
         ▼                                   ▼
  ┌───────────────────────────┐    ┌───────────────────────────┐
  │  Hub VNet 10.128.0.0/16   │    │  vWAN Hub 10.129.0.0/23   │
  │                           │    │                            │
  │  VNG (GatewaySubnet)      │    │  VPN GW (inst0 + inst1)   │
  │  BGP ASN 65515            │    │  BGP ASN 65515 (fixed)     │
  │                           │    │                            │
  │  Cloud NGFW               │    │  Cloud NGFW (PAN NVA)      │
  │  Trusted  10.128.1.0/24   │    │  Routing intent via portal │
  │  Untrusted 10.128.2.0/24  │    │                            │
  └────────────┬──────────────┘    └──────────────┬────────────┘
               │ VNet Peering                     │ Hub Connection
               │ use_remote_gateways              │
               ▼                                  ▼
  ┌────────────────────────────┐   ┌──────────────────────────┐
  │ Workload VNet              │   │ Workload VNet             │
  │ 10.130.0.0/16              │   │ 10.131.0.0/16             │
  │ VM: 10.130.0.4             │   │ VM: 10.131.0.4            │
  │ UDR: 0/0 → 10.128.1.4     │   │ Routes via hub            │
  └────────────────────────────┘   └──────────────────────────┘
```

### VNet CNGFW Traffic Flow

```
Outbound:  Workload VM → UDR (0/0 → CNGFW trusted 10.128.1.4) → CNGFW → VNG → S2S tunnel → on-prem → internet
Return:    internet → on-prem → S2S tunnel → VNG → GatewaySubnet UDR (10.130.0.0/16 → 10.128.1.4) → CNGFW → Workload VM
```

- Workload subnet UDR: `0.0.0.0/0 → VirtualAppliance → 10.128.1.4` (CNGFW trusted IP)
- GatewaySubnet UDR: workload VNet prefix `→ VirtualAppliance → 10.128.1.4` — enforces symmetric return path through CNGFW
- BGP route propagation disabled on workload subnet RT to prevent VNG-learned routes from overriding the UDR
- Management backdoor routes (`allowed_mgmt_cidrs → Internet`) on workload subnet RT for direct SSH access

### vWAN CNGFW Traffic Flow

```
Outbound:  Workload VM → vWAN hub → routing intent → CNGFW → VPN GW → S2S tunnel → on-prem → internet
```

- Routing intent configured via portal (not managed by Terraform)
- vWAN Hub VPN GW is active-active with two instances; both tunnel to the same external peer

---

## IP Allocation

| Resource | CIDR |
|---|---|
| Hub VNet | 10.128.0.0/16 |
| GatewaySubnet | 10.128.0.0/27 |
| CNGFW Trusted | 10.128.1.0/24 |
| CNGFW Untrusted | 10.128.2.0/24 |
| CNGFW Mgmt | 10.128.3.0/24 |
| vWAN Hub | 10.129.0.0/23 |
| VNet Workload VNet | 10.130.0.0/16 |
| vWAN Workload VNet | 10.131.0.0/16 |

---

## Prerequisites

- Azure subscription with Cloud NGFW resource provider registered (`PaloAltoNetworks.Cloudngfw`)
- Strata Cloud Manager (SCM) tenant — both CNGFWs are SCM-managed
- External BGP peer (physical or virtual firewall/router) at a static public IP capable of IKEv2 S2S and BGP
- Terraform >= 1.5
- Azure CLI authenticated (`az login`)

---

## Usage

```bash
cp example.tfvars terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

After apply, retrieve VPN configuration for the external peer:

```bash
# Azure-side VPN endpoints and BGP IPs
terraform output

# Full PAN-OS set commands (requires generate_panos_config = true in tfvars)
terraform output -raw panos_vpn_set_commands
```

---

## Key Variables

| Variable | Description |
|---|---|
| `subscription_id` | Azure subscription ID |
| `location` | Azure region (default: `eastus`) |
| `prefix` | Naming prefix for all resources |
| `remote_peer_public_ike_ip` | Public IP of external BGP peer — IKE tunnel endpoint |
| `remote_peer_private_bgp_ip` | Inner/loopback IP of external peer — BGP session source |
| `remote_peer_asn` | BGP ASN of external peer |
| `vpn_shared_key` | Pre-shared key for both S2S connections |
| `vng_bgp_asn` | Hub VNet VNG BGP ASN (default: 65515) |
| `scm_tenant_name` | Strata Cloud Manager tenant name |
| `allowed_mgmt_cidrs` | CIDRs for SSH access to workload VMs (also bypasses UDR as backdoor route) |
| `ssh_public_key` | SSH public key for workload VM access (`azureuser`) |

---

## PAN-OS Configuration Generation

Set `generate_panos_config = true` and configure the `panos_*` variables to render a complete PAN-OS configure-mode `set` CLI script after apply. The script is populated with Azure-side IPs (BGP peer addresses, IKE endpoints) interpolated directly from Terraform outputs.

Covers:
- IKE/IPsec crypto profiles (multi-algorithm for Azure compatibility)
- IKE gateways with local/peer identities for all 3 tunnels (VNet VNG + vWAN inst0/inst1)
- IPsec tunnels bound to tunnel interfaces
- Security zone assignments for tunnel and loopback interfaces
- Static `/32` host routes for Azure BGP peer IPs via tunnel interfaces
- BGP peer groups and peers
- Redistribution profile and redist-rules to advertise `0.0.0.0/0` to Azure
- `reject-default-route no` and `allow-redist-default-route yes`
- Security policies: loopback↔tunnel (BGP + ping), tunnel→egress (any)
- Interface SNAT rule: tunnel zone → egress zone

| Variable | Default | Description |
|---|---|---|
| `generate_panos_config` | `false` | Set `true` to populate `panos_vpn_set_commands` output |
| `panos_router_type` | `virtual-router` | `virtual-router` or `logical-router` |
| `panos_vr` | `default` | Virtual/logical router name |
| `panos_outside_iface` | `ethernet1/1` | Outside/untrust interface (IKE local-address) |
| `panos_loopback_iface` | `loopback.1` | Loopback for BGP source IP = `remote_peer_private_bgp_ip` |
| `panos_tunnel_vnet` | `tunnel.10` | Tunnel interface → VNet VNG |
| `panos_tunnel_vwan0` | `tunnel.11` | Tunnel interface → vWAN VPN GW instance 0 |
| `panos_tunnel_vwan1` | `tunnel.12` | Tunnel interface → vWAN VPN GW instance 1 |
| `panos_tunnel_zone` | `vpn-zone` | Security zone for all three tunnel interfaces |
| `panos_loopback_zone` | `loopback-zone` | Security zone for loopback interface |
| `panos_egress_zone` | `untrust` | Egress/untrust security zone |

---

## vWAN Routing Intent

Routing intent is **not managed by Terraform** — configure it via the Azure portal after apply:

1. Navigate to vWAN hub → **Routing Intent and Routing Policies**
2. Set next hop to the CNGFW NVA for **Private Traffic** (and **Internet Traffic** if desired)

See [Azure vWAN Internet Routing](https://learn.microsoft.com/en-us/azure/virtual-wan/about-internet-routing) for details on how BGP-learned routes interact with routing intent.

---

## Outputs

| Output | Description |
|---|---|
| `vnet_vng_public_ip` | VNet VNG public IP (IKE endpoint) |
| `vnet_vng_bgp_asn` | VNet VNG BGP ASN |
| `vnet_vng_bgp_peering_address` | VNet VNG BGP peering address |
| `vwan_vpngw_bgp_asn` | vWAN VPN GW BGP ASN (65515) |
| `vwan_vpngw_instance0_public_ip` | vWAN VPN GW instance 0 public IP |
| `vwan_vpngw_instance0_bgp_ips` | vWAN VPN GW instance 0 BGP IPs |
| `vwan_vpngw_instance1_public_ip` | vWAN VPN GW instance 1 public IP |
| `vwan_vpngw_instance1_bgp_ips` | vWAN VPN GW instance 1 BGP IPs |
| `cngfw_vnet_public_ip` | VNet CNGFW public IP |
| `cngfw_vwan_public_ip` | vWAN CNGFW public IP |
| `workload_vnet_vm_public_ip` | VNet path workload VM SSH target |
| `workload_vwan_vm_public_ip` | vWAN path workload VM SSH target |

---

## Supporting Documentation

- [Azure vWAN Internet Routing](https://learn.microsoft.com/en-us/azure/virtual-wan/about-internet-routing)
- [Cloud NGFW for Azure Deployment Architectures](https://live.paloaltonetworks.com/t5/cloud-ngfw-for-azure-articles/cloud-ngfw-for-azure-deployment-architectures/ta-p/626697) — "Centralized VNET Deployment Model: Forced Tunneling Through Private Subnet of Cloud NGFW" (slide 12)
- [Azure VPN Gateway BGP overview](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview)
- [vWAN routing intent and routing policies](https://learn.microsoft.com/en-us/azure/virtual-wan/how-to-routing-policies)
- [Azure VPN Gateway UDRs and BGP](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-forced-tunneling)

---

## Disclaimer

> **This repository is provided for lab and demonstration purposes only.**

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, OR NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**This deployment:**
- Is not validated for production use
- Has not undergone security review
- Deploys permissive security rules intended only for traffic flow validation
- May incur significant Azure costs — VPN Gateway (VpnGw2AZ), Cloud NGFW, and vWAN are not free-tier resources; destroy when not in use
- Requires acceptance of PaloAltoNetworks Marketplace terms in your Azure subscription

MIT License — Copyright (c) 2026
