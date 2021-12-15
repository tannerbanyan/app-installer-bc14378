# Run as administrator

$INVITE_CODE=$args[0]
$DEPLOYMENT_KEY=$args[1]
$APP_VERSION=$args[2]

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (! $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be with admin privilege"   
    exit 1
}

if (!$INVITE_CODE -or !$DEPLOYMENT_KEY) {
    Write-Host "Usage: "
    Write-Host "$PSCommandPath <INVITE_CODE> <DEPLOYMENT_KEY> <APP_VERSION (optional>"   
    exit 1
}

if (!$APP_VERSION) {
    Write-Host "Checking for latest version of app"
    $res = Invoke-WebRequest "https://www.banyanops.com/app/windows/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing
    $loc = $res.Headers.Location
    $match = select-string "Banyan-Setup-(.*).exe" -inputobject $loc
    $APP_VERSION = $match.matches.groups[1].value
}

Write-Host "Installing with invite code: $INVITE_CODE"
Write-Host "Installing using deploy key: $DEPLOYMENT_KEY"
Write-Host "Installing app version: $APP_VERSION"

$logged_on_user = Get-WMIObject -class Win32_ComputerSystem | Select-Object -expand UserName
Write-Host "Installing app for user: $logged_on_user"

$global_profile_dir = "C:\ProgramData"


function create_config() {
    Write-Host "Creating mdm-config json file"

    $banyan_dir_name = "Banyan"
    $global_config_dir = $global_profile_dir + "\" + $banyan_dir_name
    $global_config_file = $global_config_dir + "\" + "mdm-config.json"

    $deploy_user = ""
    $deploy_email = ""

    # get user and email assuming device is joined to an Azure AD domain
    # https://nerdymishka.com/articles/azure-ad-domain-join-registry-keys/
    $intune_info = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
    if (Test-Path $intune_info) {
        Write-Host "Intune deployment - extracting user email"
        $ADJoinInfo = Get-ChildItem -path $intune_info
        $ADJoinInfo = $ADJoinInfo -replace "HKEY_LOCAL_MACHINE","HKLM:"
        $ADJoinUser = Get-ItemProperty -Path $ADJoinInfo
        $deploy_email = $ADJoinUser.UserEmail
        $deploy_user = $intune_email.Split("@")[0]
        Write-Host "Intune deployment - found user - $intune_email, $intune_user"
    }

    $json = [pscustomobject]@{ 
        mdm_invite_code = $INVITE_CODE
        mdm_deploy_user = $deploy_user
        mdm_deploy_email = $deploy_email 
        mdm_device_ownership = "C"
        mdm_present = $true
        mdm_vendor_name = "Intune"
        mdm_start_at_boot = $true
        mdm_hide_on_start = $true  

    } | ConvertTo-Json

    New-Item -Path $global_profile_dir -Name $banyan_dir_name -ItemType "directory" -Force
    Set-Content -Path $global_config_file -Value $json -NoNewLine
}


function download_extract() {
    Write-Host "Downloading installer EXE"    

    $tmp_dir_name = "banyantemp"
    $tmp_dir = $global_profile_dir + "\" + $tmp_dir_name

    New-Item -Path $global_profile_dir -Name $tmp_dir_name -ItemType "directory" -Force

    $dl_file = $tmp_dir + "\" + "Banyan-Setup-$APP_VERSION.exe"

    if (Test-Path $dl_file -PathType leaf) {
        Write-Host "Installer EXE already downloaded"    
    } else {
        $progressPreference = 'silentlyContinue'
        Invoke-Webrequest "https://www.banyanops.com/app/releases/Banyan-Setup-$APP_VERSION.exe" -outfile $dl_file -UseBasicParsing
        $progressPreference = 'Continue'
    }

    # Install
    Start-Process -FilePath $dl_file -ArgumentList "/S" -Wait
}


function stage() {
    Write-Host "Running staged deployment"
    Start-Process -FilePath "C:\Program Files\Banyan\Banyan.exe" -ArgumentList "--staged-deploy-key=$DEPLOYMENT_KEY" -Wait
    Write-Host "Staged deployment done. Have the logged_on_user start the Banyan app to complete registration."
}


function set_scheduled_task() {
    Write-Host "Creating ScheduledTask for logged_on_user, so app launches upon next user login"    
    $action = New-ScheduledTaskAction -Execute "C:\Program Files\Banyan\Banyan.exe"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $logged_on_user
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal
    Register-ScheduledTask StartBanyan -InputObject $task
}


function start_app() {
    Write-Host "Starting the Banyan app as logged_on_user"
    Start-ScheduledTask -TaskName StartBanyan   
    Start-Sleep -Seconds 5     
}


function stop_app() {
    Write-Host "Stopping Banyan app"
    Stop-Process -Name Banyan -Force
}


create_config
download_extract
stage
set_scheduled_task
start_app
