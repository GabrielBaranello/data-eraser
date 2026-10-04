# 1. FORZAR ARQUITECTURA DE 64 BITS Y PERMISOS DE ADMINISTRADOR
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$is64BitPs = [Environment]::Is64BitProcess

if (-not $isAdmin -or -not $is64BitPs) {
    Write-Host "[INFO] Redireccionando a entorno nativo de 64 bits con privilegios..." -ForegroundColor Cyan
    # Busca la ruta real de PowerShell de 64 bits evadiendo la redirección x86
    $psPath = if (Test-Path "env:windir\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
        "$env:windir\SysNative\WindowsPowerShell\v1.0\powershell.exe"
    } else {
        "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    
    Start-Process -FilePath $psPath -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# Establecer la carpeta local como el directorio activo de trabajo
Set-Location -Path $PSScriptRoot

# Forzar la ruta nativa del sistema para herramientas de arranque
$Sys64 = if (Test-Path "env:windir\SysNative") { "$env:windir\SysNative" } else { "$env:windir\System32" }
$BcdCmd = "$Sys64\bcdedit.exe"
cl
Write-Host "============================================================" -ForegroundColor Green
Write-Host "   INSTALADOR PORTABLE: CONFIGURACION INTEGRAL DE ARRANQUE  " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

# 2. VERIFICACIÓN CRÍTICA DEL DISCO
Write-Host "[0/5] Comprobando SecurityStatus de los discos fisicos..." -ForegroundColor White
try {
    $disks = Get-PhysicalDisk | Get-StorageDiagnosticInfo -StorageDiagnosticInfoTypes PhysicalDiskPhysicalTopology | Select-Object -ExpandProperty PhysicalDiskPhysicalTopology
    statusList = disks.SecurityStatus
    if (statusList -contains 2 -or statusList -contains 3) {
        Write-Host "`n[ERROR CRITICO] Estado de seguridad de disco no compatible (Valor 2 o 3)." -ForegroundColor Red
        Write-Host "La instalacion se ha cancelado por proteccion de hardware." -ForegroundColor Yellow
        Read-Host "Presiona Enter para salir..."
        Exit
    }
    Write-Host "[OK] Almacenamiento compatible." -ForegroundColor Green
} catch {
    Write-Host "[INFO] Omitiendo verificacion avanzada de topologia de disco." -ForegroundColor Yellow
}

# 3. Validar archivos locales requeridos
if (-not (Test-Path "signtool.exe") -or -not (Test-Path "ejecutable.efi")) {
    Write-Host "[ERROR] No se encontraron 'signtool.exe' o 'ejecutable.efi' en esta carpeta." -ForegroundColor Red
    Read-Host "Presiona Enter para salir..."
    Exit
}

# 4. Descarga de binarios desde Servidores Oficiales de Ubuntu (Launchpad)
Write-Host "[1/5] Descargando componentes Shim de Canonical..." -ForegroundColor White
$shimUrl = "https://launchpad.net"
$mmUrl = "https://launchpad.net"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $shimUrl -OutFile "shimx64.efi" -UseBasicParsing
Invoke-WebRequest -Uri $mmUrl -OutFile "mmx64.efi" -UseBasicParsing

# 5. Criptografía y Firmado Digital Portable
Write-Host "[2/5] Generando llaves criptograficas MOK..." -ForegroundColor White
$cert = New-SelfSignedCertificate -DnsName "MiFirmaMOK" -Type CodeSigning -CertStoreLocation Cert:\CurrentUser\My
$pwd = ConvertTo-SecureString -String "1234" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath "clave_privada.pfx" -Password $pwd | Out-Null
Export-Certificate -Cert $cert -FilePath "certificado_publico.cer" | Out-Null

Write-Host "[3/5] Firmando digitalmente tu ejecutable.efi..." -ForegroundColor White
# Estructurar el comando en una sola cadena de texto absoluta para evitar fallos de parámetros
$cmdSign = ".\\signtool.exe sign /f .\clave_privada.pfx /p 1234 /fd sha256 .\ejecutable.efi"
Invoke-Expression $cmdSign | Out-Null


# 6. Despliegue en la partición oculta UEFI
Write-Host "[4/5] Escribiendo binarios en la particion oculta UEFI..." -ForegroundColor White
& "mountvol.exe" Z: /s
$UefiDir = "Z:\EFI\MiPrograma"
New-Item -Path $UefiDir -ItemType Directory -Force | Out-Null

Copy-Item -Path "shimx64.efi" -Destination "$UefiDir\bootx64.efi" -Force
Copy-Item -Path "mmx64.efi" -Destination "$UefiDir\mmx64.efi" -Force
Copy-Item -Path "ejecutable.efi" -Destination "$UefiDir\grubx64.efi" -Force
Copy-Item -Path "ejecutable.efi" -Destination "$UefiDir\fbx64.efi" -Force
Copy-Item -Path "certificado_publico.cer" -Destination "$UefiDir\certificado_publico.cer" -Force

# 7. Registrar entrada persistente en el almacén NVRAM de la UEFI
Write-Host "[5/5] Registrando identificador unico en el firmware..." -ForegroundColor White
$bcdOutput = & $BcdCmd /create /d "Ejecucion Temporal UEFI" /application bootapp
if ($bcdOutput -match '\{([^}]+)\}') { $myGuid = "{$($Matches[1])}" } else { $myGuid = "{00000000-0000-0000-0000-000000000000}" }
& $BcdCmd /set $myGuid device partition=Z: | Out-Null
& $BcdCmd /set $myGuid path \EFI\MiPrograma\bootx64.efi | Out-Null
# Primero se agrega el gestor de arranque al inicio de la lista de visualización
& $BcdCmd /displayorder {bootmgr} /addfirst | Out-Null
# Luego se asegura que el dispositivo apunte correctamente a la unidad Z:
& $BcdCmd /set {bootmgr} device partition=Z: | Out-Null
& "$Sys64\mountvol.exe" Z: /d

# 8. Limpieza absoluta de rastros criptográficos en Windows
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -like "*MiFirmaMOK*" } | Remove-Item
Remove-Item -Path "clave_privada.pfx", "certificado_publico.cer", "shimx64.efi", "mmx64.efi" -Force -ErrorAction SilentlyContinue

# 9. CREAR EL DISPARADOR LIVIANO EN EL ESCRITORIO REAL DEL USUARIO
# Detecta la ruta exacta del escritorio interactivo (incluso si está modificado a D:\)
$regEscritorio = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders").Desktop
$escritorioReal = [System.Environment]::ExpandEnvironmentVariables($regEscritorio)
$disparadorPath = Join-Path -Path $escritorioReal -ChildPath "Apagar_y_Saltar.bat"

$disparadorContent = @"
@echo off
whoami /groups | findstr /b /c:"S-1-5-32-544 " >nul 2>&1
if %errorlevel% neq 0 ( powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b )
$Sys64\bcdedit.exe /set {fwbootmgr} displayorder {bootmgr} /addfirst >nul
$Sys64\bcdedit.exe /bootsequence $myGuid >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d "0" /f >nul
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d "1" /f >nul
shutdown /s /f /t 0
"@
Set-Content -Path $disparadorPath -Value $disparadorContent -Force

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "   INSTALACION COMPLETADA. REINICIANDO HACIA LA UEFI...     " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green

& $BcdCmd /bootsequence myGuid | Out-Null
Start-Sleep -Seconds 50

# Autodestruirse y reiniciar la laptop de inmediato
Remove-Item -Path \$PSCommandPath -Force -ErrorAction SilentlyContinue
#Restart-Computer -Force
