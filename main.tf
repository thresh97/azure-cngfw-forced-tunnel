# =============================================================================
# Azure Cloud NGFW — Forced Tunneling via S2S BGP
#
# Architecture:
#   - Single external public IP peers via BGP and advertises 0.0.0.0/0
#     to both the Hub VNet VNG and the vWAN Hub VPN Gateway (forced tunnel)
#   - VNet CNGFW: deployed into hub VNet; workload VNet peered to hub;
#     UDR on workload subnet steers 0/0 to CNGFW trusted IP (.4)
#   - vWAN CNGFW: deployed into vWAN hub via PAN NVA + CNGFW resource;
#     routing intent configured via portal (not managed by TF)
#   - Both CNGFW deployments managed by Strata Cloud Manager (SCM)
#
# IP Allocation (10.128.0.0/6):
#   Hub VNet            10.128.0.0/16
#     GatewaySubnet     10.128.0.0/27
#     CNGFW Trusted     10.128.1.0/24  (delegated to PAN)
#     CNGFW Untrusted   10.128.2.0/24  (delegated to PAN)
#     CNGFW Mgmt        10.128.3.0/24
#   VNet Workload VNet  10.130.0.0/16
#     Workload Subnet   10.130.0.0/24
#   vWAN Hub            10.129.0.0/23
#   vWAN Workload VNet  10.131.0.0/16
#     Workload Subnet   10.131.0.0/24
# =============================================================================

terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.69"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
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


variable "scm_tenant_name" {
  type        = string
  description = "Strata Cloud Manager tenant name (strata_cloud_manager_tenant_name)"
}

variable "allowed_mgmt_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH to workload VMs (for validation)"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content for workload VM admin access"
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

