#Requires -Version 5.1
<#
.SYNOPSIS
    Reports which AWS resources in the Hack for LA incubator account are managed
    by Terraform and which are not.

.DESCRIPTION
    Both hackforla/incubator and hackforla/devops-security stamp a `managed-by`
    default tag on every resource their Terraform creates or next updates, so the
    absence of that tag is the signal that nothing manages a resource.

    This is a tag sweep, not a Terraform state diff.

    The Resource Groups Tagging API is a supplement here, not the enumerator.
    Measured against this account on 2026-08-27 it under-reports nearly every
    service, because it largely indexes only resources that already carry at
    least one tag - which is precisely the wrong bias for a report whose whole
    purpose is finding untagged resources. Observed live-versus-sweep counts in
    us-west-2 included ECR 12/6, CloudWatch log groups 26/9, Secrets Manager
    10/3, ACM 7/2, SSM 45/36 and SNS 2/0. Every service below is therefore
    enumerated natively and the tagging sweep only fills in anything the native
    collectors missed.

    Resource types that can never carry a tag are reported as their own category
    so they do not read as unmanaged forever. Resources deliberately kept out of
    Terraform carry `managed-by = exempt`, applied by hand rather than by any
    provider, and are excluded from the ratio for the same reason.

    Read the "Blind spots" section of README.md before treating the output as a
    complete inventory.

    Every AWS call made here is read-only. Invoke-AwsCli refuses any subcommand
    that is not a describe-*, list-* or get-*.

.PARAMETER Region
    Regions to sweep. Defaults to us-west-2, which holds the workloads, and
    us-east-1, where IAM policies, CloudFront-facing ACM certificates and
    Route 53 surface. A single-region run silently under-reports.

.PARAMETER AwsProfile
    Named AWS CLI profile to use. Defaults to the ambient credentials.

.PARAMETER ExpectedAccountId
    Account this script expects to be pointed at. A mismatch warns but does not
    stop, so the script can be reused against another account deliberately.

.PARAMETER ListArns
    List every unmanaged and untaggable ARN, not just the per-service counts.

.PARAMETER CsvPath
    Also write the full classified resource list to this path as CSV.

.EXAMPLE
    ./aws-terraform-coverage.ps1

.EXAMPLE
    ./aws-terraform-coverage.ps1 -AwsProfile hfla-incubator -ListArns

.EXAMPLE
    ./aws-terraform-coverage.ps1 -CsvPath coverage.csv
#>
[CmdletBinding()]
param(
    [string[]]$Region = @('us-west-2', 'us-east-1'),
    [string]$AwsProfile,
    [string]$ExpectedAccountId = '035866691871',
    [switch]$ListArns,
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

$script:TagKey              = 'managed-by'
$script:IncubatorValue      = 'terraform-incubator'
$script:DevOpsSecurityValue = 'terraform-devops-security'
$script:ExemptValue         = 'exempt'
$script:ReadOnlyVerbPattern = '^(describe|list|get)-'

# ---------------------------------------------------------------------------
# AWS CLI plumbing
# ---------------------------------------------------------------------------

function Invoke-AwsCli {
    <#
        Runs one read-only AWS CLI call and returns the parsed JSON.

        -Tolerant is for calls that fail as a normal outcome rather than as an
        error, such as get-bucket-tagging against a bucket with no tag set at
        all. Those return $null instead of throwing.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Tolerant
    )

    if ($Arguments.Count -lt 2 -or $Arguments[1] -notmatch $script:ReadOnlyVerbPattern) {
        throw (("Refusing to run 'aws {0}': this script makes read-only " +
                '(describe-*/list-*/get-*) calls only.') -f ($Arguments -join ' '))
    }

    $callArgs = @($Arguments)
    if ($AwsProfile) { $callArgs += @('--profile', $AwsProfile) }
    $callArgs += @('--output', 'json')

    if ($Tolerant) {
        # Redirecting a native command's stderr in Windows PowerShell 5.1 turns
        # each line into an ErrorRecord, which $ErrorActionPreference = 'Stop'
        # then makes terminating - even when the exit code is 0. Relax it for
        # the duration of the call and judge success by $LASTEXITCODE instead.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { $raw = & aws @callArgs 2>$null }
        finally { $ErrorActionPreference = $previousPreference }
    }
    else {
        $raw = & aws @callArgs
    }

    if ($LASTEXITCODE -ne 0) {
        if ($Tolerant) { return $null }
        throw "aws $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Split-IntoChunks {
    <# Several describe-tags style APIs cap the number of ARNs per call. #>
    param([object[]]$Items, [int]$Size)

    $chunks = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $Items.Count; $index += $Size) {
        $end = [math]::Min($index + $Size - 1, $Items.Count - 1)
        $null = $chunks.Add(@($Items[$index..$end]))
    }
    return $chunks
}

# ---------------------------------------------------------------------------
# Tag readers
#
# Tag shapes differ per API and none of these are interchangeable:
#   Key/Value pairs        - tagging API, IAM, EC2, ASG, ACM, RDS, S3 (TagSet)
#   key/value pairs        - ECS (lower case; PowerShell property access is
#                            case-insensitive, so the same reader handles it)
#   TagKey/TagValue pairs  - KMS
#   dictionary object      - Cognito, Lambda, CloudWatch Logs, SQS
# ---------------------------------------------------------------------------

function Get-TagValueFromPairs {
    param($Pairs, [string]$Name = $script:TagKey)

    if ($null -eq $Pairs) { return $null }
    foreach ($pair in $Pairs) {
        if ($null -eq $pair) { continue }
        $names = $pair.PSObject.Properties.Name
        $key = $null
        if ($names -contains 'Key')        { $key = $pair.Key }
        elseif ($names -contains 'TagKey') { $key = $pair.TagKey }
        if ($key -ne $Name) { continue }
        if ($names -contains 'Value')    { return $pair.Value }
        if ($names -contains 'TagValue') { return $pair.TagValue }
    }
    return $null
}

function Get-TagValueFromMap {
    param($Map, [string]$Name = $script:TagKey)

    if ($null -eq $Map) { return $null }
    foreach ($property in $Map.PSObject.Properties) {
        if ($property.Name -eq $Name) { return $property.Value }
    }
    return $null
}

