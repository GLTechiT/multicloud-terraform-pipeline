# Pipeline Multi-Cloud: AWS + Azure com Terraform e GitHub Actions

Infraestrutura **multi-cloud** com **bastion host atrás de VPN** e **conectividade híbrida
com o on-premises**, provisionada por **Terraform** e promovida entre os ambientes
**QA → DEV → PRD** por um pipeline no **GitHub Actions**, com login nas nuvens via **OIDC**
(sem nenhuma senha ou access key guardada no GitHub).

> 📄 **Leia a jornada completa** — arquitetura, decisões de projeto, problemas reais
> encontrados e como foram resolvidos:
> 🇧🇷 [Português](docs/jornada.md) · 🇺🇸 [English](docs/journey.md) · 🇪🇸 [Español](docs/recorrido.md)
>
> **Status:** projeto de estudo concluído em out/2026 — todos os recursos foram destruídos
> ao final do dia. O código permanece para reprodução.

## Arquitetura (por ambiente)

```
   admins (cliente WireGuard)
          │ VPN WireGuard (UDP 51820) ─ SSH só por chave, dentro do túnel
          ▼
 ┌──────────────── AWS ────────────────────┐            ┌─────────────── Azure ───────────────┐
 │  subnet pública                         │            │                                     │
 │   BASTION Ubuntu 24.04 (Elastic IP)  ◀──┼─ SSH/ICMP ─┼──  VM Ubuntu 24.04                   │
 │   VPN WireGuard · NAT · SSH hardening ──┼── SSH ────▶│    NSG: entrada só do bastion       │
 │        │ SSH                            │            │         │                           │
 │  subnet privada                         │            │   VPN Gateway (VpnGw1AZ)            │
 │   VM Ubuntu 24.04 (sem IP público)      │            └─────────┼───────────────────────────┘
 │        │                                │                      │ IPsec IKEv2 · AES-256
 │   Virtual Private Gateway ──────────────┼── IPsec ──┐          │
 └─────────────────────────────────────────┘ 2 túneis  ▼          ▼
                                            ┌──────── On-premises ────────┐
                                            │  concentrador VPN            │
                                            │  PostgreSQL 192.168.100.0/24 │
                                            └──────────────────────────────┘
```

| Componente | Detalhe |
|---|---|
| **VPN de administração** | WireGuard no bastion. É o único caminho de entrada dos admins: a porta 22 não é exposta à internet; o SSH acontece dentro do túnel, para o IP do bastion na rede da VPN |
| **Bastion (AWS)** | Login só com **usuário + chave** (`PasswordAuthentication no`, `PermitRootLogin no`). Também faz NAT (iptables) para a subnet privada — substitui o NAT Gateway pago |
| **VM AWS** | Subnet privada, sem IP público, aceita SSH apenas do security group do bastion |
| **VM Azure** | O NSG aceita entrada (SSH/ICMP) apenas do Elastic IP do bastion. O bastion também aceita SSH/ICMP vindo dela |
| **On-premises** | VPN site-to-site **IPsec** (IKEv2, AES-256, SHA-256, DH 14) a partir das duas nuvens: Virtual Private Gateway na AWS (2 túneis) e VPN Gateway na Azure. As VMs acessam o banco PostgreSQL on-prem sem tráfego em claro na internet; na Azure, o NSG libera **só a porta do banco** para a rede on-prem |
| **Usuários** | `gabriel` e `rafael` em todas as máquinas, só com chave SSH e `sudo` |

### Decisões de projeto

- **Um único módulo Terraform com os dois providers.** O NSG da Azure precisa do IP do
  bastion (AWS) e o security group da AWS precisa do IP da VM Azure. Em states separados
  isso seria uma dependência circular; em um único grafo o Terraform resolve a ordem
  (reserva os IPs → cria as regras → cria as VMs).
- **Um state por ambiente** no S3 (`qa/`, `dev/`, `prd/terraform.tfstate`), com lock nativo
  do S3 (`use_lockfile`). Destruir QA nunca encosta em PRD.
- **Mesmo código, valores diferentes:** o que muda por ambiente fica em `terraform/env/*.tfvars`
  (faixas de rede, rede da VPN e a *feature flag* da VPN site-to-site).
