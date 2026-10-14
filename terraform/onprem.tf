# VPN site-to-site IPsec com o datacenter on-premises, nas duas nuvens.
# As VMs alcançam o banco de dados on-prem (var.onprem_cidr) por túneis criptografados;
# o tráfego nunca passa em claro pela internet.
#
#   AWS:   Virtual Private Gateway  ──IPsec (2 túneis)──┐
#                                                       ├── concentrador on-prem ── banco de dados
#   Azure: VPN Gateway (route-based) ──IPsec──────────┘

locals {
  onprem = var.enable_onprem_vpn ? 1 : 0
}

# ---------- AWS ----------
resource "aws_vpn_gateway" "onprem" {
  count  = local.onprem
  vpc_id = aws_vpc.main.id
  tags   = { Name = "vgw-${local.prefix}" }
}

resource "aws_customer_gateway" "onprem" {
  count      = local.onprem
  bgp_asn    = var.onprem_bgp_asn
  ip_address = var.onprem_gateway_ip
  type       = "ipsec.1"
  tags       = { Name = "cgw-onprem-${local.prefix}" }
}

resource "aws_vpn_connection" "onprem" {
  count               = local.onprem
  vpn_gateway_id      = aws_vpn_gateway.onprem[0].id
  customer_gateway_id = aws_customer_gateway.onprem[0].id
  type                = "ipsec.1"
  static_routes_only  = true

  # IKEv2 + AES-256 / SHA-256 / DH 14 nos dois túneis
  tunnel1_preshared_key                = var.onprem_vpn_psk
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]

  tunnel2_preshared_key                = var.onprem_vpn_psk
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = { Name = "vpn-onprem-${local.prefix}" }
}

resource "aws_vpn_connection_route" "onprem" {
  count                  = local.onprem
  vpn_connection_id      = aws_vpn_connection.onprem[0].id
  destination_cidr_block = var.onprem_cidr
}

# A rota para o on-prem é mais específica que o 0.0.0.0/0 (NAT no bastion) e vence
resource "aws_vpn_gateway_route_propagation" "private" {
  count          = local.onprem
  vpn_gateway_id = aws_vpn_gateway.onprem[0].id
  route_table_id = aws_route_table.private.id
}

# ---------- Azure ----------
resource "azurerm_subnet" "gateway" {
  count                = local.onprem
  name                 = "GatewaySubnet" # nome exigido pela Azure
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.azure_vnet_cidr, 11, 2040)] # /27 no fim da VNet
}

resource "azurerm_public_ip" "vpn_gateway" {
  count               = local.onprem
  name                = "pip-vgw-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_virtual_network_gateway" "onprem" {
  count               = local.onprem
  name                = "vgw-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1AZ"
  generation          = "Generation1"
  active_active       = false
  bgp_enabled         = false
  tags                = local.tags

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn_gateway[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway[0].id
  }
}

resource "azurerm_local_network_gateway" "onprem" {
  count               = local.onprem
  name                = "lgw-onprem-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  gateway_address     = var.onprem_gateway_ip
  address_space       = [var.onprem_cidr]
  tags                = local.tags
}

resource "azurerm_virtual_network_gateway_connection" "onprem" {
  count                      = local.onprem
  name                       = "cn-onprem-${local.prefix}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem[0].id
  shared_key                 = var.onprem_vpn_psk
  tags                       = local.tags

  ipsec_policy {
    ike_encryption   = "AES256"
    ike_integrity    = "SHA256"
    dh_group         = "DHGroup14"
    ipsec_encryption = "AES256"
    ipsec_integrity  = "SHA256"
    pfs_group        = "PFS2048"
    sa_lifetime      = 3600
  }
}