function Select-Nested {
    <# Walks a dotted property path, tolerating nulls anywhere along it. #>
    param($InputObject, [string]$Path)

    $current = $InputObject
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $current = $current.$segment
    }
    return $current
}

function Get-ManagedByFromCall {
    <#
        Fetches tags for a single resource with its own API call and returns the
        managed-by value. Used wherever the listing API does not return tags.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$TagsPath = 'Tags',
        [switch]$AsMap,
        [switch]$Tolerant
    )

    if ($Tolerant) { $response = Invoke-AwsCli -Arguments $Arguments -Tolerant }
    else           { $response = Invoke-AwsCli -Arguments $Arguments }
    if ($null -eq $response) { return $null }

    $tags = Select-Nested -InputObject $response -Path $TagsPath
    if ($AsMap) { return Get-TagValueFromMap -Map $tags }
    return Get-TagValueFromPairs -Pairs $tags
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

function Get-CoverageBucket {
    param([string]$ManagedBy)

    if ($ManagedBy -eq $script:IncubatorValue)      { return $script:IncubatorValue }
    if ($ManagedBy -eq $script:DevOpsSecurityValue) { return $script:DevOpsSecurityValue }
    if ($ManagedBy -eq $script:ExemptValue)         { return $script:ExemptValue }
    return 'unmanaged'
}

function ConvertFrom-ResourceArn {
    <# Splits an ARN into the service and resource type used for reporting. #>
    param([string]$Arn)

    $parts = $Arn -split ':', 6
    $service = ''
    $region = ''
    $resource = ''
    if ($parts.Count -ge 6) {
        $service  = $parts[2]
        $region   = $parts[3]
        $resource = $parts[5]
    }

    # S3 bucket ARNs carry no resource-type segment, only the bucket name.
    if ($service -eq 's3') { $type = 'bucket' }
    elseif ($resource -match '^([^/:]+)[/:]') { $type = $Matches[1] }
    else { $type = $resource }

    if ([string]::IsNullOrWhiteSpace($region)) { $region = 'global' }

    return [pscustomobject]@{ Service = $service; Type = $type; Region = $region }
}

$script:Resources = New-Object System.Collections.ArrayList
$script:SeenArns  = New-Object System.Collections.Generic.HashSet[string]

