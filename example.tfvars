subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "eastus"
prefix          = "cngfw-ft"

# External BGP peer — single public IP that advertises 0.0.0.0/0
bgp_peer_public_ip      = "203.0.113.1"
bgp_peer_asn            = 65001
bgp_peer_peering_address = "169.254.0.1"  # inner/loopback IP for BGP session
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
