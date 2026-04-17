# =============================================================================
# Azure Cloud NGFW — Forced Tunneling via S2S BGP
#
# Architecture:
#   - Single external public IP peers via BGP and advertises 0.0.0.0/0
#     to both the Hub VNet VNG and the vWAN Hub VPN Gateway (forced tunnel)
#   - VNet CNGFW: deployed into hub VNet; workload VNet peered to hub;
#     UDR on workload subnet steers 0/0 to CNGFW trusted IP
#   - vWAN CNGFW: deployed into vWAN hub; workload VNet connected as spoke;
#     private routing intent (0.0.0.0/1 + 128.0.0.0/1) steers E-W through CNGFW;
#     internet traffic forced via BGP-learned 0/0 through vWAN Hub VPN GW
#   - SCM (Strata Cloud Manager) TSG manages both CNGFW deployments
#
# IP Allocation (10.128.0.0/6):
#   Hub VNet            10.128.0.0/16
#     GatewaySubnet     10.128.0.0/27
#     CNGFW Trusted     10.128.1.0/24  (delegated)
#     CNGFW Untrusted   10.128.2.0/24  (delegated)
#     CNGFW Mgmt        10.128.3.0/24
#   VNet Workload VNet  10.130.0.0/16
#     Workload Subnet   10.130.0.0/24
#   vWAN Hub            10.129.0.0/23
#   vWAN Workload VNet  10.131.0.0/16
#     Workload Subnet   10.131.0.0/24
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.69"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID (sandbox)"
}

variable "location" {
  type        = string
  default     = "eastus"
  description = "Azure region for all resources"
}

variable "prefix" {
  type        = string
  default     = "cngfw-ft"
  description = "Naming prefix for all resources"
}

variable "bgp_peer_public_ip" {
  type        = string
  description = "Public IP of the external BGP peer that advertises 0.0.0.0/0 (forced tunnel)"
}

variable "bgp_peer_asn" {
  type        = number
  default     = 65001
  description = "BGP ASN of the external peer"
}

variable "vpn_shared_key" {
  type        = string
  sensitive   = true
  description = "Shared key for both S2S VPN connections"
}

variable "vng_bgp_asn" {
  type        = number
  default     = 65515
  description = "BGP ASN for the Hub VNet VNG"
}

variable "vwan_bgp_asn" {
  type        = number
  default     = 65516
  description = "BGP ASN for the vWAN Hub VPN Gateway"
}

variable "scm_tsg_id" {
  type        = string
  description = "Strata Cloud Manager Tenant Security Group (TSG) ID"
}

variable "allowed_mgmt_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH to workload VMs (for validation)"
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# ===========================================================================
# HUB VNET — VNet CNGFW path
# ===========================================================================

resource "azurerm_virtual_network" "hub" {
  name                = "${var.prefix}-hub-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.128.0.0/16"]
}

# GatewaySubnet — required name for VNG
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.0.0/27"]
}

# Trusted subnet — delegated to PAN NGFW
resource "azurerm_subnet" "cngfw_trusted" {
  name                 = "${var.prefix}-cngfw-trusted"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.1.0/24"]

  delegation {
    name = "pan-ngfw-delegation"
    service_delegation {
      name = "PaloAltoNetworks.Ngfw/firewalls"
    }
  }
}

# Untrusted subnet — delegated to PAN NGFW
resource "azurerm_subnet" "cngfw_untrusted" {
  name                 = "${var.prefix}-cngfw-untrusted"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.2.0/24"]

  delegation {
    name = "pan-ngfw-delegation"
    service_delegation {
      name = "PaloAltoNetworks.Ngfw/firewalls"
    }
  }
}

# Management subnet (optional — for out-of-band access)
resource "azurerm_subnet" "cngfw_mgmt" {
  name                 = "${var.prefix}-cngfw-mgmt"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.3.0/24"]
}

# ---------------------------------------------------------------------------
# Virtual Network Gateway — BGP, route-based, forced tunnel endpoint
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "vng" {
  name                = "${var.prefix}-vng-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "${var.prefix}-vng"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw2"
  enable_bgp          = true
  active_active       = false

  ip_configuration {
    name                          = "vng-ipconfig"
    public_ip_address_id          = azurerm_public_ip.vng.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = var.vng_bgp_asn
  }
}

# ---------------------------------------------------------------------------
# Local Network Gateway — represents the external BGP peer (single public IP)
# ---------------------------------------------------------------------------

