# terraform-aws-makao-agent

Deploys an AWS Lambda agent that scans your account for cost waste and security gaps, then sends a weekly HTML digest via email.

## What it finds

The agent scans EC2, EBS, RDS, EKS, ECS, Lambda, NAT gateways, EIPs, S3, and CloudWatch Logs for idle, oversized, unencrypted, or untagged resources and estimates monthly savings. On the security side it checks security groups for dangerously open ports (SSH, MySQL, PostgreSQL exposed to 0.0.0.0/0). Pro tier adds IAM audit, root MFA, and GuardDuty coverage. All findings are deduplicated across scans — the same issue won't flood your inbox.

## Quick start

### Option 1 — Terraform Registry

> **Coming Soon — not yet live.**

```hcl
module "makao_agent" {
  source  = "makao-labs/makao-agent/aws"
  version = "0.1.7"

  client_name    = "acme"
  account_id     = "123456789012"
  alert_emails   = ["ops@acme.com"]
  module_version = "0.1.7"
}
```

Terraform Registry publishing is in progress. Use Option 2 in the meantime.

### Option 2 — GitHub (Available Now)

```hcl
module "makao_agent" {
  source = "github.com/makao-labs/terraform-aws-makao-agent"

  client_name    = "acme"
  account_id     = "123456789012"
  alert_emails   = ["ops@acme.com"]
  module_version = "0.1.7"
}
```

## First-time setup (step by step)

### 1. Create a working directory

```bash
mkdir makao-agent && cd makao-agent
```

### 2. Create your Terraform configuration

Create a file named `main.tf` and paste the following:

```hcl
module "makao_agent" {
  source = "github.com/makao-labs/terraform-aws-makao-agent"

  client_name    = "your-company-name"
  account_id     = "123456789012"
  alert_emails   = ["you@yourcompany.com"]
  module_version = "0.1.7"
}
```

Replace:
- `your-company-name` — a short slug used to name resources (e.g. `acme`)
- `123456789012` — your AWS account ID
  (find it at: AWS Console → top right → your account name → Account ID)
- `you@yourcompany.com` — email address(es) to receive the digest

### 3. Initialise Terraform

```bash
terraform init
```

This downloads the Makao Agent module and the AWS provider.
You should see "Terraform has been successfully initialized."

### 4. Deploy

```bash
terraform apply
```

Terraform will show you a plan of resources to create.
Type `yes` when prompted to confirm.

Deployment takes 1–2 minutes. When complete you will see:
"Apply complete! Resources: X added."

### 5. Check your inbox

AWS SES will send a verification email to every address in `alert_emails` immediately after deployment. Check your inbox for:

> **Amazon Web Services – Email Address Verification Request**

Click the verification link in every email before triggering your first scan — SES will not deliver the digest until all addresses are verified.

### 6. Trigger your first scan

Once emails are verified, run the scan manually to get your first report without waiting for the nightly schedule:

```bash
# Step 1 — Run the scan
aws lambda invoke \
  --function-name makao-agent-<your-company-name> \
  --payload '{"detail":{"loop":"scan"}}' \
  --cli-binary-format raw-in-base64-out /tmp/scan.json && cat /tmp/scan.json

# Step 2 — Send the digest
aws lambda invoke \
  --function-name makao-agent-<your-company-name> \
  --payload '{"detail":{"loop":"digest"}}' \
  --cli-binary-format raw-in-base64-out /tmp/digest.json && cat /tmp/digest.json
```

Replace `<your-company-name>` with the value you set for `client_name`.

Your first report will arrive within a few minutes.

---

## Tiers

| | Community (free) | Pro |
|---|---|---|
| Cost scan | ✓ | ✓ |
| Multi-region | ✓ | ✓ |
| Security groups | ✓ | ✓ |
| Weekly email digest | ✓ | ✓ |
| IAM audit (admin users, inactive users) | — | ✓ |
| Root MFA check | — | ✓ |
| GuardDuty per-region | — | ✓ |
| 30-day remediation roadmap | — | ✓ |
| Architecture risk flags | — | ✓ |
| Monday briefings | — | ✓ |
| Spend spike alerts | — | ✓ |
| Makao Labs support | — | ✓ |

