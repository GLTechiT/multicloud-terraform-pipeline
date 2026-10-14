resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}"
  location = var.azure_location
  tags     = local.tags
}

# ---------- Rede ----------
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.prefix}"
  address_space       = [var.azure_vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.azure_vnet_cidr, 8, 1)]
}

# IP público necessário para o bastion alcançar a VM sem VPN; o NSG só aceita o bastion
resource "azurerm_public_ip" "vm" {
  name                = "pip-vm-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# ---------- Firewall ----------
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "allow-ssh-from-bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "${aws_eip.bastion.public_ip}/32"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-icmp-from-bastion"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "${aws_eip.bastion.public_ip}/32"
    destination_address_prefix = "*"
  }
  # Qualquer outra entrada vinda da internet cai na regra padrão DenyAllInBound

  # Saída para o on-premises: só a porta do banco; o resto da rede on-prem é negado
  security_rule {
    name                       = "allow-onprem-db"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.onprem_db_port)
    source_address_prefix      = "*"
    destination_address_prefix = var.onprem_cidr
  }

  security_rule {
    name                       = "deny-onprem-other"
    priority                   = 210
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = var.onprem_cidr
  }
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-vm-${local.prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ---------- VM ----------
resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-azure-${local.prefix}"
  location                        = azurerm_resource_group.main.location
  resource_group_name             = azurerm_resource_group.main.name
  size                            = var.azure_vm_size
  admin_username                  = local.azure_admin
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  tags                            = local.tags

  admin_ssh_key {
    username   = local.azure_admin
    public_key = local.users[local.azure_admin]
  }

  # "default" = o admin acima; o cloud-init cria os demais usuários
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", merge(local.cloud_init_defaults, {
    users                = { for name, key in local.users : name => key if name != local.azure_admin }
    include_default_user = true
  })))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
