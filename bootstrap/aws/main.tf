# Bootstrap AWS — rodar UMA vez, localmente, com suas credenciais de admin.
# Cria: bucket S3 para o state + provedor OIDC do GitHub + role que o pipeline assume.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform-bootstrap" }
  }
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

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "multicloud-pipeline"
}

variable "create_oidc_provider" {
  description = "false se a conta já tiver o provedor OIDC token.actions.githubusercontent.com"
  type        = bool
  default     = true
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------- State remoto ----------
resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- OIDC GitHub -> AWS ----------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # O GitHub emite o "sub" com IDs imutáveis: repo:OWNER@ID/REPO@ID:<contexto>
  github_subject = "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
}

# Só workflows deste repositório podem assumir a role
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_subject}:*"]
    }
  }
}

resource "aws_iam_role" "github" {
  name               = "github-actions-${var.project}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "ec2" {
  role       = aws_iam_role.github.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

data "aws_iam_policy_document" "extra" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "extra" {
  name   = "terraform-state"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.extra.json
}

# ---------- Valores para cadastrar no GitHub ----------
output "github_variables" {
  description = "Cadastre em Settings > Secrets and variables > Actions > Variables"
  value = {
    AWS_ROLE_ARN    = aws_iam_role.github.arn
    AWS_REGION      = var.region
    TF_STATE_BUCKET = aws_s3_bucket.state.id
  }
}