function Add-Resource {
    <#
        Records one classified resource, deduplicating by ARN so anything found
        by both a native collector and the tagging sweep is counted once. The
        native collectors run first, so they win on any overlap.
    #>
    param(
        [Parameter(Mandatory)][string]$Arn,
        [string]$ManagedBy,
        [string]$Source,
        [string]$Service,
        [string]$Type,
        [string]$ResourceRegion,
        [switch]$Untaggable,
        [string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($Arn)) { return }
    if (-not $script:SeenArns.Add($Arn)) { return }

    if (-not $Service -or -not $Type -or -not $ResourceRegion) {
        $parsed = ConvertFrom-ResourceArn -Arn $Arn
        if (-not $Service)        { $Service = $parsed.Service }
        if (-not $Type)           { $Type = $parsed.Type }
        if (-not $ResourceRegion) { $ResourceRegion = $parsed.Region }
    }

    if ($Untaggable) { $bucket = 'untaggable' }
    else { $bucket = Get-CoverageBucket -ManagedBy $ManagedBy }

    $null = $script:Resources.Add([pscustomobject]@{
        Arn       = $Arn
        Service   = $Service
        Type      = $Type
        Region    = $ResourceRegion
        ManagedBy = $ManagedBy
        Bucket    = $bucket
        Source    = $Source
        Note      = $Note
    })
}

function Write-Step {
    param([string]$Label)
    Write-Host ('  {0,-46}' -f $Label) -NoNewline
}

# ---------------------------------------------------------------------------
# Global collectors - IAM, Route 53, S3
# ---------------------------------------------------------------------------

function Add-IamResources {
    Write-Step 'IAM users, roles, policies, groups'
    $count = 0

    foreach ($user in @((Invoke-AwsCli -Arguments @('iam', 'list-users')).Users)) {
        if ($null -eq $user) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @('iam', 'list-user-tags', '--user-name', $user.UserName)
        Add-Resource -Arn $user.Arn -ManagedBy $managedBy -Source 'iam:list-users' `
                     -Service 'iam' -Type 'user' -ResourceRegion 'global'
        $count++
    }

    foreach ($role in @((Invoke-AwsCli -Arguments @('iam', 'list-roles')).Roles)) {
        if ($null -eq $role) { continue }
        # Service-linked roles are created and owned by an AWS service, not by
        # anything in either Terraform repo.
        if ($role.Path -like '/aws-service-role/*') {
            Add-Resource -Arn $role.Arn -Source 'iam:list-roles' -Service 'iam' `
                         -Type 'role' -ResourceRegion 'global' -Untaggable `
                         -Note 'AWS service-linked role'
            $count++
            continue
        }
        # IAM Identity Center owns everything under /aws-reserved/. These roles
        # are provisioned from permission sets and re-provisioned whenever the
        # permission set changes, which discards any tag written here, so they
        # cannot hold managed-by even though the tagging API accepts one.
        if ($role.Path -like '/aws-reserved/*') {
            Add-Resource -Arn $role.Arn -Source 'iam:list-roles' -Service 'iam' `
                         -Type 'role' -ResourceRegion 'global' -Untaggable `
                         -Note 'IAM Identity Center reserved role'
            $count++
            continue
        }
        $managedBy = Get-ManagedByFromCall -Arguments @('iam', 'list-role-tags', '--role-name', $role.RoleName)
        Add-Resource -Arn $role.Arn -ManagedBy $managedBy -Source 'iam:list-roles' `
                     -Service 'iam' -Type 'role' -ResourceRegion 'global'
        $count++
    }

    foreach ($policy in @((Invoke-AwsCli -Arguments @('iam', 'list-policies', '--scope', 'Local')).Policies)) {
        if ($null -eq $policy) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @('iam', 'list-policy-tags', '--policy-arn', $policy.Arn)
        Add-Resource -Arn $policy.Arn -ManagedBy $managedBy -Source 'iam:list-policies' `
                     -Service 'iam' -Type 'policy' -ResourceRegion 'global'
        $count++
    }

    $providers = (Invoke-AwsCli -Arguments @('iam', 'list-open-id-connect-providers')).OpenIDConnectProviderList
    foreach ($provider in @($providers)) {
        if ($null -eq $provider) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @('iam', 'get-open-id-connect-provider',
                                                        '--open-id-connect-provider-arn', $provider.Arn)
        Add-Resource -Arn $provider.Arn -ManagedBy $managedBy -Source 'iam:list-open-id-connect-providers' `
                     -Service 'iam' -Type 'oidc-provider' -ResourceRegion 'global'
        $count++
    }

    # AWS exposes no tagging API for IAM groups at all - there is no
    # iam tag-group and no iam list-group-tags - so these can never carry the
    # tag and must not be reported as unmanaged.
    foreach ($group in @((Invoke-AwsCli -Arguments @('iam', 'list-groups')).Groups)) {
        if ($null -eq $group) { continue }
        Add-Resource -Arn $group.Arn -Source 'iam:list-groups' -Service 'iam' `
                     -Type 'group' -ResourceRegion 'global' -Untaggable `
                     -Note 'IAM groups have no AWS tagging API'
        $count++
    }

    Write-Host $count
    return $count
}

function Add-Route53Resources {
    Write-Step 'Route 53 hosted zones'
    $count = 0
    foreach ($zone in @((Invoke-AwsCli -Arguments @('route53', 'list-hosted-zones')).HostedZones)) {
        if ($null -eq $zone) { continue }
        $zoneId = $zone.Id -replace '^/hostedzone/', ''
        $managedBy = Get-ManagedByFromCall -TagsPath 'ResourceTagSet.Tags' -Arguments @(
            'route53', 'list-tags-for-resource', '--resource-type', 'hostedzone', '--resource-id', $zoneId)
        Add-Resource -Arn "arn:aws:route53:::hostedzone/$zoneId" -ManagedBy $managedBy `
                     -Source 'route53:list-hosted-zones' -Service 'route53' `
                     -Type 'hostedzone' -ResourceRegion 'global'
        $count++
    }
    Write-Host $count
    return $count
}

function Add-S3Resources {
    Write-Step 'S3 buckets'
    $count = 0
    foreach ($bucket in @((Invoke-AwsCli -Arguments @('s3api', 'list-buckets')).Buckets)) {
        if ($null -eq $bucket) { continue }
        # A bucket with no tag set at all makes this call fail; that is a normal
        # outcome and means the same thing as an empty tag set.
        $managedBy = Get-ManagedByFromCall -Tolerant -TagsPath 'TagSet' `
                                           -Arguments @('s3api', 'get-bucket-tagging', '--bucket', $bucket.Name)
        Add-Resource -Arn "arn:aws:s3:::$($bucket.Name)" -ManagedBy $managedBy `
                     -Source 's3api:list-buckets' -Service 's3' -Type 'bucket' -ResourceRegion 'global'
        $count++
    }
    Write-Host $count
    return $count
}

# ---------------------------------------------------------------------------
# Regional collectors
# ---------------------------------------------------------------------------

function Add-Ec2Resources {
    param([string]$SweepRegion)
    $count = 0

    # EC2 describe-* calls return tags inline, so no per-resource tag call.
    $collectors = @(
        @{ Type = 'security-group';      Arguments = @('ec2', 'describe-security-groups');      Property = 'SecurityGroups';     Id = 'GroupId' }
        @{ Type = 'security-group-rule'; Arguments = @('ec2', 'describe-security-group-rules'); Property = 'SecurityGroupRules'; Id = 'SecurityGroupRuleId' }
        @{ Type = 'subnet';           Arguments = @('ec2', 'describe-subnets');           Property = 'Subnets';          Id = 'SubnetId' }
        @{ Type = 'vpc';              Arguments = @('ec2', 'describe-vpcs');              Property = 'Vpcs';             Id = 'VpcId' }
        @{ Type = 'route-table';      Arguments = @('ec2', 'describe-route-tables');      Property = 'RouteTables';      Id = 'RouteTableId' }
        @{ Type = 'natgateway';       Arguments = @('ec2', 'describe-nat-gateways');      Property = 'NatGateways';      Id = 'NatGatewayId' }
        @{ Type = 'internet-gateway'; Arguments = @('ec2', 'describe-internet-gateways'); Property = 'InternetGateways'; Id = 'InternetGatewayId' }
        @{ Type = 'volume';           Arguments = @('ec2', 'describe-volumes');           Property = 'Volumes';          Id = 'VolumeId' }
        @{ Type = 'launch-template';  Arguments = @('ec2', 'describe-launch-templates');  Property = 'LaunchTemplates';  Id = 'LaunchTemplateId' }
        @{ Type = 'elastic-ip';       Arguments = @('ec2', 'describe-addresses');         Property = 'Addresses';        Id = 'AllocationId' }
    )

    foreach ($collector in $collectors) {
        $response = Invoke-AwsCli -Arguments ($collector.Arguments + @('--region', $SweepRegion))
        foreach ($item in @($response.($collector.Property))) {
            if ($null -eq $item) { continue }
            Add-Resource -Arn ('arn:aws:ec2:{0}:{1}:{2}/{3}' -f $SweepRegion, $script:AccountId, $collector.Type, $item.($collector.Id)) `
                         -ManagedBy (Get-TagValueFromPairs -Pairs $item.Tags) `
                         -Source "ec2:$($collector.Arguments[1])" -Service 'ec2' `
                         -Type $collector.Type -ResourceRegion $SweepRegion
            $count++
        }
    }

    # Instances are nested one level deeper than the rest.
    $reservations = (Invoke-AwsCli -Arguments @('ec2', 'describe-instances', '--region', $SweepRegion)).Reservations
    foreach ($reservation in @($reservations)) {
        foreach ($instance in @($reservation.Instances)) {
            if ($null -eq $instance) { continue }
            Add-Resource -Arn ('arn:aws:ec2:{0}:{1}:instance/{2}' -f $SweepRegion, $script:AccountId, $instance.InstanceId) `
                         -ManagedBy (Get-TagValueFromPairs -Pairs $instance.Tags) `
                         -Source 'ec2:describe-instances' -Service 'ec2' `
                         -Type 'instance' -ResourceRegion $SweepRegion
            $count++
        }
    }

    return $count
}

function Add-AutoScalingResources {
    param([string]$SweepRegion)
    $count = 0
    $groups = (Invoke-AwsCli -Arguments @('autoscaling', 'describe-auto-scaling-groups', '--region', $SweepRegion)).AutoScalingGroups
    foreach ($group in @($groups)) {
        if ($null -eq $group) { continue }
        Add-Resource -Arn $group.AutoScalingGroupARN -ManagedBy (Get-TagValueFromPairs -Pairs $group.Tags) `
                     -Source 'autoscaling:describe-auto-scaling-groups' -Service 'autoscaling' `
                     -Type 'autoScalingGroup' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-AcmResources {
    param([string]$SweepRegion)
    $count = 0
    $certificates = (Invoke-AwsCli -Arguments @('acm', 'list-certificates', '--region', $SweepRegion)).CertificateSummaryList
    foreach ($certificate in @($certificates)) {
        if ($null -eq $certificate) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @('acm', 'list-tags-for-certificate',
                                                        '--certificate-arn', $certificate.CertificateArn,
                                                        '--region', $SweepRegion)
        Add-Resource -Arn $certificate.CertificateArn -ManagedBy $managedBy `
                     -Source 'acm:list-certificates' -Service 'acm' `
                     -Type 'certificate' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-EcrResources {
    param([string]$SweepRegion)
    $count = 0
    $repositories = (Invoke-AwsCli -Arguments @('ecr', 'describe-repositories', '--region', $SweepRegion)).repositories
    foreach ($repository in @($repositories)) {
        if ($null -eq $repository) { continue }
        $managedBy = Get-ManagedByFromCall -TagsPath 'tags' -Arguments @(
            'ecr', 'list-tags-for-resource', '--resource-arn', $repository.repositoryArn, '--region', $SweepRegion)
        Add-Resource -Arn $repository.repositoryArn -ManagedBy $managedBy `
                     -Source 'ecr:describe-repositories' -Service 'ecr' `
                     -Type 'repository' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-LambdaResources {
    param([string]$SweepRegion)
    $count = 0
    $functions = (Invoke-AwsCli -Arguments @('lambda', 'list-functions', '--region', $SweepRegion)).Functions
    foreach ($function in @($functions)) {
        if ($null -eq $function) { continue }
        $managedBy = Get-ManagedByFromCall -AsMap -Arguments @(
            'lambda', 'list-tags', '--resource', $function.FunctionArn, '--region', $SweepRegion)
        Add-Resource -Arn $function.FunctionArn -ManagedBy $managedBy `
                     -Source 'lambda:list-functions' -Service 'lambda' `
                     -Type 'function' -ResourceRegion $SweepRegion
        $count++
    }

    # Layers are a separate resource from the functions that use them, and the
    # tagging API does not return them, so without this they were invisible.
    # The taggable unit is the layer, not the layer version: ListTags accepts
    # arn:...:layer:<name> and rejects arn:...:layer:<name>:<version>. Versions
    # are therefore counted through their layer, the same way task definition
    # revisions are counted through their family.
    foreach ($layer in @((Invoke-AwsCli -Arguments @('lambda', 'list-layers', '--region', $SweepRegion)).Layers)) {
        if ($null -eq $layer) { continue }
        $managedBy = Get-ManagedByFromCall -AsMap -Arguments @(
            'lambda', 'list-tags', '--resource', $layer.LayerArn, '--region', $SweepRegion)
        Add-Resource -Arn $layer.LayerArn -ManagedBy $managedBy `
                     -Source 'lambda:list-layers' -Service 'lambda' `
                     -Type 'layer' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-DynamoDbResources {
    param([string]$SweepRegion)
    $count = 0
    foreach ($table in @((Invoke-AwsCli -Arguments @('dynamodb', 'list-tables', '--region', $SweepRegion)).TableNames)) {
        if ([string]::IsNullOrWhiteSpace($table)) { continue }
        $arn = 'arn:aws:dynamodb:{0}:{1}:table/{2}' -f $SweepRegion, $script:AccountId, $table
        $managedBy = Get-ManagedByFromCall -Arguments @(
            'dynamodb', 'list-tags-of-resource', '--resource-arn', $arn, '--region', $SweepRegion)
        Add-Resource -Arn $arn -ManagedBy $managedBy -Source 'dynamodb:list-tables' `
                     -Service 'dynamodb' -Type 'table' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-CloudWatchResources {
    param([string]$SweepRegion)
    $count = 0

    foreach ($alarm in @((Invoke-AwsCli -Arguments @('cloudwatch', 'describe-alarms', '--region', $SweepRegion)).MetricAlarms)) {
        if ($null -eq $alarm) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @(
            'cloudwatch', 'list-tags-for-resource', '--resource-arn', $alarm.AlarmArn, '--region', $SweepRegion)
        Add-Resource -Arn $alarm.AlarmArn -ManagedBy $managedBy `
                     -Source 'cloudwatch:describe-alarms' -Service 'cloudwatch' `
                     -Type 'alarm' -ResourceRegion $SweepRegion
        $count++
    }

    foreach ($logGroup in @((Invoke-AwsCli -Arguments @('logs', 'describe-log-groups', '--region', $SweepRegion)).logGroups)) {
        if ($null -eq $logGroup) { continue }
        # The ARN from describe-log-groups carries a trailing ":*" that
        # list-tags-for-resource rejects.
        $arn = $logGroup.arn -replace ':\*$', ''
        $managedBy = Get-ManagedByFromCall -AsMap -TagsPath 'tags' -Tolerant -Arguments @(
            'logs', 'list-tags-for-resource', '--resource-arn', $arn, '--region', $SweepRegion)
        Add-Resource -Arn $arn -ManagedBy $managedBy -Source 'logs:describe-log-groups' `
                     -Service 'logs' -Type 'log-group' -ResourceRegion $SweepRegion
        $count++
    }

    return $count
}

function Add-MessagingResources {
    param([string]$SweepRegion)
    $count = 0

    foreach ($secret in @((Invoke-AwsCli -Arguments @('secretsmanager', 'list-secrets', '--region', $SweepRegion)).SecretList)) {
        if ($null -eq $secret) { continue }
        Add-Resource -Arn $secret.ARN -ManagedBy (Get-TagValueFromPairs -Pairs $secret.Tags) `
                     -Source 'secretsmanager:list-secrets' -Service 'secretsmanager' `
                     -Type 'secret' -ResourceRegion $SweepRegion
        $count++
    }

    foreach ($topic in @((Invoke-AwsCli -Arguments @('sns', 'list-topics', '--region', $SweepRegion)).Topics)) {
        if ($null -eq $topic) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @(
            'sns', 'list-tags-for-resource', '--resource-arn', $topic.TopicArn, '--region', $SweepRegion)
        Add-Resource -Arn $topic.TopicArn -ManagedBy $managedBy -Source 'sns:list-topics' `
                     -Service 'sns' -Type 'topic' -ResourceRegion $SweepRegion
        $count++
    }

    foreach ($queueUrl in @((Invoke-AwsCli -Arguments @('sqs', 'list-queues', '--region', $SweepRegion)).QueueUrls)) {
        if ([string]::IsNullOrWhiteSpace($queueUrl)) { continue }
        $queueName = $queueUrl.Substring($queueUrl.LastIndexOf('/') + 1)
        $managedBy = Get-ManagedByFromCall -AsMap -Tolerant -Arguments @(
            'sqs', 'list-queue-tags', '--queue-url', $queueUrl, '--region', $SweepRegion)
        Add-Resource -Arn ('arn:aws:sqs:{0}:{1}:{2}' -f $SweepRegion, $script:AccountId, $queueName) `
                     -ManagedBy $managedBy -Source 'sqs:list-queues' -Service 'sqs' `
                     -Type 'queue' -ResourceRegion $SweepRegion
        $count++
    }

    foreach ($rule in @((Invoke-AwsCli -Arguments @('events', 'list-rules', '--region', $SweepRegion)).Rules)) {
        if ($null -eq $rule) { continue }
        $managedBy = Get-ManagedByFromCall -Arguments @(
            'events', 'list-tags-for-resource', '--resource-arn', $rule.Arn, '--region', $SweepRegion)
        Add-Resource -Arn $rule.Arn -ManagedBy $managedBy -Source 'events:list-rules' `
                     -Service 'events' -Type 'rule' -ResourceRegion $SweepRegion
        $count++
    }

    return $count
}

function Add-SsmResources {
    param([string]$SweepRegion)
    $count = 0
    foreach ($parameter in @((Invoke-AwsCli -Arguments @('ssm', 'describe-parameters', '--region', $SweepRegion)).Parameters)) {
        if ($null -eq $parameter) { continue }
        $managedBy = Get-ManagedByFromCall -TagsPath 'TagList' -Tolerant -Arguments @(
            'ssm', 'list-tags-for-resource', '--resource-type', 'Parameter',
            '--resource-id', $parameter.Name, '--region', $SweepRegion)
        Add-Resource -Arn ('arn:aws:ssm:{0}:{1}:parameter{2}' -f $SweepRegion, $script:AccountId, ($parameter.Name -replace '^/?', '/')) `
                     -ManagedBy $managedBy -Source 'ssm:describe-parameters' `
                     -Service 'ssm' -Type 'parameter' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-EcsResources {
    param([string]$SweepRegion)
    $count = 0

    $clusterArns = @((Invoke-AwsCli -Arguments @('ecs', 'list-clusters', '--region', $SweepRegion)).clusterArns)
    foreach ($clusterArn in $clusterArns) {
        if ([string]::IsNullOrWhiteSpace($clusterArn)) { continue }
        $cluster = (Invoke-AwsCli -Arguments @('ecs', 'describe-clusters', '--clusters', $clusterArn,
                                               '--include', 'TAGS', '--region', $SweepRegion)).clusters
        Add-Resource -Arn $clusterArn -ManagedBy (Get-TagValueFromPairs -Pairs $cluster[0].tags) `
                     -Source 'ecs:list-clusters' -Service 'ecs' -Type 'cluster' -ResourceRegion $SweepRegion
        $count++

        $serviceArns = @((Invoke-AwsCli -Arguments @('ecs', 'list-services', '--cluster', $clusterArn,
                                                     '--region', $SweepRegion)).serviceArns)
        # describe-services accepts at most 10 services per call.
        foreach ($chunk in (Split-IntoChunks -Items $serviceArns -Size 10)) {
            $described = (Invoke-AwsCli -Arguments (@('ecs', 'describe-services', '--cluster', $clusterArn,
                                                      '--include', 'TAGS', '--region', $SweepRegion, '--services') + $chunk)).services
            foreach ($service in @($described)) {
                if ($null -eq $service) { continue }
                Add-Resource -Arn $service.serviceArn -ManagedBy (Get-TagValueFromPairs -Pairs $service.tags) `
                             -Source 'ecs:list-services' -Service 'ecs' -Type 'service' -ResourceRegion $SweepRegion
                $count++
            }
        }
    }

    $capacityProviders = (Invoke-AwsCli -Arguments @('ecs', 'describe-capacity-providers',
                                                     '--include', 'TAGS', '--region', $SweepRegion)).capacityProviders
    foreach ($provider in @($capacityProviders)) {
        if ($null -eq $provider) { continue }
        # FARGATE and FARGATE_SPOT are owned by AWS and exist in every account.
        if ($provider.name -in @('FARGATE', 'FARGATE_SPOT')) {
            Add-Resource -Arn $provider.capacityProviderArn -Source 'ecs:describe-capacity-providers' `
                         -Service 'ecs' -Type 'capacity-provider' -ResourceRegion $SweepRegion `
                         -Untaggable -Note 'AWS-owned ECS capacity provider'
            $count++
            continue
        }
        Add-Resource -Arn $provider.capacityProviderArn -ManagedBy (Get-TagValueFromPairs -Pairs $provider.tags) `
                     -Source 'ecs:describe-capacity-providers' -Service 'ecs' `
                     -Type 'capacity-provider' -ResourceRegion $SweepRegion
        $count++
    }

    # Task definition revisions are immutable deploy artifacts and there are
    # hundreds of them, so only the current revision of each family is reported.
    $families = @((Invoke-AwsCli -Arguments @('ecs', 'list-task-definition-families',
                                              '--status', 'ACTIVE', '--region', $SweepRegion)).families)
    foreach ($family in $families) {
        if ([string]::IsNullOrWhiteSpace($family)) { continue }
        $described = Invoke-AwsCli -Tolerant -Arguments @('ecs', 'describe-task-definition',
                                                          '--task-definition', $family,
                                                          '--include', 'TAGS', '--region', $SweepRegion)
        if ($null -eq $described) { continue }
        Add-Resource -Arn $described.taskDefinition.taskDefinitionArn `
                     -ManagedBy (Get-TagValueFromPairs -Pairs $described.tags) `
                     -Source 'ecs:list-task-definition-families' -Service 'ecs' `
                     -Type 'task-definition' -ResourceRegion $SweepRegion
        $count++
    }

    return $count
}

function Add-LoadBalancingResources {
    param([string]$SweepRegion)
    $count = 0

    $arns = New-Object System.Collections.ArrayList
    $lookup = @{}

    foreach ($loadBalancer in @((Invoke-AwsCli -Arguments @('elbv2', 'describe-load-balancers', '--region', $SweepRegion)).LoadBalancers)) {
        if ($null -eq $loadBalancer) { continue }
        $null = $arns.Add($loadBalancer.LoadBalancerArn)
        $lookup[$loadBalancer.LoadBalancerArn] = 'loadbalancer'

        $listeners = (Invoke-AwsCli -Arguments @('elbv2', 'describe-listeners',
                                                 '--load-balancer-arn', $loadBalancer.LoadBalancerArn,
                                                 '--region', $SweepRegion)).Listeners
        foreach ($listener in @($listeners)) {
            if ($null -eq $listener) { continue }
            $null = $arns.Add($listener.ListenerArn)
            $lookup[$listener.ListenerArn] = 'listener'

            $rules = (Invoke-AwsCli -Arguments @('elbv2', 'describe-rules',
                                                 '--listener-arn', $listener.ListenerArn,
                                                 '--region', $SweepRegion)).Rules
            foreach ($rule in @($rules)) {
                if ($null -eq $rule) { continue }
                $null = $arns.Add($rule.RuleArn)
                $lookup[$rule.RuleArn] = 'listener-rule'
            }
        }
    }
    foreach ($targetGroup in @((Invoke-AwsCli -Arguments @('elbv2', 'describe-target-groups', '--region', $SweepRegion)).TargetGroups)) {
        if ($null -eq $targetGroup) { continue }
        $null = $arns.Add($targetGroup.TargetGroupArn)
        $lookup[$targetGroup.TargetGroupArn] = 'targetgroup'
    }

    # describe-tags accepts at most 20 ARNs per call.
    foreach ($chunk in (Split-IntoChunks -Items $arns.ToArray() -Size 20)) {
        $descriptions = (Invoke-AwsCli -Arguments (@('elbv2', 'describe-tags', '--region', $SweepRegion, '--resource-arns') + $chunk)).TagDescriptions
        foreach ($description in @($descriptions)) {
            if ($null -eq $description) { continue }
            Add-Resource -Arn $description.ResourceArn -ManagedBy (Get-TagValueFromPairs -Pairs $description.Tags) `
                         -Source 'elbv2:describe-tags' -Service 'elasticloadbalancing' `
                         -Type $lookup[$description.ResourceArn] -ResourceRegion $SweepRegion
            $count++
        }
    }

    return $count
}

function Add-RdsResources {
    param([string]$SweepRegion)
    $count = 0

    # RDS describe-* calls return TagList inline.
    $collectors = @(
        @{ Type = 'db';       Arguments = @('rds', 'describe-db-instances');        Property = 'DBInstances';        Arn = 'DBInstanceArn' }
        @{ Type = 'snapshot'; Arguments = @('rds', 'describe-db-snapshots');        Property = 'DBSnapshots';        Arn = 'DBSnapshotArn' }
        @{ Type = 'pg';       Arguments = @('rds', 'describe-db-parameter-groups'); Property = 'DBParameterGroups';  Arn = 'DBParameterGroupArn' }
        @{ Type = 'subgrp';   Arguments = @('rds', 'describe-db-subnet-groups');    Property = 'DBSubnetGroups';     Arn = 'DBSubnetGroupArn' }
    )

    foreach ($collector in $collectors) {
        $response = Invoke-AwsCli -Arguments ($collector.Arguments + @('--region', $SweepRegion))
        foreach ($item in @($response.($collector.Property))) {
            if ($null -eq $item) { continue }
            $arn = $item.($collector.Arn)
            $managedBy = Get-TagValueFromPairs -Pairs $item.TagList
            if ($null -eq $managedBy) {
                $managedBy = Get-ManagedByFromCall -TagsPath 'TagList' -Tolerant -Arguments @(
                    'rds', 'list-tags-for-resource', '--resource-name', $arn, '--region', $SweepRegion)
            }
            Add-Resource -Arn $arn -ManagedBy $managedBy -Source "rds:$($collector.Arguments[1])" `
                         -Service 'rds' -Type $collector.Type -ResourceRegion $SweepRegion
            $count++
        }
    }

    return $count
}

function Add-CognitoResources {
    param([string]$SweepRegion)
    $count = 0
    $pools = (Invoke-AwsCli -Arguments @('cognito-idp', 'list-user-pools', '--max-results', '60', '--region', $SweepRegion)).UserPools
    foreach ($pool in @($pools)) {
        if ($null -eq $pool) { continue }
        $arn = 'arn:aws:cognito-idp:{0}:{1}:userpool/{2}' -f $SweepRegion, $script:AccountId, $pool.Id
        # Cognito returns tags as a dictionary, not as Key/Value pairs.
        $managedBy = Get-ManagedByFromCall -AsMap -Arguments @(
            'cognito-idp', 'list-tags-for-resource', '--resource-arn', $arn, '--region', $SweepRegion)
        Add-Resource -Arn $arn -ManagedBy $managedBy -Source 'cognito-idp:list-user-pools' `
                     -Service 'cognito-idp' -Type 'userpool' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-KmsResources {
    param([string]$SweepRegion)
    $count = 0
    foreach ($key in @((Invoke-AwsCli -Arguments @('kms', 'list-keys', '--region', $SweepRegion)).Keys)) {
        if ($null -eq $key) { continue }
        $metadata = (Invoke-AwsCli -Arguments @('kms', 'describe-key', '--key-id', $key.KeyId, '--region', $SweepRegion)).KeyMetadata

        # AWS-managed keys cannot be tagged by the account, so they would
        # otherwise be permanent false positives in the same way IAM groups are.
        if ($metadata.KeyManager -ne 'CUSTOMER') {
            Add-Resource -Arn $metadata.Arn -Source 'kms:list-keys' -Service 'kms' `
                         -Type 'key' -ResourceRegion $SweepRegion -Untaggable `
                         -Note 'AWS-managed KMS key - not taggable by the account'
            $count++
            continue
        }

        # KMS uses TagKey/TagValue rather than Key/Value.
        $managedBy = Get-ManagedByFromCall -Tolerant -Arguments @(
            'kms', 'list-resource-tags', '--key-id', $key.KeyId, '--region', $SweepRegion)
        Add-Resource -Arn $metadata.Arn -ManagedBy $managedBy -Source 'kms:list-keys' `
                     -Service 'kms' -Type 'key' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

function Add-CloudTrailResources {
    param([string]$SweepRegion)
    $count = 0
    $trails = (Invoke-AwsCli -Arguments @('cloudtrail', 'describe-trails', '--region', $SweepRegion)).trailList
    foreach ($trail in @($trails)) {
        if ($null -eq $trail) { continue }
        # A trail is reported by every region it is visible from; keep it under
        # the region that actually owns it.
        if ($trail.HomeRegion -ne $SweepRegion) { continue }
        $tagList = (Invoke-AwsCli -Tolerant -Arguments @('cloudtrail', 'list-tags',
                                                         '--resource-id-list', $trail.TrailARN,
                                                         '--region', $SweepRegion)).ResourceTagList
        Add-Resource -Arn $trail.TrailARN -ManagedBy (Get-TagValueFromPairs -Pairs $tagList[0].TagsList) `
                     -Source 'cloudtrail:describe-trails' -Service 'cloudtrail' `
                     -Type 'trail' -ResourceRegion $SweepRegion
        $count++
    }
    return $count
}

# ---------------------------------------------------------------------------
# Tagging API - supplement only, run last so native results win on overlap
# ---------------------------------------------------------------------------

# The tagging API has no type filter and returns some things that are not
# durable resources. Anything matching one of these is dropped rather than
# classified, because it can never carry managed-by and is not something
# Terraform could own.
#
# SSM sessions are the case that prompted this. Every `ecs execute-command`
# leaves a session in SSM's history, the tagging API returns it, and it lands in
# the report as an untagged - therefore unmanaged - resource. They age out of
# session history on their own, so this is not a slow leak; it is something
# worse for a metric, because the denominator moves depending on whether anyone
# happened to shell into a container in the days before the run. Two runs on
# 2026-08-31 differed for exactly this reason.
$script:TaggingApiSkipPatterns = @(
    'arn:aws:ssm:*:*:session/*'      # a transient action, not a resource
)

function Test-TaggingApiSkip {
    param([string]$Arn)
    foreach ($pattern in $script:TaggingApiSkipPatterns) {
        if ($Arn -like $pattern) { return $true }
    }
    return $false
}

function Add-TaggingApiResources {
    param([string]$SweepRegion)

    Write-Step "tagging API supplement ($SweepRegion)"
    $before = $script:Resources.Count
    $skipped = 0
    $result = Invoke-AwsCli -Arguments @('resourcegroupstaggingapi', 'get-resources', '--region', $SweepRegion)
    foreach ($item in @($result.ResourceTagMappingList)) {
        if ($null -eq $item) { continue }
        if (Test-TaggingApiSkip -Arn $item.ResourceARN) { $skipped++; continue }
        Add-Resource -Arn $item.ResourceARN -ManagedBy (Get-TagValueFromPairs -Pairs $item.Tags) `
                     -Source 'tagging-api'
    }
    $added = $script:Resources.Count - $before
    if ($skipped -gt 0) { Write-Host "$added new, $skipped skipped" }
    else { Write-Host "$added new" }
    return $added
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor Cyan
}

function Write-CoverageReport {
    $all        = @($script:Resources)
    $untaggable = @($all | Where-Object { $_.Bucket -eq 'untaggable' })
    $exempt     = @($all | Where-Object { $_.Bucket -eq $script:ExemptValue })
    # Exempt resources are deliberately outside Terraform, so counting them as
    # unmanaged would make them permanent false positives - the same argument that
    # keeps untaggable out of the ratio. Both are excluded from it here.
    $taggable   = @($all | Where-Object { $_.Bucket -ne 'untaggable' -and $_.Bucket -ne $script:ExemptValue })
    $incubator  = @($taggable | Where-Object { $_.Bucket -eq $script:IncubatorValue })
    $security   = @($taggable | Where-Object { $_.Bucket -eq $script:DevOpsSecurityValue })
    $unmanaged  = @($taggable | Where-Object { $_.Bucket -eq 'unmanaged' })

    Write-Section 'Coverage summary'
    $total   = $taggable.Count
    $managed = $incubator.Count + $security.Count
    $percent = 0
    if ($total -gt 0) { $percent = [math]::Round(100 * $managed / $total, 1) }

    @(
        [pscustomobject]@{ Bucket = $script:IncubatorValue;      Resources = $incubator.Count }
        [pscustomobject]@{ Bucket = $script:DevOpsSecurityValue; Resources = $security.Count }
        [pscustomobject]@{ Bucket = 'unmanaged';                 Resources = $unmanaged.Count }
        [pscustomobject]@{ Bucket = $script:ExemptValue;         Resources = $exempt.Count }
    ) | Format-Table -AutoSize | Out-String | Write-Host

    Write-Host ("  {0} of {1} in-scope resources carry a managed-by tag ({2}%)." -f $managed, $total, $percent)
    Write-Host ("  {0} further resources cannot be tagged at all and are excluded from that ratio." -f $untaggable.Count)
    Write-Host ("  {0} are tagged managed-by=exempt and are excluded from it as well." -f $exempt.Count)

    # A managed-by value that is neither repo's means something stamped a
    # provenance tag we do not recognise, which is worth surfacing on its own.
    $unrecognised = @($unmanaged | Where-Object { $_.ManagedBy })
    if ($unrecognised.Count -gt 0) {
        Write-Section 'Tagged with an unrecognised managed-by value'
        $unrecognised | Group-Object ManagedBy | Sort-Object Count -Descending |
            Select-Object @{ n = 'ManagedBy'; e = { $_.Name } }, Count |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    Write-Section 'Unmanaged resources by service and type'
    if ($unmanaged.Count -eq 0) { Write-Host '  none' }
    else {
        $unmanaged | Group-Object Service, Type | Sort-Object Count -Descending |
            Select-Object @{ n = 'Service/Type'; e = { $_.Name -replace ', ', '/' } }, Count |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    Write-Section 'Exempt (deliberately outside Terraform, not counted as unmanaged)'
    if ($exempt.Count -eq 0) { Write-Host '  none' }
    else { $exempt | Sort-Object Service, Type, Arn | ForEach-Object { Write-Host "  $($_.Arn)" } }

    Write-Section 'Untaggable (reported separately, not counted as unmanaged)'
    if ($untaggable.Count -eq 0) { Write-Host '  none' }
    else {
        $untaggable | Group-Object Note | Sort-Object Count -Descending |
            Select-Object @{ n = 'Reason'; e = { $_.Name } }, Count |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    if ($ListArns) {
        Write-Section 'Unmanaged ARNs'
        if ($unmanaged.Count -eq 0) { Write-Host '  none' }
        else { $unmanaged | Sort-Object Service, Type, Arn | ForEach-Object { Write-Host "  $($_.Arn)" } }

        Write-Section 'Untaggable ARNs'
        if ($untaggable.Count -eq 0) { Write-Host '  none' }
        else { $untaggable | Sort-Object Service, Type, Arn | ForEach-Object { Write-Host "  $($_.Arn)" } }
    }

    Write-Section 'Blind spots - this report is not a complete inventory'
    $blindSpots = @(
        @('Resource types that support no tags at all are invisible to a tag sweep.'),
        @('Only the services this script enumerates natively are counted in full.',
          'A service nobody has added a collector for is simply absent rather than',
          'reported as missing, because the tagging API cannot be relied on to',
          'surface it.'),
        @('default_tags only lands on a resource when Terraform next creates or',
          'updates it, so a resource in state since before the tag was added can',
          'still read as unmanaged until some later apply touches it.'),
        @('This says nothing about the reverse direction: a resource in Terraform',
          'state that no longer exists in AWS.'),
        @('managed-by=exempt is applied by hand, so it records an intention rather',
          'than a fact. Nothing here verifies that an exempt resource is genuinely',
          'one Terraform should not manage.'),
        @('ECS task definitions are reported as the current revision per family,',
          'not as every historical revision. Lambda layers are reported as the',
          'layer, not as every layer version, for the same reason: the layer is',
          'the unit ListTags accepts.'),
        @('The tagging API supplement drops ARNs that are not durable resources,',
          'currently SSM sessions. They cannot carry managed-by and would',
          'otherwise move the denominator run to run.')
    )
    foreach ($spot in $blindSpots) {
        Write-Host "  - $($spot[0])"
        for ($index = 1; $index -lt $spot.Count; $index++) { Write-Host "    $($spot[$index])" }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw 'The AWS CLI (aws) was not found on PATH. Install it and try again.'
}

$identity = Invoke-AwsCli -Arguments @('sts', 'get-caller-identity')
$script:AccountId = $identity.Account

Write-Host ''
Write-Host "Account : $($script:AccountId)"
Write-Host "Identity: $($identity.Arn)"
Write-Host "Regions : $($Region -join ', ')"

if ($ExpectedAccountId -and $script:AccountId -ne $ExpectedAccountId) {
    Write-Warning (("Expected account {0} but the current credentials are for {1}. " +
                    'Continuing anyway.') -f $ExpectedAccountId, $script:AccountId)
}

Write-Host ''
Write-Host 'Global resources'
$null = Add-IamResources
$null = Add-Route53Resources
$null = Add-S3Resources

foreach ($sweepRegion in $Region) {
    Write-Host ''
    Write-Host "Regional resources ($sweepRegion)"

    $regionalCollectors = @(
        @{ Label = 'EC2';                    Function = 'Add-Ec2Resources' }
        @{ Label = 'Auto Scaling';           Function = 'Add-AutoScalingResources' }
        @{ Label = 'ACM';                    Function = 'Add-AcmResources' }
        @{ Label = 'ECR';                    Function = 'Add-EcrResources' }
        @{ Label = 'Lambda';                 Function = 'Add-LambdaResources' }
        @{ Label = 'DynamoDB';               Function = 'Add-DynamoDbResources' }
        @{ Label = 'CloudWatch and Logs';    Function = 'Add-CloudWatchResources' }
        @{ Label = 'Secrets, SNS, SQS, EventBridge'; Function = 'Add-MessagingResources' }
        @{ Label = 'SSM parameters';         Function = 'Add-SsmResources' }
        @{ Label = 'ECS';                    Function = 'Add-EcsResources' }
        @{ Label = 'Load balancing';         Function = 'Add-LoadBalancingResources' }
        @{ Label = 'RDS';                    Function = 'Add-RdsResources' }
        @{ Label = 'Cognito';                Function = 'Add-CognitoResources' }
        @{ Label = 'KMS';                    Function = 'Add-KmsResources' }
        @{ Label = 'CloudTrail';             Function = 'Add-CloudTrailResources' }
    )

    foreach ($collector in $regionalCollectors) {
        Write-Step $collector.Label
        $count = & $collector.Function -SweepRegion $sweepRegion
        Write-Host $count
    }
}

Write-Host ''
Write-Host 'Tagging API supplement'
foreach ($sweepRegion in $Region) { $null = Add-TaggingApiResources -SweepRegion $sweepRegion }

Write-CoverageReport

if ($CsvPath) {
    $script:Resources | Sort-Object Bucket, Service, Type, Arn |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
    Write-Host "Full classified list written to $CsvPath"
    Write-Host ''
}
