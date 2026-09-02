# scripts

Standalone operational scripts for the DevOps Community of Practice.

These are run by hand against live AWS. They are not wired into CI — see
[Automation](#automation) below for why.

## aws-terraform-coverage.ps1

Reports which resources in the Hack for LA **incubator** AWS account
(`035866691871`) are managed by Terraform and which are not.

Two repos write Terraform into that account, and each stamps a `managed-by`
default tag on the resources it creates:

| Repo | Tag value |
|---|---|
| [`hackforla/incubator`](https://github.com/hackforla/incubator) | `managed-by = terraform-incubator` |
| [`hackforla/devops-security`](https://github.com/hackforla/devops-security) | `managed-by = terraform-devops-security` |

A third value, `managed-by = exempt`, marks a resource that is deliberately
outside Terraform. Unlike the two above it is applied by hand rather than by a
provider, because by definition no Terraform run will ever touch the resource.

So the absence of any of those values is the signal that nothing manages a
resource. This script sweeps the account, reads the tag, and buckets everything
four ways.

This is a **tag sweep, not a Terraform state diff**. Read
[Blind spots](#blind-spots) before treating the output as an inventory.

### Requirements

- PowerShell 5.1 or later (Windows PowerShell or PowerShell 7 on macOS/Linux).
- The AWS CLI v2 on `PATH`, with credentials that can read the account.
- No `jq` and no Node tooling. JSON is parsed with `ConvertFrom-Json`.

### Usage

```powershell
./aws-terraform-coverage.ps1                              # summary
./aws-terraform-coverage.ps1 -ListArns                    # every ARN, not just counts
./aws-terraform-coverage.ps1 -AwsProfile hfla-incubator   # pick a named profile
./aws-terraform-coverage.ps1 -CsvPath coverage.csv        # full classified list as CSV
./aws-terraform-coverage.ps1 -Region us-west-2            # narrow the sweep
```

A full run makes several hundred read-only API calls and takes a few minutes.

**It sweeps `us-west-2` and `us-east-1` by default, and both are needed.**
us-west-2 holds the workloads; us-east-1 is where IAM policies, CloudFront-facing
ACM certificates and Route 53 surface. A single-region run silently
under-reports.

### Reading the output

- **`terraform-incubator` / `terraform-devops-security`** — managed, and by which repo.
- **`unmanaged`** — taggable, but carrying no recognised `managed-by` value. This
  is the number the report exists to surface.
- **`unmanageable`** — reported separately and deliberately excluded from the
  managed/unmanaged ratio, because these can never carry the tag no matter what
  anyone does. Counting them as unmanaged would make them permanent false
  positives. Three different things put a resource here:
  - **AWS exposes no way to tag it.** IAM groups have no group tagging API at all.
  - **AWS owns it.** AWS-managed KMS keys, service-linked IAM roles, the
    `FARGATE` / `FARGATE_SPOT` ECS capacity providers, elastic IPs an ELB
    allocated for itself (`ServiceManaged`), and EventBridge rules an AWS service
    created for itself (a rule with its own `ManagedBy` field, which is what
    `ecs.amazonaws.com` does for a capacity provider).
  - **Terraform cannot own or tag it, even though AWS could.** This is the
    subtle group, and every member of it is a resource that may well *be* under
    Terraform management while still reading as untagged:
    - **Autoscaling groups.** An ASG's tags are a separate schema carrying
      `propagate_at_launch`, and the AWS provider does not merge `default_tags`
      into it. No apply will ever put the tag there.
    - **Rules of a VPC's default security group.** `aws_default_security_group`
      holds its rules inline, so they are not resources of their own and nothing
      tags them. Note the group itself *is* taggable and stays in the ratio.
    - **Listener default rules.** A listener's default rule is its
      `default_action`, not an `aws_lb_listener_rule`.
    - **Instances and volumes an autoscaling group launched.** Terraform should
      not import these — it would fight the ASG and hold state that goes stale on
      the next replacement.
    - **`/aws/lambda/*` log groups.** Lambda creates these on first invocation,
      before any `aws_cloudwatch_log_group` could exist.
    - **`default.*` RDS parameter groups.** AWS reserves the name and creates one
      per engine family itself. They cannot be modified or deleted, so nothing
      can adopt them.

  **This bucket was called `untaggable` until 2026-09-02**, when the third group
  above was added. If you are comparing against a run from before that date, the
  ratio moved partly because the denominator shrank — not because anything was
  brought under management.
- **`exempt`** — carrying `managed-by = exempt`, and likewise excluded from the
  ratio. These are resources Terraform deliberately does not manage, so counting
  them as unmanaged would make them permanent false positives in the same way
  unmanageable ones would. The clearest case is `hackforla/devops-security`'s own
  CI identity and state backend: Terraform managing the credentials and the
  bucket it unlocks is a lockout risk. Note the difference from `unmanageable` —
  that bucket is a fact about AWS or about the provider, this one is an assertion
  someone made by hand, and nothing here checks it.
- **Tagged with an unrecognised `managed-by` value** — appears only when
  something stamped a provenance tag that is neither repo's and is not `exempt`.
  Worth investigating when it shows up.

### Why it does not just use the Resource Groups Tagging API

The obvious implementation is one `resourcegroupstaggingapi get-resources` call
per region. That was the original design and **it does not work**, because the
tagging API largely indexes only resources that already carry at least one tag —
exactly the wrong bias for a report whose purpose is finding untagged resources.

Measured against this account in us-west-2 on 2026-08-27:

| Service | Live | Returned by the tagging API |
|---|---|---|
| CloudWatch log groups | 26 | 9 |
| ECR repositories | 12 | 6 |
| Secrets Manager secrets | 10 | 3 |
| ACM certificates | 7 | 2 |
| SSM parameters | 45 | 36 |
| ELB target groups | 16 | 9 |
| ECS services | 14 | 9 |
| SNS topics | 2 | 0 |
| Route 53 hosted zones | 8 | **0** |
| IAM users / roles | 25 / 44 | **0 / 0** |
| S3 buckets, ASGs, KMS keys, EIPs, EBS volumes | all | **0** |

Route 53 is the clearest case: 8 zones exist, none is tagged, and the tagging
API returns nothing at all — so a tag-sweep-only report would call the account
fully managed on that axis rather than reporting 8 unmanaged zones.

So every service is enumerated natively with its own `list-*`/`describe-*` call,
and the tagging sweep runs **last**, only as a backstop for anything the native
collectors miss. As of the last run it adds **zero** resources, meaning the
native collectors are a strict superset of it. If that number is ever non-zero,
it means a service needs a collector.

The practical difference: the tagging API alone sees 203 resources in this
account; the script reports 486.

### Blind spots

The report is not a complete inventory, and the script prints these caveats after
every run so the output cannot be read without them.

- **Resource types that support no tags at all** are invisible to a tag sweep
  entirely.
- **Only services with a collector are counted in full.** A service nobody has
  added a collector for is simply absent rather than reported as missing,
  because the tagging API cannot be relied on to surface it. Adding a service
  means adding a collector.
- **`default_tags` only lands on a resource when Terraform next creates or
  updates it.** A resource that has been in state since before the tag was added
  can still read as unmanaged until some later apply touches it. A resource in
  the `unmanaged` bucket is therefore a *candidate* for being unmanaged, not
  proof.
- **Nothing is said about the reverse direction** — a resource in Terraform
  state that no longer exists in AWS. That needs a state diff, which this is not.
- **ECS task definitions** are reported as the current revision per family, not
  as every historical revision. There were 286 active revisions at the time of
  writing; the family's current revision is the meaningful unit.
- **Lambda layers** are reported as the layer, not as every layer version, for
  the same reason. This is not a choice about granularity so much as what the
  API allows: `lambda list-tags` accepts `arn:...:layer:<name>` and rejects
  `arn:...:layer:<name>:<version>` with a `ValidationException`, so the version
  cannot carry `managed-by` at all.
- **The tagging API supplement drops ARNs that are not durable resources.** The
  supplement has no type filter, so it returns things Terraform could never own.
  SSM sessions are the case that prompted the skip list: every
  `ecs execute-command` leaves one in session history, and each was landing in
  the report as an untagged, therefore unmanaged, resource. They age out on
  their own, which makes them worse than a leak — the denominator moved
  depending on whether anyone had shelled into a container recently. Add to
  `$script:TaggingApiSkipPatterns` if another such type turns up.

### Read-only

Every call the script makes is read-only. `Invoke-AwsCli` enforces this rather
than relying on convention: it refuses to run any subcommand that is not a
`describe-*`, `list-*` or `get-*`, so a mutating call cannot be added by
accident. The script never runs Terraform.

### Automation

Out of scope for now, and it is not simply a matter of adding a workflow: there
is no GitHub Actions OIDC role for `hackforla/devops`.
`devops-security/terraform/aws-gha-oidc-providers.tf` grants `gha-incubator` to
`repo:hackforla/incubator` only. Running this on a schedule would need that role
created first. Open a follow-on issue if the report proves worth automating.

### Related

- [hackforla/incubator#155](https://github.com/hackforla/incubator/issues/155) —
  the hand-captured record of the unmanaged platform that this script supersedes
  as the living version. It also carries a pending CoP decision about what to do
  with that platform, so it is not closed by this script existing.
- [hackforla/incubator#121](https://github.com/hackforla/incubator/issues/121) —
  added `managed-by = terraform-incubator`, for exactly this reporting purpose.
- [hackforla/devops-security#172](https://github.com/hackforla/devops-security/issues/172) —
  the devops-security half of the same tagging work.
