provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = merge(var.tags, { "eks-cluster" = var.cluster_name })
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  partition       = data.aws_partition.current.partition
  kubeconfig_path = "${path.root}/.kubeconfig-${var.cluster_name}"
  profile_flag    = var.aws_profile == null ? "" : "--profile ${var.aws_profile}"

  eks_token_args = concat(
    ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name, "--region", var.region],
    var.aws_profile == null ? [] : ["--profile", var.aws_profile]
  )
}

provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_token_args
  }
}

provider "helm" {
  # Own repo config/cache: a stale global Helm cache (%TEMP%\helm) otherwise
  # breaks plan with "no cached repo found".
  repository_config_path = "${path.root}/.helm/repositories.yaml"
  repository_cache       = "${path.root}/.helm/cache"

  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_token_args
    }
  }
}
