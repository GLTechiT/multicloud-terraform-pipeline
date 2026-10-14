locals {
  prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Usuários criados em todas as VMs (nome => chave pública SSH)
  users = {
    gabriel = trimspace(var.ssh_pubkey_gabriel)
    rafael  = trimspace(var.ssh_pubkey_rafael)
  }

  # Na Azure um usuário é obrigatoriamente o "admin" da VM; os demais vêm pelo cloud-init
  azure_admin = "gabriel"

  # ---------- VPN de administração (WireGuard no bastion) ----------
  # Servidor = 1º IP da faixa; peers recebem IPs fixos em ordem alfabética do nome
  vpn_server_ip = cidrhost(var.vpn_cidr, 1)
  vpn_peers = [
    for i, name in sort(keys(var.vpn_peer_public_keys)) : {
      name       = name
      public_key = trimspace(var.vpn_peer_public_keys[name])
      address    = cidrhost(var.vpn_cidr, i + 2)
    }
  ]

  # Parâmetros do cloud-init; o bastion sobrescreve os campos de VPN e NAT
  cloud_init_defaults = {
    users                = local.users
    include_default_user = false
    bastion              = false
    nat_source_cidr      = ""
    wg_address           = ""
    wg_port              = var.vpn_port
    wg_private_key       = ""
    wg_peers             = []
  }
}
