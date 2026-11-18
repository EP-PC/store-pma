# Builda os jars que os Dockerfiles copiam (target/*.jar), na ordem dos hands-on:
#   1) contratos: mvn install (vão para o ~/.m2, de onde os services os resolvem)
#   2) services:  mvn package (geram target/*.jar)
# Diferenças em relação ao "mvn clean ..." dos hands-on:
#   - sem "clean": o OneDrive pode travar a pasta target/
#   - -DskipTests: como nos Jenkinsfiles; os testes rodam no repo de cada serviço
# Uso (de dentro de api/):  .\build.ps1   e depois   docker compose up --build -d
$ErrorActionPreference = 'Stop'

# mvn do PATH; senão, o Maven local em ~\tools
$mvn = (Get-Command mvn -ErrorAction SilentlyContinue).Source
if (-not $mvn) { $mvn = "$env:USERPROFILE\tools\apache-maven-3.9.11\bin\mvn.cmd" }

$contratos = 'product', 'account', 'order'
$services  = 'product-service', 'account-service', 'auth-service', 'order-service', 'gateway-service'

function Build($dir, $goal) {
    Write-Host "==> $dir ($goal)" -ForegroundColor Cyan
    Push-Location "$PSScriptRoot\$dir"
    try {
        & $mvn -B -q -DskipTests $goal
        if ($LASTEXITCODE -ne 0) { throw "falhou: $dir" }
    } finally { Pop-Location }
}

$contratos | ForEach-Object { Build $_ 'install' }
$services  | ForEach-Object { Build $_ 'package' }
Write-Host "OK: jars gerados. Agora: docker compose up --build -d" -ForegroundColor Green
