# Makao Agent v3

AWS cost and security advisor delivered as a Terraform module. Deploys a Lambda function into the client's account that scans for cost waste and security gaps, then sends an email digest via SES.

## How it works

1. **Nightly scan** — EventBridge triggers the Lambda at 2 AM UTC. The agent scans EC2, EBS, RDS, EKS, ECS, Lambda, NAT gateways, EIPs, S3, CloudWatch Logs, security groups, IAM, and GuardDuty.
2. **Findings stored** — Each finding is deduplicated in DynamoDB by `resource_id`. Recurring findings increment a `scan_count`; resolved resources are marked closed.
3. **Weekly digest** — A second EventBridge rule sends an HTML email via SES summarising open findings, estimated savings, and remediation steps.

## Tiers

| Feature | Community | Pro |
|---|---|---|
| Cost findings (EC2/EBS/RDS/…) | ✓ | ✓ |
| Security group scan (22/3306/5432 open to 0.0.0.0/0) | ✓ | ✓ |
| Weekly email digest | ✓ | ✓ |
| IAM admin user detection | — | ✓ |
| IAM inactive user detection (90 days) | — | ✓ |
| Root account MFA check | — | ✓ |
| GuardDuty per-region check | — | ✓ |
| Compute Optimizer recommendations | — | ✓ |
| 30-day remediation roadmap | — | ✓ |
| Architecture risk flags | — | ✓ |
| Monday morning briefing | — | ✓ |
| Spend spike alerts | — | ✓ |

Set `license_key` to activate Pro. Leave it empty for Community.

## Quick start

```hcl
module "makao_agent" {
  source  = "makao-labs/makao-agent/aws"
  version = "0.1.0"

  client_name  = "acme-corp"
  account_id   = "123456789012"
  alert_emails = ["ops@acme.com"]

  # Optional — omit for Community tier
  license_key = var.makao_license_key
}
```

After `terraform apply`, AWS sends a verification email to each address in `alert_emails`. Recipients must click the link before digests are delivered.

## Module variables

| Variable | Default | Description |
|---|---|---|
| `client_name` | required | Human-readable client name. Used in email subjects and DynamoDB keys. |
| `account_id` | required | AWS account ID being monitored. |
| `alert_emails` | required | 1–10 email addresses for digest delivery. |
| `license_key` | `""` | Pro license key. Empty = Community tier. |
| `aws_region` | `us-east-1` | Primary AWS region for Lambda and DynamoDB. |
| `scan_regions` | `""` | Comma-separated regions to scan. Defaults to primary region only. |
| `scan_months` | `6` | Months of history for cost and snapshot age checks. |
| `escalation_threshold` | `5` | `scan_count` at which a finding is escalated to high severity. |
| `module_version` | `0.1.0` | Lambda zip version to download from GitHub Releases. |
| `lambda_memory_mb` | `512` | Lambda memory allocation. |
| `lambda_timeout_seconds` | `600` | Lambda timeout (max 900). |
| `lambda_reserved_concurrency` | `-1` | -1 = unreserved. |
| `log_retention_days` | `7` | CloudWatch log group retention. |
| `dynamodb_billing_mode` | `PAY_PER_REQUEST` | DynamoDB billing mode. |
| `dynamodb_point_in_time_recovery` | `false` | Enable DynamoDB PITR. |
| `schedule_expression` | `cron(0 2 * * ? *)` | EventBridge cron for nightly scan. |
| `digest_frequency` | `weekly` | `weekly`, `biweekly`, or `monthly`. |
| `client_timezone` | `Africa/Nairobi` | Used in email timestamps. |
| `business_hours_start` | `08:00` | Business hours window start. |
| `business_hours_end` | `18:00` | Business hours window end. |
| `log_level` | `INFO` | Lambda log level. |

## Repo structure

```
makao-agent-v3/
├── lambda/                 # Lambda source (Python 3.12)
│   ├── main.py             # Handler + StateManager + scan/digest orchestration
│   ├── tier.py             # License key → Features dataclass
│   ├── models.py           # Finding dataclass, DynamoDB serialisation
│   ├── registration.py     # Cold-start registration (non-blocking)
│   ├── requirements.txt    # Runtime deps (python-dateutil only)
│   ├── scanner/
│   │   ├── cost.py         # Cost waste scanners
│   │   ├── security.py     # SG, IAM, GuardDuty scanners
│   │   └── compute.py      # Compute Optimizer recommendations
│   └── email/
│       ├── digest.py       # Digest orchestration + SES delivery
│       └── templates/
│           ├── community.html
│           └── pro.html
├── module/                 # Public Terraform module
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
├── releases/               # Bootstrap infra for makao-labs AWS account
│   ├── main.tf
│   ├── variables.tf
│   └── deploy-releases.sh
├── scripts/
│   └── build.sh            # Local build: produces makao-agent.zip
└── .github/workflows/
    └── release.yml         # Tag push → GitHub Release on makao-agent-releases
```

## Releasing a new version

```bash
git tag v0.2.0
git push origin v0.2.0
```

The GitHub Actions workflow builds `makao-agent-0.2.0.zip`, creates a release on `makao-labs/makao-agent-releases`, and uploads the zip and SHA-256 checksum as assets.

Requires `RELEASES_REPO_TOKEN` secret — a PAT with `repo` scope on `makao-labs/makao-agent-releases`.

## Local build

```bash
bash scripts/build.sh                    # → makao-agent.zip
bash scripts/build.sh --version 0.2.0   # → makao-agent-0.2.0.zip
```

## Bootstrap (run once)

```bash
cd releases/
export AWS_PROFILE=makao-labs
bash deploy-releases.sh
```

Provisions the Terraform state S3 bucket and GitHub Actions OIDC role in the makao-labs AWS account.

## Security model

- Findings are sanitised before storage: account IDs in ARNs are replaced with `REDACTED`.
- No raw account IDs, ARNs, or IP addresses are transmitted externally.
- The registration call (`api.makao-labs.com/register`) is the only external network call the Lambda makes, and it is non-blocking — a failure never affects the scan.
- Lambda IAM role is least-privilege: read-only AWS APIs, write to its own DynamoDB table and SES only.
