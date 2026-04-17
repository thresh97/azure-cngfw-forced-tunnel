subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "eastus"
prefix          = "cngfw-ft"

# External BGP peer — single public IP that advertises 0.0.0.0/0
bgp_peer_public_ip = "203.0.113.1"
bgp_peer_asn       = 65001
vpn_shared_key     = "changeme-use-a-strong-key"

# Azure VNG and vWAN Hub VPN GW BGP ASNs
vng_bgp_asn  = 65515
vwan_bgp_asn = 65516

# Strata Cloud Manager TSG ID
scm_tsg_id = "your-tsg-id-here"

# CIDRs for direct SSH validation to workload VMs
allowed_mgmt_cidrs = ["203.0.113.0/24"]
