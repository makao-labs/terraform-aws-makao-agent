# =============================================================================
# Makao Agent v3 — Public Terraform Module
#
# Deploys the Makao Agent into the caller's AWS account.
# Lambda zip is downloaded from the makao-labs/makao-agent-releases GitHub
# Release for the specified module_version, uploaded to a module-managed S3
# bucket, and deployed as a Lambda function.
#
# Usage:
#   module "makao_agent" {
#     source       = "makao-labs/makao-agent/aws"
#     version      = "0.1.0"
#     client_name  = "acme-corp"
#     account_id   = "123456789012"
#     alert_emails = ["ops@acme.com"]
#   }
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  client_slug = lower(replace(var.client_name, " ", "-"))
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  prefix      = "makao-agent-${local.client_slug}"

  release_zip_url = (
    "https://github.com/makao-labs/makao-agent-releases/releases/download/"
    "v${var.module_version}/makao-agent-${var.module_version}.zip"
  )

  common_tags = {
    Project     = "makao-agent"
    ManagedBy   = "terraform"
    Owner       = "makao-labs"
    ClientName  = var.client_name
    Version     = var.module_version
  }
}

# =============================================================================
# S3 bucket — Lambda artifact storage
# =============================================================================

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.prefix}-artifacts-${local.account_id}"
  force_destroy = true
  tags          = merge(local.common_tags, { Name = "${local.prefix}-artifacts" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Download Lambda zip from GitHub Releases and upload to S3
resource "null_resource" "download_lambda_zip" {
  triggers = { version = var.module_version }

  provisioner "local-exec" {
    command = <<-EOT
      curl -fsSL -o /tmp/makao-agent-${var.module_version}.zip \
        "${local.release_zip_url}" || \
        (echo "WARNING: Could not download Lambda zip from GitHub Releases. Upload manually." && exit 0)
    EOT
  }

  depends_on = [aws_s3_bucket.artifacts]
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "makao-agent-${var.module_version}.zip"
  source = "/tmp/makao-agent-${var.module_version}.zip"

  lifecycle {
    ignore_changes = [etag]
  }

  depends_on = [null_resource.download_lambda_zip]
}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# =============================================================================
# DynamoDB — findings storage
#
# GSI status-index: efficient query for open/in_progress findings per client
# GSI scan-count-index: range query for escalation candidates
# =============================================================================

resource "aws_dynamodb_table" "findings" {
  name         = "makao-findings-${local.client_slug}"
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "client_id"
  range_key    = "finding_id"

  attribute {
    name = "client_id"
    type = "S"
  }
  attribute {
    name = "finding_id"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "scan_count"
    type = "N"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "client_id"
    range_key       = "status"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "scan-count-index"
    hash_key        = "client_id"
    range_key       = "scan_count"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.dynamodb_point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, { Name = "makao-findings-${local.client_slug}" })
}

# =============================================================================
# IAM Role — least-privilege Lambda execution
# =============================================================================

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Makao Agent Lambda execution role for ${var.client_name}"
  tags               = local.common_tags
}

data "aws_iam_policy_document" "lambda_logs" {
  statement {
    sid     = "CloudWatchLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_logs.json
}

data "aws_iam_policy_document" "scanning" {
  # EC2 read-only for cost and SG scanning
  statement {
    sid       = "EC2ReadOnly"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }
  statement {
    sid       = "CloudWatchMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"]
  }
  statement {
    sid       = "CloudWatchLogsRead"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
  statement {
    sid       = "LambdaRead"
    effect    = "Allow"
    actions   = ["lambda:List*", "lambda:Get*"]
    resources = ["*"]
  }
  statement {
    sid       = "ECSRead"
    effect    = "Allow"
    actions   = ["ecs:List*", "ecs:Describe*"]
    resources = ["*"]
  }
  statement {
    sid       = "ELBRead"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }
  statement {
    sid       = "RDSRead"
    effect    = "Allow"
    actions   = ["rds:DescribeDBInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "EKSRead"
    effect    = "Allow"
    actions   = ["eks:ListClusters", "eks:DescribeCluster"]
    resources = ["*"]
  }
  statement {
    sid     = "S3Read"
    effect  = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketLocation",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "ComputeOptimizerRead"
    effect  = "Allow"
    actions = [
      "compute-optimizer:GetEnrollmentStatus",
      "compute-optimizer:GetEC2InstanceRecommendations",
      "compute-optimizer:GetEBSVolumeRecommendations",
      "compute-optimizer:GetLambdaFunctionRecommendations",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "CostExplorerRead"
    effect  = "Allow"
    actions = ["ce:GetCostAndUsage"]
    resources = ["*"]
  }
  statement {
    sid     = "IAMSecurityRead"
    effect  = "Allow"
    actions = [
      "iam:GetAccountSummary",
      "iam:GenerateCredentialReport",
      "iam:GetCredentialReport",
      "iam:ListUsers",
      "iam:ListRoles",
      "iam:ListAttachedUserPolicies",
      "iam:ListAttachedRolePolicies",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "GuardDutyRead"
    effect    = "Allow"
    actions   = ["guardduty:ListDetectors", "guardduty:GetDetector"]
    resources = ["*"]
  }
  statement {
    sid       = "TaggingAPIRead"
    effect    = "Allow"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }
  statement {
    sid       = "STSIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scanning" {
  name   = "aws-scanning"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.scanning.json
}

data "aws_iam_policy_document" "dynamodb" {
  statement {
    sid     = "FindingsTableAccess"
    effect  = "Allow"
    actions = [
      "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem",
      "dynamodb:Query", "dynamodb:BatchWriteItem",
    ]
    resources = [
      aws_dynamodb_table.findings.arn,
      "${aws_dynamodb_table.findings.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "dynamodb" {
  name   = "dynamodb-findings"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.dynamodb.json
}

data "aws_iam_policy_document" "ses_send" {
  statement {
    sid       = "SESSendEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ses" {
  name   = "ses-send-email"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.ses_send.json
}

data "aws_iam_policy_document" "artifacts_read" {
  statement {
    sid       = "ArtifactsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "artifacts_read" {
  name   = "artifacts-s3-read"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.artifacts_read.json
}

# =============================================================================
# SES Email Identities
#
# Each address in alert_emails gets an SES identity. AWS sends a verification
# email to each address — recipients must click the link before digests work.
# =============================================================================

resource "aws_ses_email_identity" "alert" {
  for_each = toset(var.alert_emails)
  email    = each.value
}

# =============================================================================
# Lambda Function
# =============================================================================

resource "aws_lambda_function" "makao_agent" {
  function_name = local.prefix
  description   = "Makao Agent v${var.module_version}: AWS cost and security advisor for ${var.client_name}"

  s3_bucket = aws_s3_bucket.artifacts.id
  s3_key    = aws_s3_object.lambda_zip.key

  handler     = "main.lambda_handler"
  runtime     = "python3.12"
  role        = aws_iam_role.lambda_exec.arn
  timeout     = var.lambda_timeout_seconds
  memory_size = var.lambda_memory_mb

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      CLIENT_NAME            = var.client_name
      AWS_ACCOUNT_ID         = local.account_id
      DYNAMODB_TABLE         = aws_dynamodb_table.findings.name
      SCAN_REGIONS           = var.scan_regions
      SCAN_MONTHS            = tostring(var.scan_months)
      ESCALATION_THRESHOLD   = tostring(var.escalation_threshold)
      LOG_LEVEL              = var.log_level
      MODULE_VERSION         = var.module_version
      LICENSE_KEY            = var.license_key
      ALERT_EMAILS           = join(",", var.alert_emails)
      SENDER_EMAIL           = var.alert_emails[0]
      DIGEST_FREQUENCY       = var.digest_frequency
      CLIENT_TIMEZONE        = var.client_timezone
      BUSINESS_HOURS_START   = var.business_hours_start
      BUSINESS_HOURS_END     = var.business_hours_end
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_logs.name
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.scanning,
    aws_iam_role_policy.dynamodb,
    aws_iam_role_policy.ses,
    aws_s3_object.lambda_zip,
  ]

  tags = merge(local.common_tags, { Name = local.prefix })
}

# =============================================================================
# EventBridge — nightly scan (2 AM UTC)
# =============================================================================

resource "aws_cloudwatch_event_rule" "nightly_scan" {
  name                = "${local.prefix}-scan"
  description         = "Triggers Makao Agent nightly scan at 2 AM UTC"
  schedule_expression = var.schedule_expression
  state               = "ENABLED"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "nightly_scan" {
  rule      = aws_cloudwatch_event_rule.nightly_scan.name
  target_id = "MakaoAgentScan"
  arn       = aws_lambda_function.makao_agent.arn
  input     = jsonencode({ detail = { loop = "scan" } })
}

resource "aws_lambda_permission" "nightly_scan_invoke" {
  statement_id  = "AllowEventBridgeScan"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.makao_agent.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nightly_scan.arn
}

# =============================================================================
# EventBridge — digest schedule (weekly default)
# =============================================================================

locals {
  digest_cron = {
    weekly   = "cron(0 8 ? * MON *)"
    biweekly = "cron(0 8 ? * MON#1,MON#3 *)"
    monthly  = "cron(0 8 1 * ? *)"
  }
}

resource "aws_cloudwatch_event_rule" "digest" {
  name                = "${local.prefix}-digest"
  description         = "Triggers Makao Agent email digest (${var.digest_frequency})"
  schedule_expression = local.digest_cron[var.digest_frequency]
  state               = "ENABLED"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "digest" {
  rule      = aws_cloudwatch_event_rule.digest.name
  target_id = "MakaoAgentDigest"
  arn       = aws_lambda_function.makao_agent.arn
  input     = jsonencode({ detail = { loop = "digest" } })
}

resource "aws_lambda_permission" "digest_invoke" {
  statement_id  = "AllowEventBridgeDigest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.makao_agent.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.digest.arn
}

# =============================================================================
# Registration — fires on terraform apply
#
# Mirrors the Lambda cold-start registration. Non-blocking: || true prevents
# apply failure if the registration API is unreachable.
# =============================================================================

resource "null_resource" "registration" {
  triggers = {
    client_name  = var.client_name
    account_id   = var.account_id
    version      = var.module_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -fsSL -X POST https://api.makao-labs.com/register \
        -H "Content-Type: application/json" \
        -d '{
          "account_id":     "${var.account_id}",
          "client_name":    "${var.client_name}",
          "module_version": "${var.module_version}",
          "license_key":    "${var.license_key}",
          "alert_emails":   "${join(",", var.alert_emails)}",
          "timestamp":      "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
          "tier":           "${var.license_key != "" ? "pro" : "community"}"
        }' || echo "Registration skipped (API unreachable)"
    EOT
  }
}