- **WireGuard em vez de AWS Client VPN** para administração: sem custo por hora e sem PKI para
  manter; os IPs dos admins na VPN são fixos e derivados da lista de chaves.
- **VPN site-to-site gerenciada nas duas nuvens**, ligada por `enable_onprem_vpn`: o VPN
  Gateway da Azure leva ~40 min para provisionar e tem custo por hora, então é habilitado
  por ambiente conforme a necessidade.
- **Nada sensível no repositório público:** chave privada do WireGuard e PSK do IPsec em
  GitHub Secrets; origens autorizadas na VPN são variáveis `sensitive` (não aparecem nos logs);
  chaves privadas SSH nunca saem da máquina de cada usuário.

## Pipeline

```
Pull Request ──▶ plan QA │ plan DEV │ plan PRD           (revisão, nada é alterado)

merge na main ──▶ QA   plan → apply (automático)
                   ▼
                  DEV  plan → ⏸ aprovação (RafaelWagnerLara) → apply
                   ▼
                  PRD  plan → ⏸ aprovação (GLTechiT) → apply
```

| Arquivo | Função |
|---|---|
| `.github/workflows/terraform.yml` | Orquestra: plan nos PRs, promoção QA → DEV → PRD na `main` |
| `.github/workflows/_terraform.yml` | Workflow reutilizável: plan / apply / destroy de um ambiente |
| `.github/workflows/destroy.yml` | Destruição manual (um ambiente ou todos) |
| `terraform/aws.tf`, `azure.tf` | Rede, firewall, bastion e VMs |
| `terraform/onprem.tf` | VPN site-to-site IPsec com o on-premises (AWS + Azure) |
| `terraform/cloud-init.yaml.tftpl` | Usuários, WireGuard, hardening do SSH e NAT |
| `scripts/tf-init.sh` | `terraform init` apontando para o state do ambiente |
| `bootstrap/aws` | Bucket S3 do state + provedor OIDC + IAM Role (rodado uma vez, localmente) |
| `bootstrap/azure` | App Registration com federação OIDC + permissão na assinatura (uma vez, localmente) |

O `apply` usa o **plan salvo** no job anterior — aplica exatamente o que foi revisado; se o
state mudou nesse meio tempo, o Terraform recusa.

---

## Como reproduzir

### 1. Pré-requisitos
- Terraform ≥ 1.10, AWS CLI, Azure CLI, GitHub CLI e WireGuard (`wg`) — logados nas três nuvens/plataformas.
- Permissão de admin na conta AWS; Owner na assinatura Azure + permissão para criar App Registrations.

### 2. Chaves SSH (cada usuário gera a sua)
```bash
ssh-keygen -t ed25519 -N "" -C "gabriel" -f ~/.ssh/gabriel.key
```
Gera `gabriel.key` (privada — não compartilhe) e `gabriel.key.pub` (pública — vai para o GitHub).

### 3. Chaves WireGuard
```bash
# Servidor (bastion): a privada vai para um GitHub Secret; a pública vai para os clientes
wg genkey | tee bastion.wg.key | wg pubkey > bastion.wg.pub

# Cada admin gera o seu par (ou pelo app WireGuard no Windows/macOS)
wg genkey | tee gabriel.wg.key | wg pubkey > gabriel.wg.pub
```

### 4. Bootstrap
O GitHub emite o `sub` do token OIDC com IDs imutáveis
(`repo:OWNER@ID/REPO@ID:<contexto>`), então o bootstrap precisa dos IDs numéricos:
```bash
REPO=OWNER/multicloud-terraform-pipeline
read OWNER_ID REPO_ID < <(gh api repos/$REPO --jq '"\(.owner.id) \(.id)"')
VARS="-var=github_repo=$REPO -var=github_owner_id=$OWNER_ID -var=github_repo_id=$REPO_ID"

cd bootstrap/aws
terraform init
terraform apply $VARS

cd ../azure
terraform init
terraform apply $VARS -var="subscription_id=$(az account show --query id -o tsv)"
```
> Se a conta AWS já tiver o provedor OIDC do GitHub, use `-var="create_oidc_provider=false"`.
> Para confirmar o formato que o GitHub enviou, o CloudTrail registra o `sub` mesmo nas
> tentativas recusadas (`AssumeRoleWithWebIdentity` → `userName`).