# NSG for CNGFW subnets
resource "azurerm_network_security_group" "cngfw" {
  name                = "${var.prefix}-cngfw-nsg"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Trusted subnet — delegated to PaloAltoNetworks.Cloudngfw/firewalls
resource "azurerm_subnet" "cngfw_trusted" {
  name                 = "${var.prefix}-cngfw-trusted"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.1.0/24"]

  delegation {
    name = "pan-cloudngfw-delegation"
    service_delegation {
      name    = "PaloAltoNetworks.Cloudngfw/firewalls"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "cngfw_trusted" {
  subnet_id                 = azurerm_subnet.cngfw_trusted.id
  network_security_group_id = azurerm_network_security_group.cngfw.id
}

# Untrusted subnet — delegated to PaloAltoNetworks.Cloudngfw/firewalls
resource "azurerm_subnet" "cngfw_untrusted" {
  name                 = "${var.prefix}-cngfw-untrusted"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.128.2.0/24"]

  delegation {
    name = "pan-cloudngfw-delegation"
    service_delegation {
      name    = "PaloAltoNetworks.Cloudngfw/firewalls"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "cngfw_untrusted" {
  subnet_id                 = azurerm_subnet.cngfw_untrusted.id
  network_security_group_id = azurerm_network_security_group.cngfw.id
}

# Management subnet (out-of-band / SSH validation)
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
  zones               = ["1", "2", "3"]
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "${var.prefix}-vng"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw2AZ"
  bgp_enabled         = true
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
# Local Network Gateway + VPN Connection — Hub VNet → external BGP peer
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

resource "azurerm_virtual_network_gateway_connection" "hub_to_peer" {
  name                = "${var.prefix}-vng-to-bgp-peer"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id
  local_network_gateway_id   = azurerm_local_network_gateway.bgp_peer.id
  shared_key                 = var.vpn_shared_key
  bgp_enabled                = true
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
  name                             = "${var.prefix}-cngfw-vnet"
  resource_group_name              = azurerm_resource_group.main.name
  location                         = azurerm_resource_group.main.location
  strata_cloud_manager_tenant_name = var.scm_tenant_name

  network_profile {
    public_ip_address_ids = [azurerm_public_ip.cngfw_vnet.id]

    vnet_configuration {
      virtual_network_id  = azurerm_virtual_network.hub.id
      trusted_subnet_id   = azurerm_subnet.cngfw_trusted.id
      untrusted_subnet_id = azurerm_subnet.cngfw_untrusted.id
    }
  }
}

# ===========================================================================
# WORKLOAD VNET — VNet CNGFW path
# ===========================================================================

resource "azurerm_virtual_network" "workload_vnet" {
  name                = "${var.prefix}-workload-vnet"
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

resource "azurerm_virtual_network_peering" "workload_to_hub" {
  name                      = "workload-to-hub"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.workload_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  use_remote_gateways       = true
  allow_forwarded_traffic   = true

  depends_on = [azurerm_virtual_network_gateway.hub]
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
# UDR — route workload traffic through VNet CNGFW trusted IP (.4)
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

  dynamic "route" {
    for_each = var.allowed_mgmt_cidrs
    content {
      name           = "mgmt-backdoor-${replace(route.value, "/", "-")}"
      address_prefix = route.value
      next_hop_type  = "Internet"
    }
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

  # Custom ASN requires Support enablement — must use 65515
  bgp_settings {
    asn         = 65515
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
# vWAN VPN Site + Connection — external BGP peer (same single public IP)
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

  # When routing intent owns the hub, VPN connections must not carry their own
  # routing configuration — Azure auto-populates it. The provider sends routing
  # defaults even without an explicit block, which triggers
  # ConnectionRoutingConfigConflictsWithRoutingIntent. Suppress that drift.
  lifecycle {
    ignore_changes = [routing]
  }
}

# ---------------------------------------------------------------------------
# PAN NVA — required prerequisite for vWAN CNGFW
# ---------------------------------------------------------------------------

resource "azurerm_palo_alto_virtual_network_appliance" "main" {
  name           = "${var.prefix}-pan-nva"
  virtual_hub_id = azurerm_virtual_hub.main.id
}

# ---------------------------------------------------------------------------
# vWAN CNGFW public IP
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "cngfw_vwan" {
  name                = "${var.prefix}-cngfw-vwan-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ---------------------------------------------------------------------------
# vWAN CNGFW — Strata Cloud Manager managed
# ---------------------------------------------------------------------------

resource "azurerm_palo_alto_next_generation_firewall_virtual_hub_strata_cloud_manager" "main" {
  name                             = "${var.prefix}-cngfw-vhub"
  resource_group_name              = azurerm_resource_group.main.name
  location                         = azurerm_resource_group.main.location
  strata_cloud_manager_tenant_name = var.scm_tenant_name

  network_profile {
    public_ip_address_ids        = [azurerm_public_ip.cngfw_vwan.id]
    virtual_hub_id               = azurerm_virtual_hub.main.id
    network_virtual_appliance_id = azurerm_palo_alto_virtual_network_appliance.main.id
  }

  depends_on = [azurerm_vpn_gateway.main]
}


# ===========================================================================
# WORKLOAD VNET — vWAN path
# ===========================================================================

resource "azurerm_virtual_network" "workload_vwan" {
  name                = "${var.prefix}-workload-vwan"
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

resource "azurerm_virtual_hub_connection" "workload_vwan" {
  name                      = "${var.prefix}-workload-vwan-conn"
  virtual_hub_id            = azurerm_virtual_hub.main.id
  remote_virtual_network_id = azurerm_virtual_network.workload_vwan.id
}

# Route table for vWAN workload — BGP propagation enabled to receive
# effective routes pushed by routing intent from the vWAN hub
resource "azurerm_route_table" "workload_vwan" {
  name                          = "${var.prefix}-workload-vwan-rt"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  bgp_route_propagation_enabled = true

  dynamic "route" {
    for_each = var.allowed_mgmt_cidrs
    content {
      name           = "mgmt-backdoor-${replace(route.value, "/", "-")}"
      address_prefix = route.value
      next_hop_type  = "Internet"
    }
  }
}

resource "azurerm_subnet_route_table_association" "workload_vwan" {
  subnet_id      = azurerm_subnet.workload_vwan.id
  route_table_id = azurerm_route_table.workload_vwan.id
}

# ===========================================================================
# WORKLOAD VMs
# ===========================================================================

resource "azurerm_network_security_group" "workload" {
  name                = "${var.prefix}-workload-nsg"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }
}

# ---------------------------------------------------------------------------
# VNet CNGFW path — workload VM
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "workload_vnet" {
  name                = "${var.prefix}-workload-vnet-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "workload_vnet" {
  name                = "${var.prefix}-workload-vnet-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.workload_vnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.130.0.4"
    public_ip_address_id          = azurerm_public_ip.workload_vnet.id
  }
}

resource "azurerm_network_interface_security_group_association" "workload_vnet" {
  network_interface_id      = azurerm_network_interface.workload_vnet.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

resource "azurerm_linux_virtual_machine" "workload_vnet" {
  name                  = "${var.prefix}-workload-vnet-vm"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = "Standard_B1s"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.workload_vnet.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

# ---------------------------------------------------------------------------
# vWAN CNGFW path — workload VM
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "workload_vwan" {
  name                = "${var.prefix}-workload-vwan-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "workload_vwan" {
  name                = "${var.prefix}-workload-vwan-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.workload_vwan.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.131.0.4"
    public_ip_address_id          = azurerm_public_ip.workload_vwan.id
  }
}

resource "azurerm_network_interface_security_group_association" "workload_vwan" {
  network_interface_id      = azurerm_network_interface.workload_vwan.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

resource "azurerm_linux_virtual_machine" "workload_vwan" {
  name                  = "${var.prefix}-workload-vwan-vm"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = "Standard_B1s"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.workload_vwan.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

# ===========================================================================
# Outputs
# ===========================================================================

# ---------------------------------------------------------------------------
# VNet VNG — S2S VPN configuration
# ---------------------------------------------------------------------------

output "vnet_vng_public_ip" {
  description = "VNet VNG public IP (IKE endpoint)"
  value       = azurerm_public_ip.vng.ip_address
}

output "vnet_vng_bgp_asn" {
  description = "VNet VNG BGP ASN"
  value       = azurerm_virtual_network_gateway.hub.bgp_settings[0].asn
}

output "vnet_vng_bgp_peering_address" {
  description = "VNet VNG BGP peering address (neighbor IP to configure on external peer)"
  value       = tolist(azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses)[0]
}

output "vnet_vng_shared_key" {
  description = "VNet VNG S2S shared key"
  value       = var.vpn_shared_key
  sensitive   = true
}

# ---------------------------------------------------------------------------
# vWAN Hub VPN Gateway — S2S VPN configuration (active-active, two instances)
# ---------------------------------------------------------------------------

output "vwan_vpngw_bgp_asn" {
  description = "vWAN Hub VPN GW BGP ASN (fixed 65515)"
  value       = azurerm_vpn_gateway.main.bgp_settings[0].asn
}

output "vwan_vpngw_instance0_public_ips" {
  description = "vWAN VPN GW instance 0 public IPs (IKE endpoints)"
  value       = azurerm_vpn_gateway.main.bgp_settings[0].instance_0_bgp_peering_address[0].tunnel_ips
}

output "vwan_vpngw_instance0_bgp_ips" {
  description = "vWAN VPN GW instance 0 BGP peering IPs"
  value       = azurerm_vpn_gateway.main.bgp_settings[0].instance_0_bgp_peering_address[0].default_ips
}

output "vwan_vpngw_instance1_public_ips" {
  description = "vWAN VPN GW instance 1 public IPs (IKE endpoints)"
  value       = azurerm_vpn_gateway.main.bgp_settings[0].instance_1_bgp_peering_address[0].tunnel_ips
}

output "vwan_vpngw_instance1_bgp_ips" {
  description = "vWAN VPN GW instance 1 BGP peering IPs"
  value       = azurerm_vpn_gateway.main.bgp_settings[0].instance_1_bgp_peering_address[0].default_ips
}

output "vwan_vpngw_shared_key" {
  description = "vWAN Hub VPN GW S2S shared key"
  value       = var.vpn_shared_key
  sensitive   = true
}

# ---------------------------------------------------------------------------
# CNGFW public IPs
# ---------------------------------------------------------------------------

output "cngfw_vnet_public_ip" {
  description = "VNet CNGFW public IP"
  value       = azurerm_public_ip.cngfw_vnet.ip_address
}

output "cngfw_vwan_public_ip" {
  description = "vWAN CNGFW public IP"
  value       = azurerm_public_ip.cngfw_vwan.ip_address
}

# ---------------------------------------------------------------------------
# Workload VMs
# ---------------------------------------------------------------------------

output "workload_vnet_vm_public_ip" {
  description = "VNet CNGFW path workload VM public IP (azureuser, 10.130.0.4)"
  value       = azurerm_public_ip.workload_vnet.ip_address
}

output "workload_vwan_vm_public_ip" {
  description = "vWAN CNGFW path workload VM public IP (azureuser, 10.131.0.4)"
  value       = azurerm_public_ip.workload_vwan.ip_address
}