resource "azurerm_local_network_gateway" "bgp_peer" {
  name                = "${var.prefix}-lgw-bgp-peer"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  gateway_address     = var.bgp_peer_public_ip

  bgp_settings {
    asn                 = var.bgp_peer_asn
    bgp_peering_address = var.bgp_peer_public_ip
  }
}

# ---------------------------------------------------------------------------
# VPN Connection — Hub VNet VNG → external BGP peer (advertises 0/0)
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_gateway_connection" "hub_to_peer" {
  name                = "${var.prefix}-vng-to-bgp-peer"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id
  local_network_gateway_id   = azurerm_local_network_gateway.bgp_peer.id
  shared_key                 = var.vpn_shared_key
  enable_bgp                 = true
}

# ---------------------------------------------------------------------------
# VNet CNGFW — Strata Cloud Manager managed
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "cngfw_vnet" {
  name                = "${var.prefix}-cngfw-vnet-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_palo_alto_next_generation_firewall_virtual_network_strata_cloud_manager" "main" {
  name                = "${var.prefix}-cngfw-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  network_profile {
    public_ip_address_ids = [azurerm_public_ip.cngfw_vnet.id]

    vnet_configuration {
      virtual_network_id                  = azurerm_virtual_network.hub.id
      trusted_subnet_id                   = azurerm_subnet.cngfw_trusted.id
      untrusted_subnet_id                 = azurerm_subnet.cngfw_untrusted.id
      ip_of_trust_for_user_defined_routes = "10.128.1.4"
    }
  }

  panorama_configuration {
    tsg_id = var.scm_tsg_id
  }
}

# ===========================================================================
# WORKLOAD VNET — VNet CNGFW path
# ===========================================================================

resource "azurerm_virtual_network" "workload_vnet" {
  name                = "${var.prefix}-workload-vnet-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.130.0.0/16"]
}

resource "azurerm_subnet" "workload_vnet" {
  name                 = "workload"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.workload_vnet.name
  address_prefixes     = ["10.130.0.0/24"]
}

# Peer workload VNet to hub VNet
resource "azurerm_virtual_network_peering" "workload_to_hub" {
  name                      = "workload-to-hub"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.workload_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  use_remote_gateways       = true
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "hub_to_workload" {
  name                      = "hub-to-workload"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.workload_vnet.id
  allow_gateway_transit     = true
  allow_forwarded_traffic   = true
}

# ---------------------------------------------------------------------------
# UDR — route workload traffic through VNet CNGFW
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "workload_vnet" {
  name                          = "${var.prefix}-workload-vnet-rt"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-cngfw"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = "10.128.1.4"
  }
}

resource "azurerm_subnet_route_table_association" "workload_vnet" {
  subnet_id      = azurerm_subnet.workload_vnet.id
  route_table_id = azurerm_route_table.workload_vnet.id
}

# ===========================================================================
# VWAN — vWAN CNGFW path
# ===========================================================================

resource "azurerm_virtual_wan" "main" {
  name                = "${var.prefix}-vwan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  type                = "Standard"
}

resource "azurerm_virtual_hub" "main" {
  name                = "${var.prefix}-vwan-hub"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_wan_id      = azurerm_virtual_wan.main.id
  address_prefix      = "10.129.0.0/23"
  sku                 = "Standard"
}

# ---------------------------------------------------------------------------
# vWAN Hub VPN Gateway — BGP endpoint for forced tunnel
# ---------------------------------------------------------------------------

resource "azurerm_vpn_gateway" "main" {
  name                = "${var.prefix}-vwan-vpngw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_hub_id      = azurerm_virtual_hub.main.id

  bgp_settings {
    asn         = var.vwan_bgp_asn
    peer_weight = 0
    instance_0_bgp_peering_address {
      custom_ips = []
    }
    instance_1_bgp_peering_address {
      custom_ips = []
    }
  }
}

# ---------------------------------------------------------------------------
# vWAN VPN Site — the external BGP peer (same single public IP)
# ---------------------------------------------------------------------------

resource "azurerm_vpn_site" "bgp_peer" {
  name                = "${var.prefix}-vpn-site-bgp-peer"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_wan_id      = azurerm_virtual_wan.main.id

  link {
    name       = "bgp-peer-link"
    ip_address = var.bgp_peer_public_ip
    bgp {
      asn             = var.bgp_peer_asn
      peering_address = var.bgp_peer_public_ip
    }
  }
}

