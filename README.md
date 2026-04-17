# Azure Cloud NGFW — Forced Tunneling via S2S BGP

Deploys two Cloud NGFW (CNGFW) instances managed by Strata Cloud Manager (SCM) — one in a hub VNet and one in a vWAN hub — with forced tunneling via S2S BGP to a single external public IP.

---

## Architecture

```
External BGP Peer (single public IP)
  │  advertises 0.0.0.0/0
  ├── S2S BGP ──► Hub VNet VNG ──► Hub VNet ──► VNet CNGFW
  │                                               │
  │                                          Workload VNet (peered)
  │                                          UDR: 0/0 → CNGFW trusted IP
  │
  └── S2S BGP ──► vWAN Hub VPN GW ──► vWAN CNGFW
                                         │
                                    Workload VNet (vWAN spoke)
                                    Routing Intent: private traffic → CNGFW
```

**Traffic flow (both paths):** Workload VM → CNGFW (inspection) → VPN GW → BGP tunnel → external peer → internet

---

## IP Allocation

| Resource | CIDR |
|---|---|
| Hub VNet | 10.128.0.0/16 |
| GatewaySubnet | 10.128.0.0/27 |
| CNGFW Trusted | 10.128.1.0/24 |
| CNGFW Untrusted | 10.128.2.0/24 |
| CNGFW Mgmt | 10.128.3.0/24 |
| VNet Workload VNet | 10.130.0.0/16 |
| vWAN Hub | 10.129.0.0/23 |
| vWAN Workload VNet | 10.131.0.0/16 |

---

## Prerequisites

- Azure subscription (sandbox)
- Strata Cloud Manager TSG ID
- An external device (physical or virtual) with the BGP peer public IP that will advertise `0.0.0.0/0` over the S2S tunnels
- `az login` or service principal configured

---

## Usage

```bash
cp example.tfvars terraform.tfvars
# edit terraform.tfvars with your values

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

---

## Key Variables

| Variable | Description |
|---|---|
| `subscription_id` | Azure subscription (sandbox) |
| `bgp_peer_public_ip` | Single public IP of external BGP peer |
| `bgp_peer_asn` | External peer ASN (default: 65001) |
| `vpn_shared_key` | S2S VPN shared key (both connections) |
| `vng_bgp_asn` | Hub VNet VNG ASN (default: 65515) |
| `vwan_bgp_asn` | vWAN Hub VPN GW ASN (default: 65516) |
| `scm_tsg_id` | SCM Tenant Security Group ID |
| `allowed_mgmt_cidrs` | CIDRs for SSH validation to workload VMs |

---

## vWAN Routing Intent

Private traffic only — internet traffic is handled by the BGP-learned `0.0.0.0/0` from the vWAN Hub VPN Gateway:

```
PrivateTrafficPolicy → CNGFW (destinations: PrivateTraffic)
```

The `0.0.0.0/1` and `128.0.0.0/1` additional private prefixes ensure full private address space coverage through the CNGFW. Configure these in SCM or verify `azurerm_virtual_hub_routing_intent` `additional_prefixes` support in azurerm 4.69.

---

## Validation

After apply:

1. Configure the external BGP peer device with the VNG public IP and vWAN Hub VPN GW IPs (see `terraform output`)
2. Verify BGP sessions establish and `0.0.0.0/0` is learned by both gateways
3. Deploy a test VM in each workload subnet
4. Trace traffic through each CNGFW via SCM logs

---

## Known Schema Notes

- `azurerm_palo_alto_next_generation_firewall_virtual_network_strata_cloud_manager`: verify `panorama_configuration.tsg_id` field name against azurerm 4.69 provider docs
- `azurerm_palo_alto_next_generation_firewall_virtual_hub_strata_cloud_manager`: verify `network_profile.public_ip_count` field name
- `azurerm_virtual_hub_routing_intent`: if `additional_prefixes` is needed for `0.0.0.0/1` and `128.0.0.0/1`, add to the `routing_policy` block once confirmed available in provider

---

## Disclaimer

Lab and proof-of-concept use only. Not validated for production.
