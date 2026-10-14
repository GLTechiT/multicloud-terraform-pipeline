data "aws_availability_zones" "available" {
  state = "available"
}

# Ubuntu 24.04 (Noble) oficial da Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- Rede ----------
resource "aws_vpc" "main" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-${local.prefix}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "igw-${local.prefix}" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.aws_vpc_cidr, 8, 1)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "snet-public-${local.prefix}" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.aws_vpc_cidr, 8, 2)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "snet-private-${local.prefix}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "rt-public-${local.prefix}" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Saída para a internet da subnet privada passa pelo bastion (NAT)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.bastion.primary_network_interface_id
  }

  tags = { Name = "rt-private-${local.prefix}" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# IP fixo do bastion — reservado antes da VM para a Azure já poder liberá-lo no NSG
resource "aws_eip" "bastion" {
  domain = "vpc"
  tags   = { Name = "eip-bastion-${local.prefix}" }
}

# ---------- Firewall do bastion ----------
resource "aws_security_group" "bastion" {
  name        = "${local.prefix}-bastion" # a AWS não aceita nomes começando com "sg-"
  description = "Bastion: VPN WireGuard dos admins, trafego da VM Azure e NAT da subnet privada"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "sg-bastion-${local.prefix}" }
}

# Admins entram SOMENTE pela VPN: a porta 22 não é exposta para eles.
# O SSH roda dentro do túnel, para o IP do bastion na rede da VPN.
resource "aws_vpc_security_group_ingress_rule" "bastion_wireguard" {
  count             = nonsensitive(length(var.vpn_allowed_cidrs))
  security_group_id = aws_security_group.bastion.id
  description       = "WireGuard (VPN de administracao)"
  cidr_ipv4         = var.vpn_allowed_cidrs[count.index]
  from_port         = var.vpn_port
  to_port           = var.vpn_port
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh_azure" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH vindo da VM Azure"
  cidr_ipv4         = "${azurerm_public_ip.vm.ip_address}/32"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "bastion_icmp_azure" {
  security_group_id = aws_security_group.bastion.id
  description       = "Ping vindo da VM Azure"
  cidr_ipv4         = "${azurerm_public_ip.vm.ip_address}/32"
  from_port         = -1
  to_port           = -1
  ip_protocol       = "icmp"
}

resource "aws_vpc_security_group_ingress_rule" "bastion_nat" {
  security_group_id = aws_security_group.bastion.id
  description       = "Trafego da subnet privada para o NAT"
  cidr_ipv4         = aws_subnet.private.cidr_block
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- Firewall da VM ----------
resource "aws_security_group" "vm" {
  name        = "${local.prefix}-vm"
  description = "VM privada: aceita apenas o bastion"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "sg-vm-${local.prefix}" }
}

resource "aws_vpc_security_group_ingress_rule" "vm_ssh_bastion" {
  security_group_id            = aws_security_group.vm.id
  description                  = "SSH do bastion"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "vm_icmp_bastion" {
  security_group_id            = aws_security_group.vm.id
  description                  = "Ping do bastion"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = -1
  to_port                      = -1
  ip_protocol                  = "icmp"
}

resource "aws_vpc_security_group_egress_rule" "vm_all" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- VMs ----------
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  source_dest_check      = false # necessário para atuar como NAT

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", merge(local.cloud_init_defaults, {
    bastion         = true
    nat_source_cidr = aws_subnet.private.cidr_block
    wg_address      = "${local.vpn_server_ip}/${split("/", var.vpn_cidr)[1]}"
    wg_private_key  = var.wireguard_server_private_key
    wg_peers        = local.vpn_peers
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Sem isso, cada nova AMI publicada recriaria a VM no próximo apply
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "vm-bastion-${local.prefix}" }
}

resource "aws_eip_association" "bastion" {
  allocation_id = aws_eip.bastion.id
  instance_id   = aws_instance.bastion.id
}

resource "aws_instance" "vm" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.vm.id]

  user_data                   = templatefile("${path.module}/cloud-init.yaml.tftpl", local.cloud_init_defaults)
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_route_table_association.private]

  tags = { Name = "vm-aws-${local.prefix}" }
}