### 5. GitHub
**Settings → Environments:** criar `QA`, `DEV` e `PRD` (exatamente assim — a federação da
Azure diferencia maiúsculas). Em DEV e PRD, marcar *Required reviewers*. Em todos, limitar
*Deployment branches* à `main`.

**Settings → Secrets and variables → Actions:**

| Tipo | Nome | Valor |
|---|---|---|
| Variable | `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET` | outputs do bootstrap AWS |
| Variable | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | outputs do bootstrap Azure |
| Variable | `SSH_PUBKEY_GABRIEL`, `SSH_PUBKEY_RAFAEL` | conteúdo dos arquivos `.key.pub` |
| Variable | `VPN_PEER_PUBLIC_KEYS` | `{"gabriel":"<gabriel.wg.pub>","rafael":"<rafael.wg.pub>"}` |
| Variable | `VPN_ALLOWED_CIDRS` | origens autorizadas a abrir o túnel, ex.: `["IP1/32","IP2/32"]` |
| **Secret** | `WG_SERVER_PRIVATE_KEY` | conteúdo de `bastion.wg.key` |
| **Secret** | `ONPREM_VPN_PSK` | PSK do IPsec (só quando `enable_onprem_vpn = true`) |

### 6. Cliente VPN e acesso
Os outputs do `apply` informam o endpoint da VPN e o IP de cada admin na rede da VPN.
Configuração do cliente (ex.: `gabriel-qa.wg.conf`):
```ini
[Interface]
PrivateKey = <conteúdo de gabriel.wg.key>
Address    = 10.251.0.2/32          # output vpn_peer_addresses

[Peer]
PublicKey           = <conteúdo de bastion.wg.pub>
Endpoint            = <output bastion_public_ip>   # IP:51820
AllowedIPs          = 10.251.0.1/32 # só o bastion passa pelo túnel
PersistentKeepalive = 25
```
Com o túnel ativo:
```bash
ssh -i ~/.ssh/gabriel.key gabriel@10.251.0.1                            # bastion
ssh -i ~/.ssh/gabriel.key -J gabriel@10.251.0.1 gabriel@IP_VM_AWS        # VM AWS
ssh -i ~/.ssh/gabriel.key -J gabriel@10.251.0.1 gabriel@IP_VM_AZURE      # VM Azure
```
Com `-J` (ProxyJump) o SSH passa pelo bastion, mas a chave privada continua só na sua máquina.

### 7. Conectividade com o on-premises
1. Em `terraform/env/<ambiente>.tfvars`: `enable_onprem_vpn = true` (e, se necessário,
   `onprem_gateway_ip`, `onprem_cidr`, `onprem_db_port`).
2. Secret `ONPREM_VPN_PSK` no GitHub.
3. Após o apply, configurar o concentrador on-premises com os endereços do output
   `onprem_vpn_endpoints` (2 túneis AWS + 1 Azure) e a mesma PSK/política
   (IKEv2, AES-256, SHA-256, DH 14, PFS 2048).
4. Status dos túneis:
   ```bash
   aws ec2 describe-vpn-connections --query 'VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status]' --output table
   az network vpn-connection show -g rg-multicloud-pipeline-<ambiente> -n cn-onprem-multicloud-pipeline-<ambiente> --query connectionStatus
   ```

### 8. Destruir
**Actions → destroy → Run workflow** (`ALL` ou um ambiente, digitando `destroy`).
Depois, `terraform destroy` em `bootstrap/azure` e `bootstrap/aws` (o bucket do state é
versionado: remova as versões antes).

## Limitações conhecidas (escopo de estudo)
- Permissões amplas para o pipeline (`AmazonEC2FullAccess`; `Contributor` na assinatura).
- Os três ambientes compartilham a mesma conta AWS e assinatura Azure.
- O tráfego administrativo bastion ↔ VM Azure usa a internet (SSH com chave + allowlist no
  NSG); o tráfego de dados com o on-premises usa IPsec.
- Chave privada do WireGuard entregue via `user_data`; em produção, buscar do Secrets Manager
  com instance profile.
- A regra de NAT do bastion não persiste após reboot (recriada apenas no primeiro boot).
