output "bastion_public_ip" {
  description = "Endpoint da VPN de administração (UDP)"
  value       = "${aws_eip.bastion.public_ip}:${var.vpn_port}"
}

output "bastion_vpn_ip" {
  description = "IP do bastion dentro da VPN — destino do SSH dos admins"
  value       = local.vpn_server_ip
}

output "vpn_peer_addresses" {
  description = "IP de cada admin dentro da VPN (Address do cliente WireGuard)"
  value       = { for p in local.vpn_peers : p.name => "${p.address}/32" }
}

output "aws_vm_private_ip" {
  value = aws_instance.vm.private_ip
}

output "azure_vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "ssh_examples" {
  description = "Com a VPN conectada; troque <usuario> por gabriel ou rafael"
  value = {
    bastion  = "ssh -i <usuario>.key <usuario>@${local.vpn_server_ip}"
    vm_aws   = "ssh -i <usuario>.key -J <usuario>@${local.vpn_server_ip} <usuario>@${aws_instance.vm.private_ip}"
    vm_azure = "ssh -i <usuario>.key -J <usuario>@${local.vpn_server_ip} <usuario>@${azurerm_public_ip.vm.ip_address}"
  }
}

output "onprem_vpn_endpoints" {
  description = "IPs públicos dos túneis para configurar no concentrador on-premises"
  value = var.enable_onprem_vpn ? {
    aws_tunnel1 = aws_vpn_connection.onprem[0].tunnel1_address
    aws_tunnel2 = aws_vpn_connection.onprem[0].tunnel2_address
    azure       = azurerm_public_ip.vpn_gateway[0].ip_address
  } : null
}
