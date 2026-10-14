# ---------- Por ambiente (env/<ambiente>.tfvars) ----------
variable "environment" {
  type = string
  validation {
    condition     = contains(["qa", "dev", "prd"], var.environment)
    error_message = "environment deve ser qa, dev ou prd."
  }
}

variable "aws_vpc_cidr" {
  type = string
}

variable "azure_vnet_cidr" {
  type = string
}

variable "vpn_cidr" {
  description = "Rede da VPN de administração (WireGuard). Única por ambiente para permitir túneis simultâneos"
  type        = string
}

variable "enable_onprem_vpn" {
  description = "Cria a VPN site-to-site IPsec com o on-premises nas duas nuvens (VGW na AWS, VPN Gateway na Azure)"
  type        = bool
  default     = false # VPN Gateway da Azure: ~40 min para provisionar e custo por hora — habilitar por ambiente
}

# ---------- Com valor padrão ----------
variable "project" {
  type    = string
  default = "multicloud-pipeline"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "azure_location" {
  type    = string
  default = "eastus2"
}

variable "aws_instance_type" {
  type    = string
  default = "t3.micro" # free tier
}

variable "azure_vm_size" {
  type    = string
  default = "Standard_B1s" # free tier
}

variable "vpn_port" {
  description = "Porta UDP do WireGuard no bastion"
  type        = number
  default     = 51820
}

# ---------- On-premises ----------
variable "onprem_gateway_ip" {
  description = "IP público do concentrador VPN on-premises"
  type        = string
  default     = "203.0.113.10"
}

variable "onprem_cidr" {
  description = "Rede on-premises onde está o banco de dados"
  type        = string
  default     = "192.168.100.0/24"
}

variable "onprem_db_port" {
  description = "Porta do banco de dados on-premises (PostgreSQL)"
  type        = number
  default     = 5432
}

variable "onprem_bgp_asn" {
  description = "ASN do concentrador on-premises (exigido pelo customer gateway da AWS, mesmo com rotas estáticas)"
  type        = number
  default     = 65000
}

# ---------- Vindas do GitHub (TF_VAR_*) ----------
variable "vpn_allowed_cidrs" {
  description = "Origens autorizadas a abrir o túnel WireGuard, ex.: [\"200.100.50.25/32\"]"
  type        = list(string)
  sensitive   = true # não aparece nos logs públicos do Actions

  validation {
    condition     = length(var.vpn_allowed_cidrs) > 0 && alltrue([for c in var.vpn_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "vpn_allowed_cidrs precisa ter ao menos um CIDR válido."
  }
}

variable "vpn_peer_public_keys" {
  description = "Chaves públicas WireGuard dos admins (nome => chave). Os IPs na VPN são atribuídos em ordem alfabética"
  type        = map(string)

  validation {
    condition     = length(var.vpn_peer_public_keys) > 0 && alltrue([for k in values(var.vpn_peer_public_keys) : length(trimspace(k)) == 44])
    error_message = "Cada chave pública WireGuard tem 44 caracteres (base64)."
  }
}

variable "wireguard_server_private_key" {
  description = "Chave privada WireGuard do bastion (wg genkey)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.wireguard_server_private_key)) == 44
    error_message = "A chave privada WireGuard tem 44 caracteres (base64)."
  }
}

variable "onprem_vpn_psk" {
  description = "Pre-shared key do IPsec site-to-site (obrigatória quando enable_onprem_vpn = true)"
  type        = string
  sensitive   = true
  default     = ""

  validation {
    # Regras da AWS: 8–64 caracteres, letras, números, ponto e underline; não pode começar com 0
    condition     = !var.enable_onprem_vpn || can(regex("^[A-Za-z1-9_.][A-Za-z0-9_.]{7,63}$", var.onprem_vpn_psk))
    error_message = "Com enable_onprem_vpn = true, informe uma PSK de 8 a 64 caracteres [A-Za-z0-9_.] que não comece com 0."
  }
}

variable "ssh_pubkey_gabriel" {
  description = "Conteúdo de gabriel.key.pub"
  type        = string
}

variable "ssh_pubkey_rafael" {
  description = "Conteúdo de rafael.key.pub"
  type        = string
}
