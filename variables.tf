# =============================================================================
# Makao Agent v3 — Module Variables
# =============================================================================

# -----------------------------------------------------------------------------
# Required
# -----------------------------------------------------------------------------

variable "client_name" {
  description = "Human-readable name for this deployment. Written to all findings and registration payload."
  type        = string
}

variable "account_id" {
  description = "AWS account ID where the agent is deployed. Used in registration and IAM policy conditions."
  type        = string
}

variable "alert_emails" {
  description = "Email addresses that receive digest reports and alerts. Each address gets an SES identity (verification email sent on apply)."
  type        = list(string)
  validation {
    condition     = length(var.alert_emails) >= 1 && length(var.alert_emails) <= 10
    error_message = "Provide 1–10 alert email addresses."
  }
}

# -----------------------------------------------------------------------------
# Optional — AWS
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "Primary AWS region for the agent deployment."
  type        = string
  default     = "us-east-1"
}

variable "scan_regions" {
  description = "Regions to scan. 'auto' discovers all opted-in regions. Or pass comma-separated list e.g. 'us-east-1,eu-west-1'."
  type        = string
  default     = "auto"
}

# -----------------------------------------------------------------------------
# Optional — Tier
# -----------------------------------------------------------------------------

variable "license_key" {
  description = "Makao Agent Pro license key. Empty string = community tier."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Optional — Scanning
# -----------------------------------------------------------------------------

variable "scan_months" {
  description = "Lookback window in months for cost analysis (snapshot age, CPU history). Community tier enforces a maximum of 3."
  type        = number
  default     = 6
}

variable "escalation_threshold" {
  description = "Consecutive scans before a persistent finding triggers an escalation alert."
  type        = number
  default     = 5
}

# -----------------------------------------------------------------------------
# Optional — Lambda
# -----------------------------------------------------------------------------

variable "lambda_memory_mb" {
  description = "Lambda memory allocation in MB."
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda execution timeout in seconds."
  type        = number
  default     = 600
}

variable "lambda_reserved_concurrency" {
  description = "Lambda reserved concurrent executions. -1 = unreserved (uses account pool)."
  type        = number
  default     = -1
}

variable "log_level" {
  description = "Lambda log level. Options: DEBUG, INFO, WARNING, ERROR."
  type        = string
  default     = "INFO"
}

variable "module_version" {
  description = "Makao Agent module version to deploy. Determines which GitHub Release zip is downloaded."
  type        = string
  default     = "0.1.0"
}

# -----------------------------------------------------------------------------
# Optional — CloudWatch
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# Optional — DynamoDB
# -----------------------------------------------------------------------------

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode. PAY_PER_REQUEST or PROVISIONED."
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "dynamodb_point_in_time_recovery" {
  description = "Enable DynamoDB point-in-time recovery."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Optional — Scheduling
# -----------------------------------------------------------------------------

variable "schedule_expression" {
  description = "EventBridge cron expression for the nightly scan. Default: 2 AM UTC daily."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

variable "digest_frequency" {
  description = "Email digest cadence. Options: weekly, biweekly, monthly."
  type        = string
  default     = "weekly"
  validation {
    condition     = contains(["weekly", "biweekly", "monthly"], var.digest_frequency)
    error_message = "digest_frequency must be weekly, biweekly, or monthly."
  }
}

# -----------------------------------------------------------------------------
# Optional — Timezone / business hours
# -----------------------------------------------------------------------------

variable "client_timezone" {
  description = "Client local timezone (IANA format). Used for time-based scheduling."
  type        = string
  default     = "Africa/Nairobi"
}

variable "business_hours_start" {
  description = "Business hours start in 24h HH:MM format."
  type        = string
  default     = "08:00"
}

variable "business_hours_end" {
  description = "Business hours end in 24h HH:MM format."
  type        = string
  default     = "18:00"
}
