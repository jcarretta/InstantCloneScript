<#
    .NOTES
    ===========================================================================
     Author:        Jesse Carretta
     Date:          May 12, 2020
     Organization:  Dell Technologies
     LinkedIn :     jesse-carretta-427730137
    ===========================================================================
    ===========================================================================
    .SYNOPSIS
        Instant Clone feature of VMware vSphere
    .DESCRIPTION
        Uses Instant Clone feature to Clone a Master VM - Then Rename and add to a Domain.
        Written to support Windows XP VMs.  The Number of clones is configurable.  Basic customization
        
    .NOTES
        Requirements
        - VMWare vSphere 6.7
        - PowerCLI 10.1 or later
    .RIGHTS AND USAGE
        Permission is hereby granted, free of charge, to any person obtaining a copy of this script to use, modify, or distribute without restriction.
        THE SCRIPT IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
        IN NO EVENT SHALL THE AUTHOR OR HIS COMPANY BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
        SCRIPT OR THE USE OR OTHER DEALINGS IN THE SCRIPT.
#>


#--- User Defined Variables --------------------------------------------------------------------
#---------------------------------------------------------------------------------------------

$VCserver      = "VCenter"
$VCadmin       = "administrator@vsphere.local"
$VCpassword    = "Password123!"
$domainName    = "domain.local"
$domainAdmin   = "DomainAdmin"
$domainPass    = "DomainPass"
$OUContainer   = "OU=Clones,DC=domain,DC=local"
$adminUser     = "tempuser"
$adminPassword = "password1"
$vmTemplate    = "WINXP-GOLD"
$cloneCount    = 10
$BatchLimit    = 10
$clonePrefix   = "InstaClone"
#$ip_Subnet     = "192.168.30."
#$ip_HostStart  = 50
#$ip_Netmask    = "255.255.255.0"
#$ip_MaskLength = 24
#$ip_Gateway    = "192.168.30.1"
#$ip_DNS        = "192.168.30.10, 192.168.30.11"

#-------------- Install PowerCLI (Only Needs to be run once) -----------------
#Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
#Install-Module -Name VMware.PowerCLI -RequiredVersion 11.5.0.14912921 -Force

#----------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------
#---Do Not Edit Below--------------
#----------------------------------

#--- OBJECT DEFINITIONS --------------------------------------------------------------------
#---------------------------------------------------------------------------------------------
class Clone {
    [string]$Name
    [string]$IPAddress
    [string]$SubnetMask
    [string]$DefaultGateway
    [string]$Description
    [string]$CloneTaskID
    [int]   $Progress = 0
    [boolean]$Created = $false
    [boolean]$Renamed = $false
    [boolean]$NamesMatch = $false
    [boolean]$JoinedToDomain =$false
    [boolean]$ToolsRunning =$false;
}