Set `license_key` to activate Pro. Leave it empty for Community.

## Configuration

Required variables first.

| Variable | Default | Description |
|---|---|---|
| `client_name` | required | Name used in email subjects and to namespace resources. |
| `account_id` | required | AWS account ID being monitored. |
| `alert_emails` | required | List of 1–10 email addresses to receive the digest. |
| `license_key` | `""` | Pro license key. Leave empty for Community tier. |
| `aws_region` | `us-east-1` | Primary region for Lambda and DynamoDB. |
| `scan_regions` | `""` | Leave empty to auto-discover and scan all active regions. |
| `scan_months` | `6` | Months of history used for cost and snapshot age checks. |
| `escalation_threshold` | `5` | Number of consecutive scans before a finding is escalated to high severity. |
| `digest_frequency` | `weekly` | How often the digest email is sent. Options: `weekly`, `biweekly`, `monthly`. |
| `schedule_expression` | `cron(0 2 * * ? *)` | EventBridge cron expression for the nightly scan. |
| `lambda_memory_mb` | `512` | Lambda memory in MB. |
| `lambda_timeout_seconds` | `600` | Lambda timeout in seconds (max 900). |
| `log_retention_days` | `7` | CloudWatch log retention in days. |
| `client_timezone` | `UTC` | Timezone used in email timestamps. |

## What to expect after install

### SES email verification

When `terraform apply` runs, AWS SES automatically sends a verification email to every address in `alert_emails` — this happens inside your own AWS account. Each recipient must click the verification link before any scan emails will arrive.

Look for an email with subject:

> **Amazon Web Services – Email Address Verification Request**

A few notes:
- If the verification email lands in spam, mark it as "Not spam" to train Gmail for future sends.
- This is a one-time step per email address per deployment.
- No SES setup is required beforehand — Terraform handles it automatically.

### Two-loop architecture

The agent has two separate invocation paths:

- **Scan loop** (`"loop":"scan"`) — scans your AWS account, writes findings to DynamoDB. No email is sent.
- **Digest loop** (`"loop":"digest"`) — reads open findings from DynamoDB, builds the HTML report, sends via SES.

Both must be triggered to receive an email.

### Triggering manually

Manual invocation is only needed for your first test. After that, the agent runs on its automatic schedule.

```bash
# 1. Run the scan
aws lambda invoke \
  --function-name makao-agent-<client-name> \
  --payload '{"detail":{"loop":"scan"}}' \
  --cli-binary-format raw-in-base64-out /tmp/scan.json && cat /tmp/scan.json

# 2. Then trigger the digest
aws lambda invoke \
  --function-name makao-agent-<client-name> \
  --payload '{"detail":{"loop":"digest"}}' \
  --cli-binary-format raw-in-base64-out /tmp/digest.json && cat /tmp/digest.json
```

### Automatic schedule

Scans run nightly at 2 AM UTC via EventBridge. The digest runs on the frequency set by `digest_frequency` (weekly by default, Monday at 8 AM UTC).

### Community vs Pro in the digest

If no `license_key` is set, the digest uses the community tier template: cost findings, security group findings, and an upgrade CTA. IAM audit, GuardDuty, and roadmap sections are not included.

## Removing the agent

To destroy all infrastructure created by the module, run the following from the directory containing your Terraform configuration:

```bash
terraform destroy
```

This removes:
- The Lambda function and its IAM role
- The EventBridge schedule
- The DynamoDB findings table and all scan data
- The CloudWatch log group
- The SES email identity verifications

**Note:** `terraform destroy` is irreversible. All findings history stored in DynamoDB will be deleted. If you want to retain scan history before destroying, export the DynamoDB table first:

```bash
aws dynamodb scan \
  --table-name makao-agent-<client-name>-findings \
  --output json > findings-backup.json
```

---

Pro tier includes managed email delivery from a verified domain — no SES setup required on your end. To unlock Pro, get in touch at [makao-labs.com](https://makao-labs.com).
