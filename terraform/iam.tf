# One IAM role per controller, bound to its service account with EKS Pod
# Identity. Associations exist BEFORE the Helm releases, so pods start with
# credentials. Policies are the same JSON files the script/console paths use.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  controllers = {
    lbc = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      policy_file     = "aws-load-balancer-controller.json"
    }
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
      policy_file     = "external-dns.json"
    }
  }
}

resource "aws_iam_role" "controller" {
  for_each           = local.controllers
  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_policy" "controller" {
  for_each = local.controllers
  name     = "${var.cluster_name}-${each.key}"
  policy   = file("${path.module}/../policies/${each.value.policy_file}")
}

resource "aws_iam_role_policy_attachment" "controller" {
  for_each   = local.controllers
  role       = aws_iam_role.controller[each.key].name
  policy_arn = aws_iam_policy.controller[each.key].arn
}

resource "aws_eks_pod_identity_association" "controller" {
  for_each        = local.controllers
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.controller[each.key].arn
  depends_on      = [aws_iam_role_policy_attachment.controller]
}

# EBS CSI driver - the association is declared on the add-on (eks.tf).
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
