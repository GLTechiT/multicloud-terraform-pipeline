# Bootstrap Azure — rodar UMA vez, localmente, logado com `az login`.
# Cria a identidade (App Registration) que o GitHub Actions usa via OIDC — sem client secret.
# O state do projeto fica só no S3 (bootstrap AWS), então aqui não há storage account.

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "github_repo" {
  description = "Repositório no formato owner/repo"
  type        = string
}

# gh api repos/OWNER/REPO --jq '.owner.id, .id'
variable "github_owner_id" {
  description = "ID numérico do dono do repositório"
  type        = string
}

variable "github_repo_id" {
  description = "ID numérico do repositório"
  type        = string
}

variable "subscription_id" {
  type = string
}

variable "project" {
  type    = string
  default = "multicloud-pipeline"
}

variable "github_environments" {
  description = "Environments do GitHub que podem fazer deploy (case-sensitive)"
  type        = list(string)
  default     = ["QA", "DEV", "PRD"]
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "azuread_application" "github" {
  display_name = "github-actions-${var.project}"
}

resource "azuread_service_principal" "github" {
  client_id = azuread_application.github.client_id
}

# O "subject" do token precisa bater exatamente — um por contexto do workflow.
# O GitHub emite o "sub" com IDs imutáveis: repo:OWNER@ID/REPO@ID:<contexto>
locals {
  github_subject = "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"

  federated_subjects = merge(
    {
      pull-request = "repo:${local.github_subject}:pull_request"
      main         = "repo:${local.github_subject}:ref:refs/heads/main"
    },
    { for env in var.github_environments : "env-${lower(env)}" => "repo:${local.github_subject}:environment:${env}" }
  )
}

resource "azuread_application_federated_identity_credential" "github" {
  for_each       = local.federated_subjects
  application_id = azuread_application.github.id
  display_name   = "github-${each.key}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = each.value
}

resource "azurerm_role_assignment" "contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.github.object_id
}

# ---------- Valores para cadastrar no GitHub ----------
output "github_variables" {
  description = "Cadastre em Settings > Secrets and variables > Actions > Variables"
  value = {
    AZURE_CLIENT_ID       = azuread_application.github.client_id
    AZURE_TENANT_ID       = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID = var.subscription_id
  }
}