#--- FUNCTION DEFINITIONS --------------------------------------------------------------------
#---------------------------------------------------------------------------------------------
Function Rename-XPComputer() #--- Defines Local script to run inside VM for customization
{
    param([Parameter(Mandatory=$true)] [String]$NewName,
          [Parameter(Mandatory=$true)] [VMware.VimAutomation.Types.VirtualMachine]$VM 
    )
    
    $script = 
    "(Get-WmiObject Win32_ComputerSystem).Rename(`"$NewName`")   
    Restart-Computer -Force"
    Write-Host -ForegroundColor DarkYellow "Polling $VM for running VM Tools"
    Wait-Tools -VM $VM -TimeoutSeconds 30 | Out-Null
    Invoke-VMScript -VM $VM -GuestUser $adminUser -GuestPassword $adminPassword -ScriptType Powershell -ScriptText $script -RunAsync -WarningAction SilentlyContinue | Out-Null 
    Write-Host -ForegroundColor DarkYellow "**---Invoking Rename Script in Guest OS of VM $VM---**"
    
}
Function Join-Domain() #--- Defines Local script to run inside VM for customization
{
    param(
        [Parameter(Mandatory=$false)] [String]$Name,
        [Parameter(Mandatory=$true)] [VMware.VimAutomation.Types.VirtualMachine]$VM,
        [Parameter(Mandatory=$false)] [PSCredential]$Credential,
        [Parameter(Mandatory=$true)] [String]$Domain,
        [Parameter(Mandatory=$false)] [String]$OU="OU=Computers"
    )
    if($Credential -EQ $null)
    {$Credential = Get-DomainCredentials}

    $admin = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password   
    $creds = "New-Object System.Management.Automation.PSCredential $admin, (ConvertTo-SecureString -String $pass -AsPlainText -Force)"
    $script = 
    "`$joinCreds = $creds
    Add-Computer -DomainName $Domain -Credential `$joinCreds -OUPath `"$OU`"
    Restart-Computer -Force"

    Write-Host -ForegroundColor DarkYellow "Polling $VM for running VM Tools"
    Wait-Tools -VM $VM -TimeoutSeconds 30 | Out-Null
    Invoke-VMScript -VM $VM -GuestUser $adminUser -GuestPassword $adminPassword -ScriptType Powershell -ScriptText $script -RunAsync -WarningAction SilentlyContinue | Out-Null 
    Write-Host -ForegroundColor DarkYellow "**---Invoking Domain Join Script in Guest OS of VM $VM---**"

}
Function New-InstantClone() #--- Function handling the Clone Process
{
    param(
        [Parameter(Mandatory=$true)] [String]$SourceVM,
        [Parameter(Mandatory=$true)] [String]$DestinationVM,
        [Parameter(Mandatory=$false)][Switch]$FreezeParent)
        
    #Get Source VM details
    $source = Get-VM $SourceVM
    $sourceNIC = $source | Get-NetworkAdapter 
    
    #--- SourceVM must be a Powered On VM
    if($source.PowerState -NE "PoweredOn") {
        Write-Host -ForegroundColor Red "Source VM must be in state: PoweredOn"
        break
    }
        
    #Set change details for Clone VM ("Relocate Specifications")
    $locationSpec = New-Object VMware.Vim.VirtualMachineRelocateSpec
    #$locationSpec.Datastore 
    #$locationSpec.Folder 
    #$locationSpec.Pool
    
    #Set Clone VM details
    $cloneSpec = New-Object VMware.Vim.VirtualMachineInstantCloneSpec
    $cloneSpec.Name = $DestinationVM
    $cloneSpec.Location = $locationSpec
    
    #Freeze Master VM
    if($FreezeParent -and -not($source.ExtensionData.Runtime.InstantCloneFrozen) )
    {
        $freezeScript = "`"C:\Program Files\VMware\VMware Tools\vmtoolsd.exe`" --cmd `"instantclone.freeze`" "
        Invoke-VMScript -VM $source -GuestUser $adminUser -GuestPassword $adminPassword -ScriptType Bat -ScriptText $freezeScript -RunAsync
    }  

    #Create Clone
    Write-Host "Creating Instant Clone $DestinationVM ..."
    $task = $source.ExtensionData.InstantClone_Task($cloneSpec)
    $taskid = "Task-$($task.value)"
    $task = Get-Task -Id $taskid
    return $task
    $task | Wait-Task | Out-Null
    <# Removes and Re-Adds vNIC
    $clone = Get-VM $DestinationVM 
    $nic = $clone | Get-NetworkAdapter
    
    #Set configuration Spec to Remove Network Adapters
    $deviceConfigSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $deviceConfigSpec.Device = $sourceNIC.ExtensionData
    $deviceConfigSpec.Operation = "remove"
    $vmSpec = New-Object VMware.Vim.VirtualMachineConfigSpec 
    $vmSpec.DeviceChange = $deviceConfigSpec
    #Remove Original Network Adapter
    $clone.ExtensionData.ReconfigVM($vmSpec)
    #Add a New vNetwork Adapter
    $clone | New-NetworkAdapter -NetworkName $nic.NetworkName -StartConnected -Type Vmxnet3 -WakeOnLan  -Confirm:$false
    #>
}
Function Get-DomainCredentials() #--- Get Domain Admin Credentials from operator - For Domain Joins
{
    $creds = Get-Credential -Message "Enter Domain Admin Credentials"
       
    #--Alternatively user/pwd could be stored in the script here - Not recommended
    #$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $domainAdmin, (ConvertTo-SecureString -String $domainPass -AsPlainText -Force)
    $creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "testlab\administrator", (ConvertTo-SecureString -String "Password123!" -AsPlainText -Force)
    return $creds
}
Function Check-CreationStatus()
{
    #Check the Status of clones creation process
    $list1 = $newClonesList | Where-Object {$_.CloneTaskID -NE $null -and (-NOT $_.Created)} 
    $list2 = $newClonesList | Where-Object {(-NOT $_.Renamed)} 

    $list1 | ForEach-Object{
        $task = (Get-Task -Id $_.CloneTaskID)
        $status = $task.State 
        $_.Progress = (Get-Task -Id $_.CloneTaskID).PercentComplete
        if($status -EQ "Success")
        {
            $_.Created = $true
        }
    }
    
    $list2 | ForEach-Object{
        if($_.Created){
            Rename-XPComputer -VM (Get-VM $_.Name) -NewName $_.Name    #Rename OS Computer Name and Reboot
            $_.Renamed = $true
        }
    }
}
Function Check-RenameStatus()
{
    #Check the Status of clones that have been renamed
    $renamedList = $newClonesList | Where-Object {$_.Renamed -EQ $true -and $_.JoinedToDomain -eq $false}
    $renamedList | ForEach-Object {
        #Check to see if clone is ready to Join to Domain
        $vm = Get-VM $_.Name
        $_.ToolsRunning = ($vm.Guest.ExtensionData.ToolsRunningStatus -EQ "guestToolsRunning")
        $_.NamesMatch = ($vm.Guest.HostName -EQ $vm.Name)
        $ready = ($_.ToolsRunning -and $_.NamesMatch)
        if($ready)
        {
            Join-Domain -VM $vm -Credential $domainCreds -Domain $domainName -OU $OUContainer
            $_.JoinedToDomain = $true
        }
    }
}
Function Sleep-Write($secs)
{
    for($i=0; $i -lt $secs; $i++)
    {
        sleep 1
        Write-Host "." -NoNewline -ForegroundColor DarkGreen -BackgroundColor White
    }
    Write-Host "." -ForegroundColor DarkGreen -BackgroundColor White
    CLS
}


