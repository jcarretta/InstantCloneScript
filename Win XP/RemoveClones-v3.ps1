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
        Instant Clone feature of VMware vSphere - Removal Script
    .DESCRIPTION
        Powers off and Deletes VMs from Disk.  Uses a Prefix to identify VMs to destroy.
        WARNING!!!!  This Script is destructive.  Use great care when running this script
                     and pay close attention to the $clonePrefix Variable
        
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

$VCserver     = "VCenter"
$adminUser    = "administrator@vsphere.local"
$password     = "Password123"
$clonePrefix  = "InstaClone"
$vmTemplate   = "WINXP-GOLD"




#--- FUNCTION DEFINITIONS --------------------------------------------------------------------
#---------------------------------------------------------------------------------------------
Function Cleanup-Deltas() #--- Cleanup Delta disks from previous Instant Clone operations
{
    param( [Parameter(Mandatory=$true)][String]$Name)
    Write-Host -ForegroundColor Yellow "Performing Cleanup of Instant Clone Delta disks"
    $vm = Get-VM $Name
    $vm | New-Snapshot -Name "Cleanup_Snap" -Description "This Snapshot will be created and then immediately deleted to consolidate leftover delta disks."
    $vm | Get-Snapshot -Name "Cleanup_Snap" | Remove-Snapshot -RemoveChildren -Confirm:$false
    Write-Host -ForegroundColor Cyan "Cleanup process complete"
}



#Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
#Install-Module -Name VMware.PowerCLI -RequiredVersion 11.5.0.14912921 -Force

Set-PowerCLIConfiguration -Scope User -ParticipateInCeip $false -InvalidCertificateAction Ignore -Confirm:$false
Connect-VIServer -server $VCserver -user $adminUser -password $password

$StartTime = Get-Date
Write-Host -ForegroundColor Cyan "Starting Tear-Down Process at " $StartTime

$vms = Get-VM -Name "$clonePrefix*" 
$vms | Stop-VM -Confirm:$false | Remove-VM -DeleteFromDisk -Confirm:$false
Write-Host "The Following VMs were terminated and removed: " $vms

#---Cleanup Leftover Copy on Write Delta Disks
Cleanup-Deltas -Name $vmTemplate

#---Close Out and Log details---
$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)
Write-Host -ForegroundColor Cyan  "`nStartTime: $StartTime"
Write-Host -ForegroundColor Cyan  "  EndTime: $EndTime"
Write-Host -ForegroundColor Green " Duration: $duration minutes"

