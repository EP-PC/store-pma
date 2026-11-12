# Sobe o store no EKS (us-east-2), do zero, com um comando:
#   1) stacks CloudFormation: VPC (template do professor) -> IAM -> cluster EKS + node group -> RDS
#   2) kubeconfig (contexto "eks-store")
#   3) ConfigMap/Secrets no cluster (RDS + segredos do api/.env, nunca do Git)
#   4) os 4 servicos (k8s/k8s.yaml de cada submodulo) e a URL publica do gateway
#
# Pre-requisitos: AWS CLI v2 + "aws sso login --profile grupo05"; kubectl; api/.env preenchido
# (JWT_SECRET_KEY, ACCOUNT_ADMIN_EMAIL, ACCOUNT_ADMIN_HASH). A senha do RDS fica em aws/.env
# (gerada aqui na primeira vez; ignorado pelo Git).
# Uso (na raiz do store-pma):  .\aws\up.ps1        Tempo: ~30 min (o EKS demora ~15).
# Custo: ~US$ 0,33/h enquanto estiver de pe. Derrubar com .\aws\down.ps1
param(
    [string]$AwsProfile = 'grupo05',
    [string]$Region     = 'us-east-2'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$aws  = @('--profile', $AwsProfile, '--region', $Region)
$tags = @('--tags', 'project=store-pma')

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Check() { if ($LASTEXITCODE -ne 0) { throw "comando falhou (exit $LASTEXITCODE)" } }
function Output($stack, $key) {
    aws cloudformation describe-stacks @aws --stack-name $stack `
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text
}
function EnvValue($file, $key) {
    $line = Get-Content $file | Where-Object { $_ -like "$key=*" } | Select-Object -First 1
    if (-not $line) { throw "faltou $key em $file" }
    ($line -replace "^$key=", '').Trim()
}
function Deploy($stack, $template, [string[]]$extra) {
    Step "stack $stack"
    # --no-fail-on-empty-changeset: rodar de novo com a stack igual nao e erro (script idempotente)
    aws cloudformation deploy @aws --stack-name $stack --template-file "$PSScriptRoot\$template" `
        --no-fail-on-empty-changeset @tags @extra
    Check
}

aws sts get-caller-identity @aws --query Account --output text | Out-Null; Check

# senha do RDS (so local)
$envAws = "$PSScriptRoot\.env"
if (-not (Test-Path $envAws)) {
    # 24 caracteres alfanumericos aleatorios (RNG criptografico; funciona no PowerShell 5.1)
    $chars = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    Set-Content -Path $envAws -Encoding utf8 -Value "# Segredos locais da infra AWS (fora do Git)`nDB_PASSWORD=$pw"
}
$dbPassword = EnvValue $envAws 'DB_PASSWORD'

# 1) infraestrutura
Deploy 'eks-store-vpc' 'amazon-eks-vpc-private-subnets.yaml'
Deploy 'eks-store-iam' 'iam.yaml' @('--capabilities', 'CAPABILITY_IAM')

$vpc     = Output 'eks-store-vpc' 'VpcId'
$subnets = Output 'eks-store-vpc' 'SubnetIds'          # publica1,publica2,privada1,privada2
$private = ($subnets -split ',')[2, 3] -join ','
$cpSg    = Output 'eks-store-vpc' 'SecurityGroups'
Deploy 'eks-store-cluster' 'eks.yaml' @('--parameter-overrides',
    "ClusterRoleArn=$(Output 'eks-store-iam' 'ClusterRoleArn')",
    "NodeRoleArn=$(Output 'eks-store-iam' 'NodeRoleArn')",
    "SubnetIds=$subnets", "PrivateSubnetIds=$private", "ControlPlaneSecurityGroup=$cpSg")

Deploy 'eks-store-rds' 'rds.yaml' @('--parameter-overrides',
    "VpcId=$vpc", "PrivateSubnetIds=$private",
    "ClusterSecurityGroupId=$(Output 'eks-store-cluster' 'ClusterSecurityGroupId')",
    "DBPassword=$dbPassword")
$dbHost = Output 'eks-store-rds' 'DBEndpoint'

# acesso do Jenkins ao cluster (so se o usuario IAM permanente store-jenkins ja existir;
# ele e criado uma vez com aws/jenkins-iam.yaml, stack eks-store-jenkins-iam)
$ErrorActionPreference = 'Continue'
$jenkinsArn = aws cloudformation describe-stacks @aws --stack-name eks-store-jenkins-iam `
    --query 'Stacks[0].Outputs[0].OutputValue' --output text 2>&1
$jenkinsOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if ($jenkinsOk) {
    Deploy 'eks-store-jenkins-access' 'jenkins-access.yaml' @('--parameter-overrides', "JenkinsUserArn=$jenkinsArn")
} else {
    Step 'stack eks-store-jenkins-iam nao existe: pulando o acesso do Jenkins (deploy pelo Jenkins nao vai funcionar)'
}

# 2) kubectl
Step 'kubeconfig (contexto eks-store)'
aws eks update-kubeconfig @aws --name eks-store --alias eks-store | Out-Null; Check
$k = @('--context', 'eks-store')

# 3) ConfigMap/Secrets (create --dry-run | apply = idempotente; valores nao aparecem na tela)
Step 'ConfigMap e Secrets'
$envApi = "$root\api\.env"
function Apply-Yaml([string[]]$createArgs) {
    $yaml = kubectl @k create @createArgs --dry-run=client -o yaml; Check
    $yaml | kubectl @k apply -f - | Out-Null; Check
}
Apply-Yaml @('configmap', 'postgres-configmap', "--from-literal=POSTGRES_HOST=$dbHost", '--from-literal=POSTGRES_DB=store')
Apply-Yaml @('secret', 'generic', 'postgres-secrets', '--from-literal=POSTGRES_USER=store', "--from-literal=POSTGRES_PASSWORD=$dbPassword")
Apply-Yaml @('secret', 'generic', 'account-secrets',
    "--from-literal=ACCOUNT_ADMIN_EMAIL=$(EnvValue $envApi 'ACCOUNT_ADMIN_EMAIL')",
    "--from-literal=ACCOUNT_ADMIN_HASH=$(EnvValue $envApi 'ACCOUNT_ADMIN_HASH')")
Apply-Yaml @('secret', 'generic', 'auth-secrets', "--from-literal=JWT_SECRET_KEY=$(EnvValue $envApi 'JWT_SECRET_KEY')")

# 4) servicos
foreach ($s in 'account-service', 'auth-service', 'product-service', 'gateway-service') {
    Step "deploy $s"
    kubectl @k apply -f "$root\api\$s\k8s\k8s.yaml"; Check
}
foreach ($d in 'account', 'auth', 'product', 'gateway') {
    kubectl @k rollout status "deploy/$d" --timeout=600s; Check
}

Step 'URL publica do gateway'
$lb = ''
for ($i = 0; $i -lt 60 -and -not $lb; $i++) {
    $lb = kubectl @k get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    if (-not $lb) { Start-Sleep 5 }
}
kubectl @k get pods,svc
Write-Host "OK: http://${lb}:8080/products  (o DNS pode levar 1-2 min)" -ForegroundColor Green