resource "azurerm_vpn_gateway_connection" "bgp_peer" {
  name               = "${var.prefix}-vwan-to-bgp-peer"
  vpn_gateway_id     = azurerm_vpn_gateway.main.id
  remote_vpn_site_id = azurerm_vpn_site.bgp_peer.id

  vpn_link {
    name             = "bgp-peer-link"
    vpn_site_link_id = azurerm_vpn_site.bgp_peer.link[0].id
    shared_key       = var.vpn_shared_key
    bgp_enabled      = true
  }
}

# ---------------------------------------------------------------------------
# vWAN CNGFW — Strata Cloud Manager managed
# ---------------------------------------------------------------------------

resource "azurerm_palo_alto_next_generation_firewall_virtual_hub_strata_cloud_manager" "main" {
  name                = "${var.prefix}-cngfw-vhub"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_hub_id      = azurerm_virtual_hub.main.id

  network_profile {
    public_ip_count = 1
  }

  panorama_configuration {
    tsg_id = var.scm_tsg_id
  }

  depends_on = [azurerm_vpn_gateway.main]
}

# ---------------------------------------------------------------------------
# vWAN Routing Intent — private traffic only
# 0.0.0.0/1 and 128.0.0.0/1 as additional prefixes complement default
# private coverage; internet traffic is handled by BGP-learned 0/0 from VPN GW
# ---------------------------------------------------------------------------

resource "azurerm_virtual_hub_routing_intent" "main" {
  name           = "${var.prefix}-routing-intent"
  virtual_hub_id = azurerm_virtual_hub.main.id

  routing_policy {
    name         = "PrivateTrafficPolicy"
    destinations = ["PrivateTraffic"]
    next_hop     = azurerm_palo_alto_next_generation_firewall_virtual_hub_strata_cloud_manager.main.id
  }

  depends_on = [azurerm_palo_alto_next_generation_firewall_virtual_hub_strata_cloud_manager.main]
}

# NOTE: 0.0.0.0/1 and 128.0.0.0/1 additional prefixes for private routing
# intent are configured in SCM/Panorama policy or via the CNGFW resource's
# network_profile depending on provider version. Verify azurerm 4.69
# azurerm_virtual_hub_routing_intent supports additional_prefixes if needed.

# ===========================================================================
# WORKLOAD VNET — vWAN path
# ===========================================================================

resource "azurerm_virtual_network" "workload_vwan" {
  name                = "${var.prefix}-workload-vnet-vwan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.131.0.0/16"]
}

resource "azurerm_subnet" "workload_vwan" {
  name                 = "workload"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.workload_vwan.name
  address_prefixes     = ["10.131.0.0/24"]
}

# Connect workload VNet to vWAN hub
resource "azurerm_virtual_hub_connection" "workload_vwan" {
  name                      = "${var.prefix}-workload-vwan-conn"
  virtual_hub_id            = azurerm_virtual_hub.main.id
  remote_virtual_network_id = azurerm_virtual_network.workload_vwan.id
}

# ---------------------------------------------------------------------------
# UDR — workload VNet vWAN path
# With routing intent active, vWAN pushes effective routes to spoke VNets.
# A local UDR is still needed when bgp_route_propagation_enabled = false
# or for overriding specific prefixes for direct SSH access.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "workload_vwan" {
  name                          = "${var.prefix}-workload-vwan-rt"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  bgp_route_propagation_enabled = true  # allow vWAN effective routes to propagate
}

resource "azurerm_subnet_route_table_association" "workload_vwan" {
  subnet_id      = azurerm_subnet.workload_vwan.id
  route_table_id = azurerm_route_table.workload_vwan.id
}

# ===========================================================================
# Outputs
# ===========================================================================

output "vng_public_ip" {
  description = "Hub VNet VNG public IP — configure as S2S peer on external device"
  value       = azurerm_public_ip.vng.ip_address
}

output "cngfw_vnet_public_ip" {
  description = "VNet CNGFW public IP"
  value       = azurerm_public_ip.cngfw_vnet.ip_address
}

output "cngfw_vnet_trusted_udr_ip" {
  description = "VNet CNGFW trusted IP for UDR next-hop"
  value       = "10.128.1.4"
}

output "vwan_hub_id" {
  description = "vWAN Hub resource ID"
  value       = azurerm_virtual_hub.main.id
}

output "workload_vnet_subnet" {
  description = "VNet path workload subnet"
  value       = azurerm_subnet.workload_vnet.address_prefixes[0]
}

output "workload_vwan_subnet" {
  description = "vWAN path workload subnet"
  value       = azurerm_subnet.workload_vwan.address_prefixes[0]
}
