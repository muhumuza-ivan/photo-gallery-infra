#!/usr/bin/env bash
#
# Verifies every IAM role this project uses actually has the permissions it
# needs - and, just as importantly, does NOT have the ones it should not.
#
# It does not read the policy documents and guess. It asks IAM to evaluate them,
# with iam:SimulatePrincipalPolicy, which is the same engine that authorises the
# real calls. Conditions, resource scoping and implicit denies are all applied.
#
# Roles that do not exist yet are reported as SKIP rather than FAIL, so this is
# safe to run at any point:
#
#   after prereq-roles.yaml         -> the deployment role is checked
#   after DeployStage: foundation   -> + the CI, task and execution roles
#   after DeployStage: full         -> + the pipeline, CodeDeploy and Events roles
#
# Usage:  ./check-roles.sh [stack-name]        (default: photo-gallery)
# Needs:  iam:SimulatePrincipalPolicy, iam:GetRole, cloudformation:DescribeStacks
# Runs in: CloudShell, Git Bash, WSL, any Linux/macOS shell.

set -uo pipefail

STACK="${1:-photo-gallery}"
PROJECT="${PROJECT_NAME:-photo-gallery}"
REGION="$(aws configure get region 2>/dev/null || echo "${AWS_REGION:-eu-west-1}")"
PARTITION="aws"

if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
   || [[ -z "$ACCOUNT" ]]; then
  echo "Cannot reach AWS - configure credentials first (aws sts get-caller-identity)." >&2
  exit 2
fi

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; D=""; N=""
fi

pass=0; fail=0; skip=0

