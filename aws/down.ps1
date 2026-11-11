# Derruba o store do EKS (us-east-2), na ordem inversa do up.ps1:
#   1) apaga o Service "gateway" (LoadBalancer): o ELB e criado pelo Kubernetes, fora do
#      CloudFormation, e prende a VPC se ficar para tras
#   2) apaga as stacks: RDS -> cluster EKS/node group -> IAM -> VPC (NAT Gateways)
#
# So toca nas stacks "eks-store-*" criadas pelo up.ps1 (tag project=store-pma).
# NUNCA apaga recursos fora delas (ex.: a EC2 "lastro" em us-east-1).
# Uso (na raiz do store-pma):  .\aws\down.ps1      Tempo: ~20 min.
param(
    [string]$AwsProfile = 'grupo05',
    [string]$Region     = 'us-east-2'
)
$ErrorActionPreference = 'Stop'
$aws = @('--profile', $AwsProfile, '--region', $Region)

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function StackExists($stack) {
    # stack inexistente = erro "does not exist" do aws cli; no PowerShell 5.1 o stderr de um .exe
    # vira excecao com ErrorActionPreference=Stop, entao relaxa so aqui dentro.
    # Qualquer OUTRO erro (token expirado, throttling...) para o script: nunca assumir "nao existe".
    $ErrorActionPreference = 'Continue'
    $out = aws cloudformation describe-stacks @aws --stack-name $stack --query 'Stacks[0].StackStatus' --output text 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    if ("$out" -match 'does not exist') { return $false }
    throw "erro ao consultar a stack ${stack}: $out"
}

aws sts get-caller-identity @aws --query Account --output text | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'sem sessao AWS: rode "aws sso login --profile grupo05"' }

# 1) LoadBalancer do gateway (so se o cluster ainda existir)
if (StackExists 'eks-store-cluster') {
    Step 'apagando o Service gateway (LoadBalancer)'
    aws eks update-kubeconfig @aws --name eks-store --alias eks-store | Out-Null
    kubectl --context eks-store delete svc gateway --ignore-not-found --wait=true
    # da tempo de a AWS remover o ELB e as interfaces de rede dele
    Start-Sleep 60
}

# 2) stacks em ordem inversa
foreach ($stack in 'eks-store-rds', 'eks-store-cluster', 'eks-store-iam', 'eks-store-vpc') {
    if (StackExists $stack) {
        Step "apagando stack $stack"
        aws cloudformation delete-stack @aws --stack-name $stack
        aws cloudformation wait stack-delete-complete @aws --stack-name $stack
        if ($LASTEXITCODE -ne 0) { throw "falha ao apagar $stack (veja os eventos no console do CloudFormation)" }
    } else {
        Step "stack $stack nao existe (ok)"
    }
}

$ErrorActionPreference = 'Continue'
kubectl config delete-context eks-store 2>&1 | Out-Null
Write-Host 'OK: tudo do store-pma em us-east-2 foi apagado.' -ForegroundColor Green
