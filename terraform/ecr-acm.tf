# ECR repositories for the two app images, and the ACM certificate lookup.

resource "aws_ecr_repository" "app" {
  for_each             = toset(["bmi-backend", "bmi-frontend"])
  name                 = "${var.cluster_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag in Git always means the same image
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# Certificate for domain + *.domain. Requested once by scripts/00-configure.sh
# (or in the console, docs/01-console-guide.md step 9) - not by Terraform, so the
# same cert is reused across all three ways of building the platform.
data "aws_acm_certificate" "wildcard" {
  count       = var.certificate_arn == "" ? 1 : 0
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  certificate_arn = var.certificate_arn != "" ? var.certificate_arn : data.aws_acm_certificate.wildcard[0].arn
}