#--- MAIN SCRIPT --------------------------------------------------------------------
#---------------------------------------------------------------------------------------------

$domainCreds = Get-DomainCredentials  # !!Gets credentials but does not error handle for bad user/password

#-------------- Connect to VCenter Server -----------------------------------
Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $false -InvalidCertificateAction Ignore -Confirm:$false
Connect-VIServer -server $VCserver -user $VCadmin -password $VCpassword

#--- Mark Start ---
$StartTime = Get-Date
Write-Host -ForegroundColor Cyan "Starting Instant Clone Process at $StartTime
$cloneCount Clones Scheduled"


#--- Create Instant Clone list ---
[Clone[]]$newClonesList = @()
For ($i=1; $i -le $cloneCount ; $i++) #--Loop based on Number of Clones needed
{
    #---Name Calc
    $newVMName = $clonePrefix + "-" + $i
    
    #---IP Calc---  (Not Currently Needed)
    $ip_HostNumber =  $ip_HostStart + $i
    $ip_Address = $ip_Subnet + $ip_HostNumber
    
    
    [Clone]$newclone = @{Name=$newVMName;IPAddress=$ip_Address;SubnetMask=$ip_Netmask;DefaultGateway=$ip_Gateway;}
    $newClonesList += $newclone
}


#--- Create Instant Clones and Rename their OS Computer Names and join to Domain ---
$completed = $false
$i = 0
while(-NOT $completed )
{
    $clonesRemaining = $newClonesList | Where-Object {(-NOT $_.Created) -AND (-NOT $_.CloneTaskID)}
    $currentQueue = $newClonesList | Where-Object {(-NOT $_.Created) -AND ($_.CloneTaskID)}
    $batchCount = $BatchLimit - $currentQueue.Count 
    if($batchCount -GT $clonesRemaining.Count)
    {
        $batchCount = $clonesRemaining.Count
    }
    
    #---Create next batch of clones
    for($j=1; $j -le $batchCount; $j++)
    {
        $clone = $newClonesList[$i]
        $task = New-InstantClone -SourceVM $vmTemplate -DestinationVM $clone.Name  -FreezeParent
        $clone.CloneTaskID = $task.ID
        $i++
    }
    

    #---Check Status and perform Rename/Join operations
    Check-CreationStatus #--Check Progress on Clone Creation and Rename Computer
    Check-RenameStatus #--Check for renamed Clones and Join to Domain    
    
    #---Check if Job completed
    $completed   = -NOT ($newClonesList | Where-Object {(-NOT $_.JoinedToDomain)}).Count

    #---Continually Output Status to screen
    if(($newClonesList | Where-Object {(-NOT $_.Created)}).Count)
    {
        Write-Host "Currently Creating Clones:"
        $currentQueue | Select-Object Name, Created, Renamed, Clonetaskid, Progress | ft
        Write-Host "Processing batch." -NoNewline -ForegroundColor DarkGreen -BackgroundColor White
    }else{Write-Host "Renaming Machines and Joining to domain" -NoNewline -ForegroundColor DarkGreen -BackgroundColor White}
    Sleep-Write(5)
}


#---Close Out and Log details---
$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)
Write-Host -ForegroundColor Cyan  "`nStartTime: $StartTime"
Write-Host -ForegroundColor Cyan  "  EndTime: $EndTime"
Write-Host -ForegroundColor Green " Duration: $duration minutes"

Disconnect-VIServer -Confirm:$false