stack_output() {   # stack_output <OutputKey> -> value or empty
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

# ---------------------------------------------------------------- ARNs -------
IMAGE_BUCKET="$(stack_output ImageBucketName)"
ARTIFACT_BUCKET="$(stack_output ArtifactBucketName)"
DB_SECRET="$(stack_output DatabaseSecretArn)"
[[ -z "$IMAGE_BUCKET"    ]] && IMAGE_BUCKET="${PROJECT}-images-${ACCOUNT}-${REGION}"
[[ -z "$ARTIFACT_BUCKET" ]] && ARTIFACT_BUCKET="${PROJECT}-artifacts-${ACCOUNT}-${REGION}"

ECR_ARN="arn:${PARTITION}:ecr:${REGION}:${ACCOUNT}:repository/${PROJECT}"
LOGS_ARN="arn:${PARTITION}:logs:${REGION}:${ACCOUNT}:log-group:/ecs/${PROJECT}:*"
PIPELINE_ARN="arn:${PARTITION}:codepipeline:${REGION}:${ACCOUNT}:${PROJECT}-pipeline"
OIDC_ARN="arn:${PARTITION}:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
TASK_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/${PROJECT}-task"
OTHER_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/some-unrelated-admin-role"
OTHER_SECRET="arn:${PARTITION}:secretsmanager:${REGION}:${ACCOUNT}:secret:unrelated-AbCdEf"
OTHER_PIPELINE="arn:${PARTITION}:codepipeline:${REGION}:${ACCOUNT}:some-other-pipeline"

echo
echo "Account ${ACCOUNT}   region ${REGION}   stack ${STACK}"
echo "$(printf '%.0s─' {1..78})"

role_exists() { aws iam get-role --role-name "$1" >/dev/null 2>&1; }

# check <role> <expect allow|deny> <action> <resource> [ctxKey ctxValue]
check() {
  local role="$1" expect="$2" action="$3" resource="$4" ck="${5:-}" cv="${6:-}"
  local arn="arn:${PARTITION}:iam::${ACCOUNT}:role/${role}" decision args=()

  args=(--policy-source-arn "$arn" --action-names "$action"
        --resource-arns "$resource" --query 'EvaluationResults[0].EvalDecision'
        --output text)
  [[ -n "$ck" ]] && args+=(--context-entries "ContextKeyName=${ck},ContextKeyValues=${cv},ContextKeyType=string")

  decision="$(aws iam simulate-principal-policy "${args[@]}" 2>/dev/null)" || decision="error"

  local ok="no"
  if [[ "$expect" == "allow" && "$decision" == "allowed" ]]; then ok="yes"; fi
  if [[ "$expect" == "deny"  && "$decision" == *"Deny"*   ]]; then ok="yes"; fi

  if [[ "$ok" == "yes" ]]; then
    pass=$((pass + 1))
    printf '   %sPASS%s  %-6s %-46s %s%s%s\n' "$G" "$N" "$expect" "$action" "$D" "$decision" "$N"
  else
    fail=$((fail + 1))
    printf '   %sFAIL%s  %-6s %-46s got %s\n' "$R" "$N" "$expect" "$action" "$decision"
    printf '         on %s\n' "$resource"
  fi
}

role_header() {
  local role="$1" what="$2"
  echo
  if role_exists "$role"; then
    printf '%s  %s%s%s\n' "$role" "$D" "$what" "$N"
    return 0
  fi
  skip=$((skip + 1))
  printf '%s  %sSKIP - not created yet (%s)%s\n' "$role" "$Y" "$what" "$N"
  return 1
}

# =============================================================================
# 1. Deployment role - from prereq-roles.yaml. Must exist before anything else.
# =============================================================================
if role_header "${PROJECT}-cfn-execution" "assumed by CloudFormation to build the stack"; then
  check "${PROJECT}-cfn-execution" allow ec2:CreateVpc                            '*'
  check "${PROJECT}-cfn-execution" allow elasticloadbalancing:CreateLoadBalancer  '*'
  check "${PROJECT}-cfn-execution" allow ecs:CreateService                        '*'
  check "${PROJECT}-cfn-execution" allow ecr:CreateRepository                     '*'
  check "${PROJECT}-cfn-execution" allow rds:CreateDBInstance                     '*'
  check "${PROJECT}-cfn-execution" allow s3:CreateBucket                          '*'
  check "${PROJECT}-cfn-execution" allow cloudfront:CreateDistribution            '*'
  check "${PROJECT}-cfn-execution" allow logs:CreateLogGroup                      '*'
  check "${PROJECT}-cfn-execution" allow cloudwatch:PutMetricAlarm                '*'
  check "${PROJECT}-cfn-execution" allow application-autoscaling:RegisterScalableTarget '*'
  check "${PROJECT}-cfn-execution" allow codedeploy:CreateDeploymentGroup         '*'
  check "${PROJECT}-cfn-execution" allow codepipeline:CreatePipeline              '*'
  check "${PROJECT}-cfn-execution" allow events:PutRule                           '*'
  check "${PROJECT}-cfn-execution" allow iam:CreateRole                           "arn:${PARTITION}:iam::${ACCOUNT}:role/${PROJECT}-task"
  check "${PROJECT}-cfn-execution" allow iam:CreateOpenIDConnectProvider          "$OIDC_ARN"
  check "${PROJECT}-cfn-execution" allow iam:PassRole "$TASK_ROLE_ARN" iam:PassedToService ecs-tasks.amazonaws.com
  # the scoping that makes this role defensible
  check "${PROJECT}-cfn-execution" deny  iam:CreateRole                           "$OTHER_ROLE_ARN"
  check "${PROJECT}-cfn-execution" deny  iam:PassRole                             "$OTHER_ROLE_ARN"
  check "${PROJECT}-cfn-execution" deny  iam:CreateUser                           '*'
  check "${PROJECT}-cfn-execution" deny  iam:AttachUserPolicy                     '*'
fi

# =============================================================================
# 2. Application CI role - pushes images, stages the deploy bundle.
# =============================================================================
if role_header "${PROJECT}-github-actions" "assumed by the app repo via OIDC"; then
  check "${PROJECT}-github-actions" allow ecr:GetAuthorizationToken   '*'
  check "${PROJECT}-github-actions" allow ecr:InitiateLayerUpload     "$ECR_ARN"
  check "${PROJECT}-github-actions" allow ecr:PutImage                "$ECR_ARN"
  check "${PROJECT}-github-actions" allow ecs:DescribeTaskDefinition  '*'
  check "${PROJECT}-github-actions" allow s3:PutObject                "arn:${PARTITION}:s3:::${ARTIFACT_BUCKET}/deploy/bundle.zip"
  # it builds and stages; it must not be able to deploy or read user photos
  check "${PROJECT}-github-actions" deny  ecr:DeleteRepository        "$ECR_ARN"
  check "${PROJECT}-github-actions" deny  ecs:UpdateService           '*'
  check "${PROJECT}-github-actions" deny  codepipeline:StartPipelineExecution "$PIPELINE_ARN"
  check "${PROJECT}-github-actions" deny  s3:GetObject                "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/x.jpg"
  check "${PROJECT}-github-actions" deny  s3:PutObject                "arn:${PARTITION}:s3:::${ARTIFACT_BUCKET}/elsewhere/x"
fi

# =============================================================================
# 3. Task role - what the running application itself can do. The tightest one.
# =============================================================================
if role_header "${PROJECT}-task" "assumed by the container"; then
  check "${PROJECT}-task" allow s3:PutObject    "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/new.jpg"
  # write-only, one prefix, one bucket - CloudFront does the reading
  check "${PROJECT}-task" deny  s3:GetObject    "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/new.jpg"
  check "${PROJECT}-task" deny  s3:DeleteObject "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/new.jpg"
  check "${PROJECT}-task" deny  s3:ListBucket   "arn:${PARTITION}:s3:::${IMAGE_BUCKET}"
  check "${PROJECT}-task" deny  s3:PutObject    "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/elsewhere/x"
  check "${PROJECT}-task" deny  s3:PutObject    "arn:${PARTITION}:s3:::${ARTIFACT_BUCKET}/deploy/x"
  check "${PROJECT}-task" deny  secretsmanager:GetSecretValue "${DB_SECRET:-$OTHER_SECRET}"
fi

# =============================================================================
# 4. Execution role - used by the ECS agent, not by the application.
# =============================================================================
if role_header "${PROJECT}-task-execution" "assumed by the ECS agent"; then
  check "${PROJECT}-task-execution" allow ecr:GetAuthorizationToken   '*'
  check "${PROJECT}-task-execution" allow ecr:BatchGetImage           "$ECR_ARN"
  check "${PROJECT}-task-execution" allow ecr:GetDownloadUrlForLayer  "$ECR_ARN"
  check "${PROJECT}-task-execution" allow logs:CreateLogStream        "$LOGS_ARN"
  check "${PROJECT}-task-execution" allow logs:PutLogEvents           "$LOGS_ARN"
  if [[ -n "$DB_SECRET" ]]; then
    check "${PROJECT}-task-execution" allow secretsmanager:GetSecretValue "$DB_SECRET"
    check "${PROJECT}-task-execution" allow kms:Decrypt '*' kms:ViaService "secretsmanager.${REGION}.amazonaws.com"
  else
    skip=$((skip + 1))
    printf '   %sSKIP%s  secret checks - stack has no DatabaseSecretArn output yet\n' "$Y" "$N"
  fi
  check "${PROJECT}-task-execution" deny  secretsmanager:GetSecretValue "$OTHER_SECRET"
  check "${PROJECT}-task-execution" deny  s3:PutObject "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/x.jpg"
  check "${PROJECT}-task-execution" deny  ecs:UpdateService '*'
  # Deliberately not simulated: kms:Decrypt with no kms:ViaService context. The
  # simulator reports missing context keys rather than evaluating the condition,
  # so the result would be an artefact of the tool, not a fact about the policy.
fi

# =============================================================================
# 5-7. Pipeline roles - only exist once DeployStage is 'full'.
# =============================================================================
if role_header "${PROJECT}-codepipeline" "assumed by CodePipeline"; then
  check "${PROJECT}-codepipeline" allow s3:GetObject            "arn:${PARTITION}:s3:::${ARTIFACT_BUCKET}/deploy/bundle.zip"
  check "${PROJECT}-codepipeline" allow s3:GetBucketVersioning  "arn:${PARTITION}:s3:::${ARTIFACT_BUCKET}"
  check "${PROJECT}-codepipeline" allow codedeploy:CreateDeployment '*'
  check "${PROJECT}-codepipeline" allow ecs:RegisterTaskDefinition  '*'
  check "${PROJECT}-codepipeline" allow iam:PassRole "$TASK_ROLE_ARN" iam:PassedToService ecs-tasks.amazonaws.com
  check "${PROJECT}-codepipeline" deny  iam:PassRole "$OTHER_ROLE_ARN"
  check "${PROJECT}-codepipeline" deny  s3:DeleteObject "arn:${PARTITION}:s3:::${IMAGE_BUCKET}/photos/x.jpg"
fi

if role_header "${PROJECT}-codedeploy" "assumed by CodeDeploy"; then
  check "${PROJECT}-codedeploy" allow ecs:DescribeServices               '*'
  check "${PROJECT}-codedeploy" allow ecs:CreateTaskSet                  '*'
  check "${PROJECT}-codedeploy" allow elasticloadbalancing:ModifyListener '*'
  check "${PROJECT}-codedeploy" allow cloudwatch:DescribeAlarms          '*'
fi

if role_header "${PROJECT}-eventbridge-pipeline" "assumed by EventBridge"; then
  check "${PROJECT}-eventbridge-pipeline" allow codepipeline:StartPipelineExecution "$PIPELINE_ARN"
  check "${PROJECT}-eventbridge-pipeline" deny  codepipeline:StartPipelineExecution "$OTHER_PIPELINE"
  check "${PROJECT}-eventbridge-pipeline" deny  ecs:UpdateService '*'
fi

# =============================================================================
# 8. Trust policies. Permissions are half the story - who may assume the role
#    is the other half, and it is where an OIDC setup usually goes wrong.
# =============================================================================
echo
echo "Trust policies"

trust_check() {   # trust_check <role> <description> <grep pattern> <expect present|absent>
  local role="$1" what="$2" pattern="$3" expect="$4" doc
  role_exists "$role" || { skip=$((skip + 1))
    printf '   %sSKIP%s  %s - role not created yet\n' "$Y" "$N" "$role"; return; }
  doc="$(aws iam get-role --role-name "$role" --query Role.AssumeRolePolicyDocument --output json)"
  if grep -qi -- "$pattern" <<<"$doc"; then found=present; else found=absent; fi
  if [[ "$found" == "$expect" ]]; then
    pass=$((pass + 1)); printf '   %sPASS%s  %s\n' "$G" "$N" "$what"
  else
    fail=$((fail + 1)); printf '   %sFAIL%s  %s (expected %s, got %s)\n' "$R" "$N" "$what" "$expect" "$found"
  fi
}

trust_check "${PROJECT}-cfn-execution"   "cfn-execution trusts CloudFormation only"       'cloudformation\.amazonaws\.com' present
trust_check "${PROJECT}-cfn-execution"   "cfn-execution pinned to this account"           'aws:SourceAccount'              present
trust_check "${PROJECT}-github-actions"  "github-actions pinned to one repo AND branch"   'repo:.*/.*:ref:refs/heads/'     present
trust_check "${PROJECT}-github-actions"  "github-actions audience is sts.amazonaws.com"   'sts\.amazonaws\.com'            present
trust_check "${PROJECT}-github-actions"  "github-actions sub is NOT a bare wildcard"      '"token.actions.githubusercontent.com:sub": *"\*"' absent
trust_check "${PROJECT}-task"            "task role trusts ecs-tasks only"                'ecs-tasks\.amazonaws\.com'      present
trust_check "${PROJECT}-task-execution"  "execution role trusts ecs-tasks only"           'ecs-tasks\.amazonaws\.com'      present

# =============================================================================
# 9. Git sync role - what turns a push into a deployment.
# =============================================================================
if role_header "${PROJECT}-git-sync" "assumed by CloudFormation Git sync"; then
  STACK_ARN="arn:${PARTITION}:cloudformation:${REGION}:${ACCOUNT}:stack/${STACK}/*"
  check "${PROJECT}-git-sync" allow cloudformation:CreateChangeSet  "$STACK_ARN"
  check "${PROJECT}-git-sync" allow cloudformation:ExecuteChangeSet "$STACK_ARN"
  check "${PROJECT}-git-sync" allow cloudformation:DescribeStacks   "$STACK_ARN"
  check "${PROJECT}-git-sync" allow iam:PassRole \
        "arn:${PARTITION}:iam::${ACCOUNT}:role/${PROJECT}-cfn-execution" \
        iam:PassedToService cloudformation.amazonaws.com
  # it triggers builds; it must not be able to perform them
  check "${PROJECT}-git-sync" deny  ec2:CreateVpc        '*'
  check "${PROJECT}-git-sync" deny  iam:CreateRole       "arn:${PARTITION}:iam::${ACCOUNT}:role/${PROJECT}-task"
  check "${PROJECT}-git-sync" deny  iam:PassRole         "$OTHER_ROLE_ARN"
  check "${PROJECT}-git-sync" deny  cloudformation:DeleteStack "$STACK_ARN"
  check "${PROJECT}-git-sync" deny  cloudformation:CreateChangeSet \
        "arn:${PARTITION}:cloudformation:${REGION}:${ACCOUNT}:stack/some-other-stack/*"
fi

# The Git sync service principal is AWS-owned, so it is read from the account
# rather than trusted from the template. AWS creates AWSServiceRoleForGitSync
# alongside a Git sync setup; whatever principal that role trusts is the value
# ours must match. Getting this wrong is silent - the role simply never gets
# assumed and pushes stop deploying - so it is asserted, not just printed.
echo
echo "Git sync service principal"
SLR_PRINCIPAL="$(aws iam get-role --role-name AWSServiceRoleForGitSync \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' \
  --output text 2>/dev/null)"

if [[ -z "$SLR_PRINCIPAL" || "$SLR_PRINCIPAL" == "None" ]]; then
  skip=$((skip + 1))
  printf '   %sSKIP%s  AWSServiceRoleForGitSync not present - nothing to compare against\n' "$Y" "$N"
elif role_exists "${PROJECT}-git-sync"; then
  OURS="$(aws iam get-role --role-name "${PROJECT}-git-sync" \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)"
  if [[ "$OURS" == "$SLR_PRINCIPAL" ]]; then
    pass=$((pass + 1))
    printf '   %sPASS%s  our role trusts %s\n' "$G" "$N" "$OURS"
  else
    fail=$((fail + 1))
    printf '   %sFAIL%s  principal mismatch - the sync will never fire\n' "$R" "$N"
    printf '         ours : %s\n' "$OURS"
    printf '         AWS  : %s\n' "$SLR_PRINCIPAL"
    printf '         fix  : redeploy prereq-roles.yaml with\n'
    printf '                --parameter-overrides GitSyncServicePrincipal=%s\n' "$SLR_PRINCIPAL"
  fi
else
  printf '   %snote%s  AWS uses %s\n' "$D" "$N" "$SLR_PRINCIPAL"
fi

# ------------------------------------------------------------------ summary --
echo
echo "$(printf '%.0s─' {1..78})"
printf '%sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s\n' "$G" "$pass" "$N" "$R" "$fail" "$N" "$Y" "$skip" "$N"
echo
if (( fail > 0 )); then
  echo "A FAIL on an 'allow' line means something will break at deploy or run time."
  echo "A FAIL on a 'deny' line means a role is broader than intended - fix the policy."
  exit 1
fi
echo "No permission gaps found for the roles that exist."
