subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "eastus"
prefix          = "cngfw-ft"

# External BGP peer — single public IP that advertises 0.0.0.0/0
remote_peer_public_ike_ip      = "203.0.113.1"
remote_peer_asn            = 65001
remote_peer_private_bgp_ip = "169.254.0.1"  # inner/loopback IP for BGP session
vpn_shared_key     = "changeme-use-a-strong-key"

# Azure VNG and vWAN Hub VPN GW BGP ASNs
vng_bgp_asn = 65515
# vwan VPN GW ASN is fixed at 65515 (custom ASN requires Support enablement)

# Strata Cloud Manager tenant name
scm_tenant_name = "your-tenant-name-here"

# CIDRs for direct SSH validation to workload VMs
allowed_mgmt_cidrs = ["203.0.113.0/24"]

# SSH public key for workload VM access (azureuser)
ssh_public_key = "ssh-rsa AAAA... user@host"

# Optional PAN-OS VPN set command generation
#
# Set generate_panos_config = true to render panos_vpn_set_commands after apply.
# Output contains the full configure-mode set CLI to build:
#   - IKE/IPsec crypto profiles (azure-ike, azure-ipsec)
#   - 3 IKE gateways: VNet VNG + vWAN instance 0/1
#   - 3 IPsec tunnels bound to tunnel interfaces below
#   - Loopback interface with remote_peer_private_bgp_ip/32
#   - BGP peer-groups and peers with Azure-side BGP IPs populated from apply
#
# Retrieve with: terraform output -raw panos_vpn_set_commands
#
# panos_router_type: virtual-router (default) or logical-router
# panos_vr:         virtual/logical router name
# panos_outside_iface: ethernet interface used as IKE local-address
# panos_loopback_iface: loopback for BGP source — IP = remote_peer_private_bgp_ip
# panos_tunnel_vnet:   tunnel interface → VNet VNG
# panos_tunnel_vwan0:  tunnel interface → vWAN VPN GW instance 0
# panos_tunnel_vwan1:  tunnel interface → vWAN VPN GW instance 1
generate_panos_config = false
panos_router_type    = "virtual-router"
panos_vr             = "default"
panos_outside_iface  = "ethernet1/1"
panos_loopback_iface = "loopback.1"
panos_tunnel_vnet    = "tunnel.10"
panos_tunnel_vwan0   = "tunnel.11"
panos_tunnel_vwan1   = "tunnel.12"
