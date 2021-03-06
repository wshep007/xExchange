function Get-TargetResource
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSDSCUseVerboseMessageInDSCResource", "")]
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Boolean]
        $Enabled,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter()]
        [System.String[]]
        $AdditionalComponentsToActivate,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [ValidateSet('None','Lossless','GoodAvailability','BestAvailability','BestEffort')]
        [System.String]
        $MountDialOverride = 'None',

        [Parameter()]
        [System.Boolean]
        $MovePreferredDatabasesBack = $false,

        [Parameter()]
        [System.Boolean]
        $SetInactiveComponentsFromAnyRequesterToActive = $false,

        [Parameter()]
        [System.Boolean]
        $SkipActiveCopyChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipAllChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipClientExperienceChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipCpuChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipHealthChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipLagChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMaximumActiveDatabasesChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMoveSuppressionChecks = $false,

        [Parameter()]
        [System.String]
        $UpgradedServerVersion
    )

    LogFunctionEntry -Parameters @{"Enabled" = $Enabled} -Verbose:$VerbosePreference

    #Load TransportMaintenanceMode Helper
    Import-Module "$((Get-Item -LiteralPath "$($PSScriptRoot)"))\TransportMaintenance.psm1" -Verbose:0

    #Establish remote Powershell session
    GetRemoteExchangeSession -Credential $Credential -CommandsToLoad "Get-*" -Verbose:$VerbosePreference

    $maintenanceModeStatus = GetMaintenanceModeStatus -EnteringMaintenanceMode $Enabled -DomainController $DomainController
    $atDesiredVersion = IsExchangeAtDesiredVersion -DomainController $DomainController -UpgradedServerVersion $UpgradedServerVersion

    if ($null -ne $maintenanceModeStatus)
    {
        #Determine which components are Active
        $activeComponents = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.State -eq "Active"}

        [System.String[]]$activeComponentsList = @()

        if ($null -ne $activeComponents)
        {
            foreach ($activeComponent in $activeComponents)
            {
                $activeComponentsList += $activeComponent.Component
            }
        }

        $activeComponentCount = $activeComponentsList.Count


        #Figure out what our Enabled state should really be in case UpgradedServerVersion was passed
        $isEnabled = $Enabled

        if ($Enabled -eq $true -and $atDesiredVersion -eq $true)
        {
            $isEnabled = $false
        }


        $returnValue = @{
            Enabled              = [System.Boolean] $isEnabled
            ActiveComponentCount = [System.Int32] $activeComponentCount
            ActiveComponentsList = [System.String[]] $activeComponentsList
            ActiveDBCount        = [System.Int32] (GetActiveDBCount -MaintenanceModeStatus $maintenanceModeStatus -DomainController $DomainController)
            ActiveUMCallCount    = [System.Int32] (GetUMCallCount -MaintenanceModeStatus $maintenanceModeStatus -DomainController $DomainController)
            ClusterState         = [System.String] $maintenanceModeStatus.ClusterNode.State
            QueuedMessageCount   = [System.Int32] (GetQueueMessageCount -MaintenanceModeStatus $maintenanceModeStatus)
        }
    }

    $returnValue
}

function Set-TargetResource
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Boolean]
        $Enabled,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter()]
        [System.String[]]
        $AdditionalComponentsToActivate,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [ValidateSet('None','Lossless','GoodAvailability','BestAvailability','BestEffort')]
        [System.String]
        $MountDialOverride = 'None',

        [Parameter()]
        [System.Boolean]
        $MovePreferredDatabasesBack = $false,

        [Parameter()]
        [System.Boolean]
        $SetInactiveComponentsFromAnyRequesterToActive = $false,

        [Parameter()]
        [System.Boolean]
        $SkipActiveCopyChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipAllChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipClientExperienceChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipCpuChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipHealthChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipLagChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMaximumActiveDatabasesChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMoveSuppressionChecks = $false,

        [Parameter()]
        [System.String]
        $UpgradedServerVersion
    )

    LogFunctionEntry -Parameters @{"Enabled" = $Enabled} -Verbose:$VerbosePreference

    #Load TransportMaintenanceMode Helper
    Import-Module "$((Get-Item -LiteralPath "$($PSScriptRoot)"))\TransportMaintenance.psm1" -Verbose:0

    #Get ready for calling DAG maintenance scripts later
    $scriptsFolder = Join-Path -Path ((Get-ItemProperty HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup).MsiInstallPath) -ChildPath "Scripts"
    $startDagServerMaintenanceScript = Join-Path -Path "$($scriptsFolder)" -ChildPath "StartDagServerMaintenance.ps1"
    $stopDagServerMaintenanceScript = Join-Path -Path "$($scriptsFolder)" -ChildPath "StopDagServerMaintenance.ps1"

    #Override Write-Host, as it is used by the target scripts, and causes a DSC error since the session is not interactive
    New-Alias Write-Host Write-Verbose

    #Check if setup is running.
    $setupRunning = Get-IsSetupRunning

    if ($setupRunning -eq $true)
    {
        Write-Verbose "Exchange Setup is currently running. Skipping maintenance mode checks."
        return
    }

    #Establish remote Powershell session
    GetRemoteExchangeSession -Credential $Credential -CommandsToLoad "*" -Verbose:$VerbosePreference

    #If the request is to put the server in maintenance mode, make sure we aren't already at the (optional) requested Exchange Server version
    $atDesiredVersion = IsExchangeAtDesiredVersion -DomainController $DomainController -UpgradedServerVersion $UpgradedServerVersion

    if ($Enabled -eq $true -and $atDesiredVersion -eq $true)
    {
        Write-Verbose "Server is already at or above the desired upgrade version of '$($UpgradedServerVersion)'. Skipping putting server into maintenance mode."
        return
    }

    #Continue on with setting the maintenance mode state
    $maintenanceModeStatus = GetMaintenanceModeStatus -EnteringMaintenanceMode $Enabled -DomainController $DomainController

    if ($null -ne $maintenanceModeStatus)
    {
        #Set vars relevant to both 'Enabled' code paths
        $htStatus = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.Component -eq "HubTransport"}
        $haStatus = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.Component -eq "HubTransport"}

        #Put the server into maintenance mode
        if ($Enabled -eq $true)
        {
            #Block DB activation on this server
            if ($maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy -ne "Blocked")
            {
                Write-Verbose "Setting DatabaseCopyAutoActivationPolicy to Blocked"
                SetMailboxServer -Identity $env:COMPUTERNAME -DomainController $DomainController -AdditionalParams @{"DatabaseCopyAutoActivationPolicy" = "Blocked"}
            }

            #Set UM to draining before anything else
            $changedUM = ChangeComponentState -Component "UMCallRouter" -Requester "Maintenance" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Draining" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController

            #Start HT maintenance if required
            if ($htStatus.State -ne "Inactive")
            {
                Write-Verbose "Entering Transport Maintenance"
                [System.String[]]$transportExclusions = GetMessageRedirectionExclusions -DomainController $DomainController
                Start-TransportMaintenance -LoadLocalShell $false -MessageRedirectExclusions $transportExclusions -Verbose
            }

            #Wait for remaining UM calls to drain
            if ($changedUM)
            {
                WaitForUMToDrain -DomainController $DomainController
            }

            #Run StartDagServerMaintenance script to put cluster offline and failover DB's
            if ($maintenanceModeStatus.ClusterNode.State -eq "Up" -or
                $maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy -ne "Blocked" -or
                (GetActiveDBCount -MaintenanceModeStatus $maintenanceModeStatus -DomainController $DomainController) -ne 0)
            {
                Write-Verbose "Running StartDagServerMaintenance.ps1"

                $dagMemberCount = GetDAGMemberCount

                #Setup parameters for StartDagServerMaintenance.ps1
                $startDagScriptParams = @{
                    serverName = $env:COMPUTERNAME
                    Verbose = $true
                }

                if ((Get-ExchangeVersion) -in '2016','2019')
                {
                    $startDagScriptParams.Add('pauseClusterNode', $true)
                }

                if ($dagMemberCount -ne 0 -and $dagMemberCount -le 2)
                {
                    $startDagScriptParams.Add('overrideMinimumTwoCopies', $true)
                }

                if ($SkipAllChecks -or $SkipMoveSuppressionChecks)
                {
                    $startDagScriptParams.Add("Force", 'true')
                }

                #Execute StartDagServerMaintenance.ps1
                . $startDagServerMaintenanceScript @startDagScriptParams
            }

            #Set remaining components to offline
            ChangeComponentState -Component "ServerWideOffline" -Requester "Maintenance" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Inactive" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null

            #Check whether we are actually in maintenance mode
            $testResults = Test-TargetResource @PSBoundParameters

            if ($testResults -eq $false)
            {
                throw "Server is not fully in maintenance mode after running through steps to enable maintenance mode."
            }
        }
        #Take the server out of maintenance mode
        else
        {
            #Bring ServerWideOffline and UMCallRouter back online
            ChangeComponentState -Component "ServerWideOffline" -Requester "Maintenance" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Active" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null
            ChangeComponentState -Component "UMCallRouter" -Requester "Maintenance" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Active" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null

            #Run StopDagServerMaintenance.ps1 if required
            if ($maintenanceModeStatus.ClusterNode.State -ne "Up" -or `
                $maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy -ne "Unrestricted" -or`
                $haStatus.State -ne "Active")
            {
                Write-Verbose "Running StopDagServerMaintenance.ps1"

                #Run StopDagServerMaintenance.ps1 in try/catch, so if an exception occurs, we can at least finish
                #doing the rest of the steps to take the server out of maintenance mode
                try
                {
                    . $stopDagServerMaintenanceScript -serverName $env:COMPUTERNAME -Verbose
                }
                catch
                {
                    Write-Error "Caught exception running StopDagServerMaintenance.ps1: $($_.Exception.Message)"
                }
            }

            #End Transport Maintenance
            if ($htStatus.State -ne "Active")
            {
                Write-Verbose "Ending Transport Maintenance"
                Stop-TransportMaintenance -LoadLocalShell $false -Verbose
            }

            #Bring components online that may have been taken offline by a failed setup run
            ChangeComponentState -Component "Monitoring" -Requester "Functional" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Active" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null
            ChangeComponentState -Component "RecoveryActionsEnabled" -Requester "Functional" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Active" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null

            #Bring online any specifically requested components
            if ($null -ne $AdditionalComponentsToActivate)
            {
                foreach ($component in $AdditionalComponentsToActivate)
                {
                    if ((IsComponentCheckedByDefault -ComponentName $component) -eq $false)
                    {
                        $status = $null
                        $status = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.Component -like "$($component)"}

                        if ($null -ne $status -and $status.State -ne 'Active')
                        {
                            ChangeComponentState -Component $component -Requester "Functional" -ServerComponentState $maintenanceModeStatus.ServerComponentState -State "Active" -SetInactiveComponentsFromAnyRequesterToActive $SetInactiveComponentsFromAnyRequesterToActive -DomainController $DomainController | Out-Null
                        }
                    }
                }
            }

            if ($MovePreferredDatabasesBack -eq $true)
            {
                MovePrimaryDatabasesBack -DomainController $DomainController -MountDialOverride $MountDialOverride -SkipActiveCopyChecks $SkipActiveCopyChecks -SkipAllChecks $SkipAllChecks -SkipClientExperienceChecks $SkipClientExperienceChecks -SkipCpuChecks $SkipCpuChecks -SkipHealthChecks $SkipHealthChecks -SkipLagChecks $SkipLagChecks -SkipMaximumActiveDatabasesChecks $SkipMaximumActiveDatabasesChecks -SkipMoveSuppressionChecks $SkipMoveSuppressionChecks
            }
        }
    }
    else
    {
        throw "Failed to retrieve maintenance mode status of server."
    }

    Remove-HelperSnapin

    Remove-Item Alias:Write-Host -ErrorAction SilentlyContinue
}

function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Boolean]
        $Enabled,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential,

        [Parameter()]
        [System.String[]]
        $AdditionalComponentsToActivate,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [ValidateSet('None','Lossless','GoodAvailability','BestAvailability','BestEffort')]
        [System.String]
        $MountDialOverride = 'None',

        [Parameter()]
        [System.Boolean]
        $MovePreferredDatabasesBack = $false,

        [Parameter()]
        [System.Boolean]
        $SetInactiveComponentsFromAnyRequesterToActive = $false,

        [Parameter()]
        [System.Boolean]
        $SkipActiveCopyChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipAllChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipClientExperienceChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipCpuChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipHealthChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipLagChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMaximumActiveDatabasesChecks = $false,

        [Parameter()]
        [System.Boolean]
        $SkipMoveSuppressionChecks = $false,

        [Parameter()]
        [System.String]
        $UpgradedServerVersion
    )

    LogFunctionEntry -Parameters @{"Enabled" = $Enabled} -Verbose:$VerbosePreference

    #Load TransportMaintenanceMode Helper
    Import-Module "$((Get-Item -LiteralPath "$($PSScriptRoot)"))\TransportMaintenance.psm1" -Verbose:0

    $setupRunning = Get-IsSetupRunning

    if ($setupRunning -eq $true)
    {
        Write-Verbose "Exchange Setup is currently running. Skipping maintenance mode checks."
        return $true
    }

    #Establish remote Powershell session
    GetRemoteExchangeSession -Credential $Credential -CommandsToLoad "Get-*" -Verbose:$VerbosePreference

    $serverVersion = Get-ExchangeVersion

    $maintenanceModeStatus = GetMaintenanceModeStatus -EnteringMaintenanceMode $Enabled -DomainController $DomainController

    $testResults = $true

    if ($null -eq $maintenanceModeStatus)
    {
        Write-Error -Message "Failed to retrieve maintenance mode status for server."

        $testResults = $false
    }
    else
    {
        #Make sure server is fully in maintenance mode
        if ($Enabled -eq $true)
        {
            $atDesiredVersion = IsExchangeAtDesiredVersion -DomainController $DomainController -UpgradedServerVersion $UpgradedServerVersion

            if ($atDesiredVersion -eq $true)
            {
                Write-Verbose "Server is already at or above the desired upgrade version of '$($UpgradedServerVersion)'. Skipping putting server into maintenance mode."
                return $true
            }
            else
            {
                if ($maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy -ne "Blocked")
                {
                    Write-Verbose "DatabaseCopyAutoActivationPolicy is not set to Blocked"
                    $testResults = $false
                }

                if ($null -ne ($MaintenanceModeStatus.ServerComponentState | Where-Object {$_.State -ne "Inactive" -and $_.Component -ne "Monitoring" -and $_.Component -ne "RecoveryActionsEnabled"}))
                {
                    Write-Verbose "One or more components have a status other than Inactive"
                    $testResults = $false
                }

                if ($maintenanceModeStatus.ClusterNode.State -eq "Up")
                {
                    Write-Verbose "Cluster node has a status of Up"
                    $testResults = $false
                }

                if ((IsServerPAM -DomainController $DomainController) -eq $true)
                {
                    Write-Verbose "Server still has the Primary Active Manager role"
                    $testResults = $false
                }


                [int]$messagesQueued = GetQueueMessageCount -MaintenanceModeStatus $maintenanceModeStatus

                if ($messagesQueued -gt 0)
                {
                    Write-Verbose "Found $($messagesQueued) messages still in queue"
                    $testResults = $false
                }


                [int]$activeDBCount = GetActiveDBCount -MaintenanceModeStatus $maintenanceModeStatus -DomainController $DomainController

                if ($activeDBCount -gt 0)
                {
                    Write-Verbose "Found $($activeDBCount) replicated databases still activated on this server"
                    $testResults = $false
                }


                [int]$umCallCount = GetUMCallCount -MaintenanceModeStatus $maintenanceModeStatus -DomainController $DomainController

                if ($umCallCount -gt 0)
                {
                    Write-Verbose "Found $($umCallCount) active UM calls on this server"
                    $testResults = $false
                }
            }
        }
        #Make sure the server is fully out of maintenance mode
        else
        {
            $activeComponents = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.State -eq "Active"}

            if ($null -eq $activeComponents)
            {
                Write-Verbose "No Components found with a status of Active"
                $testResults = $false
            }

            if ($null -eq ($activeComponents | Where-Object {$_.Component -eq "ServerWideOffline"}))
            {
                Write-Verbose "Component ServerWideOffline is not Active"
                $testResults = $false
            }

            if ($serverVersion -in '2013','2016')
            {
                if ($null -eq ($activeComponents | Where-Object {$_.Component -eq "UMCallRouter"}))
                {
                    Write-Verbose "Component UMCallRouter is not Active"
                    $testResults = $false
                }
            }

            if ($null -eq ($activeComponents | Where-Object {$_.Component -eq "HubTransport"}))
            {
                Write-Verbose "Component HubTransport is not Active"
                $testResults = $false
            }

            if ($maintenanceModeStatus.ClusterNode.State -ne "Up")
            {
                Write-Verbose "Cluster node has a status of $($maintenanceModeStatus.ClusterNode.State)"
                $testResults = $false
            }

            if ($maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy -ne "Unrestricted")
            {
                Write-Verbose "DatabaseCopyAutoActivationPolicy is set to $($maintenanceModeStatus.MailboxServer.DatabaseCopyAutoActivationPolicy)"
                $testResults = $false
            }

            if ($null -eq ($activeComponents | Where-Object {$_.Component -eq "Monitoring"}))
            {
                Write-Verbose "Component Monitoring is not Active"
                $testResults = $false
            }

            if ($null -eq ($activeComponents | Where-Object {$_.Component -eq "RecoveryActionsEnabled"}))
            {
                Write-Verbose "Component RecoveryActionsEnabled is not Active"
                $testResults = $false
            }

            if ($null -ne $AdditionalComponentsToActivate)
            {
                foreach ($component in $AdditionalComponentsToActivate)
                {
                    if ((IsComponentCheckedByDefault -ComponentName $component) -eq $false)
                    {
                        $status = $null
                        $status = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.Component -like "$($component)"}

                        if ($null -ne $status -and $Status.State -ne "Active")
                        {
                            Write-Verbose "Component $($component) is not set to Active"
                            $testResults = $false
                        }
                    }
                }
            }
        }
    }

    Remove-HelperSnapin

    return $testResults
}

#Gets a Hashtable containing various objects from Exchange that will be used to determine maintenance mode status
function GetMaintenanceModeStatus
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.Boolean]
        $EnteringMaintenanceMode = $true
    )

    RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToKeep 'DomainController'

    $serverComponentState = GetServerComponentState -Identity $env:COMPUTERNAME -DomainController $DomainController
    $clusterNode = Get-ClusterNode -Name $env:COMPUTERNAME
    $dbCopyStatus = GetMailboxDatabaseCopyStatus -Server $env:COMPUTERNAME -DomainController $DomainController
    $umCalls = GetUMActiveCalls -Server $env:COMPUTERNAME -DomainController $DomainController
    $mailboxServer = GetMailboxServer -Identity $env:COMPUTERNAME -DomainController $DomainController
    $queues = Get-Queue -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue

    #If we're checking queues too soon after restarting Transport, Get-Queue may fail. Wait for bootloader to be active and try again.
    if ($null -eq $queues -and $EnteringMaintenanceMode -eq $true)
    {
        $endTime = [DateTime]::Now.AddMinutes(5)

        Write-Verbose "Waiting up to 5 minutes for the Transport Bootloader to be ready before running Get-Queue. Wait started at $([DateTime]::Now)."

        while ($null -eq $queues -and [DateTime]::Now -lt $endTime)
        {
            Wait-BootLoaderReady -Server $env:COMPUTERNAME -TimeOut (New-TimeSpan -Seconds 15) -PollingFrequency (New-TimeSpan -Seconds 1) | Out-Null
            $queues = Get-Queue -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue
        }
    }

    [System.Collections.Hashtable]$returnValue = @{
        ServerComponentState = $serverComponentState
        ClusterNode = $clusterNode
        Queues = $queues
        DBCopyStatus = $dbCopyStatus
        UMActiveCalls = $umCalls
        MailboxServer = $mailboxServer
    }

    return $returnValue
}

#Gets a count of messages in queues on the local server
function GetQueueMessageCount
{
    [CmdletBinding()]
    [OutputType([System.UInt32])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]
        $MaintenanceModeStatus
    )

    [UInt32]$messageCount = 0

    if ($null -ne $MaintenanceModeStatus.Queues)
    {
        foreach ($queue in $MaintenanceModeStatus.Queues | Where-Object {$_.Identity -notlike "*\Shadow\*"})
        {
            Write-Verbose "Found queue '$($queue.Identity)' with a message count of '$($queue.MessageCount)'."
            $messageCount += $queue.MessageCount
        }
    }
    else
    {
        Write-Warning "No Transport Queues were detected on this server. This can occur if the MSExchangeTransport service is not started, or if Get-Queue was run too quickly after restarting the service."
    }

    return [System.UInt32] $messageCount
}

#Gets a count of database that are replication enabled, and are still activated on the local server (even if they are dismounted)
function GetActiveDBCount
{
    [CmdletBinding()]
    [OutputType([System.UInt32])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]
        $MaintenanceModeStatus,

        [Parameter()]
        [System.String]
        $DomainController
    )

    [UInt32]$activeDBCount = 0

    #Get DB's with a status of Mounted, Mounting, Dismounted, or Dismounting
    $localDBs = $MaintenanceModeStatus.DBCopyStatus | Where-Object {$_.Status -like "Mount*" -or $_.Status -like "Dismount*"}

    #Ensure that any DB's we found actually have copies
    foreach ($db in $localDBs)
    {
        $dbProps = GetMailboxDatabase -Identity "$($db.DatabaseName)" -DomainController $DomainController

        if ($dbProps.ReplicationType -ne "None")
        {
            Write-Verbose "Found database '$($db.DatabaseName)' with a replication type of '$($dbProps.ReplicationType)' and a status of '$($db.Status)'."
            $activeDBCount++
        }
    }

    return [System.UInt32] $activeDBCount
}

#Gets a count of active UM calls on the local server
function GetUMCallCount
{
    [CmdletBinding()]
    [OutputType([System.UInt32])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]
        $MaintenanceModeStatus,

        [Parameter()]
        [System.String]
        $DomainController
    )

    [Uint32]$umCallCount = 0

    $umCalls = GetUMActiveCalls -Server $env:COMPUTERNAME -DomainController $DomainController

    if ($null -ne $umCalls)
    {
        if ($null -eq $umCalls.Count)
        {
            $umCallCount = 1
        }
        else
        {
            $umCallCount = $umCalls.Count
        }
    }

    return [System.UInt32] $umCallCount
}

#Gets a list of servers in the DAG with HubTransport not set to Active, or DatabaseCopyAutoActivationPolicy set to Blocked
function GetMessageRedirectionExclusions
{
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController
    )

    [System.String[]]$exclusions = @()

    $mbxServer = GetMailboxServer -Identity $env:COMPUTERNAME -DomainController $DomainController

    if ($null -ne $mbxServer)
    {
        $dag = GetDatabaseAvailabilityGroup -Identity $($mbxServer.DatabaseAvailabilityGroup) -DomainController $DomainController

        if ($null -ne $dag)
        {
            foreach ($server in $dag.Servers)
            {
                if ($server.Name -notlike $env:COMPUTERNAME)
                {
                    $serverName = $server.Name.ToLower()

                    #Check whether HubTransport is active on the specified server
                    $htState = $null
                    $htState = GetServerComponentState -Identity $server.Name -Component "HubTransport" -DomainController $DomainController

                    if ($null -ne $htState -and $htState.State -notlike "Active")
                    {
                        if (($exclusions.Contains($serverName) -eq $false))
                        {
                            $exclusions += $serverName
                            continue
                        }
                    }

                    #Check whether the server is already blocked from database activation
                    $currentMbxServer = $null
                    $currentMbxServer = GetMailboxServer -Identity $server.Name -DomainController $DomainController

                    if ($null -ne $currentMbxServer -and $currentMbxServer.DatabaseCopyAutoActivationPolicy -like "Blocked")
                    {
                        if (($exclusions.Contains($serverName) -eq $false))
                        {
                            $exclusions += $serverName
                            continue
                        }
                    }
                }
            }
        }
    }

    return [System.String[]] $exclusions
}

#If UpgradedServerVersion was specified, checks to see whether the server is already at the desired version
function IsExchangeAtDesiredVersion
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.String]
        $UpgradedServerVersion
    )

    $atDesiredVersion = $false

    if (!([System.String]::IsNullOrEmpty($UpgradedServerVersion)))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToKeep 'DomainController'

        $server = GetExchangeServer -Identity $env:COMPUTERNAME -DomainController $DomainController

        if ($null -ne $server)
        {
            [System.String[]]$versionParts = $UpgradedServerVersion.Split('.')

            if ($null -ne $versionParts -and $versionParts.Length -eq 4)
            {
                if (([int]::Parse($server.AdminDisplayVersion.Major) -ge [int]::Parse($versionParts[0])) -and
                    ([int]::Parse($server.AdminDisplayVersion.Minor) -ge [int]::Parse($versionParts[1])) -and
                    ([int]::Parse($server.AdminDisplayVersion.Build) -ge [int]::Parse($versionParts[2])) -and
                    ([int]::Parse($server.AdminDisplayVersion.Revision) -ge [int]::Parse($versionParts[3])))
                {
                    $atDesiredVersion = $true
                }
                else
                {
                    Write-Verbose "Desired server version '$($UpgradedServerVersion)' is greater than the actual server version '$($server.AdminDisplayVersion)'"
                }
            }
            else
            {
                throw "Invalid version format for `$UpgradedServerVersion. Should be in the format ##.#.####.#"
            }
        }
    }

    return $atDesiredVersion
}

#Checks to see whether the specified component is one that is already checked by default
function IsComponentCheckedByDefault
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $ComponentName
    )

    [System.Boolean]$checkedByDefault = $false

    if ($ComponentName -like "ServerWideOffline" -or $ComponentName -like "UMCallRouter" -or $ComponentName -like "HubTransport" -or $ComponentName -like "Monitoring" -or $ComponentName -like "RecoveryActionsEnabled")
    {
        $checkedByDefault = $true
    }

    return $checkedByDefault
}

#Gets a count of members in this servers DAG
function GetDAGMemberCount
{
    [CmdletBinding()]
    [OutputType([System.Int32])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController
    )

    [System.Int32]$count = 0

    $server = GetMailboxServer -Identity $env:COMPUTERNAME -DomainController $DomainController

    if ($null -ne $server -and ![System.String]::IsNullOrEmpty($server.DatabaseAvailabilityGroup))
    {
        $dag = GetDatabaseAvailabilityGroup -Identity "$($server.DatabaseAvailabilityGroup)" -DomainController $DomainController

        if ($null -ne $dag)
        {
            $count = $dag.Servers.Count
        }
    }

    return $count
}

function IsServerPAM
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController
    )

    $isPAM = $false

    $server = GetMailboxServer -Identity $env:COMPUTERNAME -DomainController $DomainController

    if ($null -ne $server -and ![System.String]::IsNullOrEmpty($server.DatabaseAvailabilityGroup))
    {
        $dag = GetDatabaseAvailabilityGroup -Identity "$($server.DatabaseAvailabilityGroup)" -DomainController $DomainController

        if ($null -ne $dag -and $dag.PrimaryActiveManager -like $env:COMPUTERNAME)
        {
            $isPAM = $true
        }
    }

    return $isPAM
}

#Waits up the the specified WaitMinutes for existing UM calls to finish. Returns True if no more UM calls are active.
function WaitForUMToDrain
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.UInt32]
        $SleepSeconds = 15,

        [Parameter()]
        [System.UInt32]
        $WaitMinutes = 5
    )

    [System.Boolean]$umDrained = $false

    $endTime = [DateTime]::Now.AddMinutes($WaitMinutes)

    Write-Verbose "Waiting up to $($WaitMinutes) minutes for active UM calls to finish"

    while ($fullyInMaintenanceMode -eq $false -and [DateTime]::Now -lt $endTime)
    {
        Write-Verbose "Checking whether all UM calls are finished at $([DateTime]::Now)."

        $umCalls = $null

        GetUMActiveCalls -Server $env:COMPUTERNAME -DomainController $DomainController

        if ($null -eq $umCalls -or $umCalls.Count -eq 0)
        {
            $umDrained = $true
        }
        else
        {
            Write-Verbose "There are still active UM calls as of $([DateTime]::Now). Sleeping for $($SleepSeconds) seconds. Will continue checking until $($endTime)."
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    return $umDrained
}

#Checks whether a Component is at the specified State, if not, changes the component to the state.
#Returns whether a change was made to the component state
function ChangeComponentState
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Component,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Requester,

        [Parameter(Mandatory = $true)]
        $ServerComponentState,

        [Parameter(Mandatory = $true)]
        [System.String]
        $State,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.Boolean]
        $SetInactiveComponentsFromAnyRequesterToActive = $false
    )

    [System.Boolean]$madeChange = $false

    $componentState = $MaintenanceModeStatus.ServerComponentState | Where-Object {$_.Component -like "$($Component)"}

    if ($null -ne $componentState)
    {
        #If we're already Inactive don't bother setting to Draining.
        if ($State -like "Draining" -and $componentState.State -like "Inactive")
        {
            return $false
        }
        elseif ($componentState.State -notlike "$($State)")
        {
            Write-Verbose "Setting $($componentState.Component) component to $($State) for requester $($Requester)"

            SetServerComponentState -Component $componentState.Component -State $State -Requester $Requester -DomainController $DomainController

            $madeChange = $true

            if ($State -eq "Active" -and $SetInactiveComponentsFromAnyRequesterToActive -eq $true)
            {
                $additionalRequesters = $null
                $additionalRequesters = $componentState.LocalStates | Where-Object {$_.Requester -notlike "$($Requester)" -and $_.State -notlike "Active"}

                if ($null -ne $additionalRequesters)
                {
                    foreach ($additionalRequester in $additionalRequesters)
                    {
                        Write-Verbose "Setting $($componentState.Component) component to Active for requester $($additionalRequester.Requester)"

                        SetServerComponentState -Component $componentState.Component -State Active -Requester $additionalRequester.Requester -DomainController $DomainController
                    }
                }
            }
        }
    }

    return $madeChange
}

#Finds any databases which have an Activation Preference of 1 for this server, which are not currently hosted on this server, and moves them back
function MovePrimaryDatabasesBack
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [ValidateSet('None','Lossless','GoodAvailability','BestAvailability','BestEffort')]
        [System.String]
        $MountDialOverride,

        [Parameter()]
        [System.Boolean]
        $SkipActiveCopyChecks,

        [Parameter()]
        [System.Boolean]
        $SkipAllChecks,

        [Parameter()]
        [System.Boolean]
        $SkipClientExperienceChecks,

        [Parameter()]
        [System.Boolean]
        $SkipCpuChecks,

        [Parameter()]
        [System.Boolean]
        $SkipHealthChecks,

        [Parameter()]
        [System.Boolean]
        $SkipLagChecks,

        [Parameter()]
        [System.Boolean]
        $SkipMaximumActiveDatabasesChecks,

        [Parameter()]
        [System.Boolean]
        $SkipMoveSuppressionChecks
    )

    $databases = GetMailboxDatabase -Server $env:COMPUTERNAME -Status -DomainController $DomainController

    [System.String[]]$databasesWithActivationPrefOneNotOnThisServer = @()

    if ($null -ne $databases)
    {
        foreach ($database in $databases)
        {
            if ($null -ne $database.ActivationPreference)
            {
                foreach ($ap in $database.ActivationPreference)
                {
                    if ($ap.Key.Name -like $env:COMPUTERNAME -and $ap.Value -eq 1)
                    {
                        $copyStatus = $null
                        $copyStatus = GetMailboxDatabaseCopyStatus -Identity "$($database.Name)\$($env:COMPUTERNAME)" -DomainController $DomainController

                        if ($null -ne $copyStatus -and $copyStatus.Status -eq "Healthy")
                        {
                            $databasesWithActivationPrefOneNotOnThisServer += $database.Name
                        }
                    }
                }
            }
        }
    }

    if ($databasesWithActivationPrefOneNotOnThisServer.Count -gt 0)
    {
        Write-Verbose "Found $($databasesWithActivationPrefOneNotOnThisServer.Count) Healthy databases with Activation Preference 1 that should be moved to this server."

        foreach ($database in $databasesWithActivationPrefOneNotOnThisServer)
        {
            Write-Verbose "Attempting to move database '$($database)' back to this server."

            #Do the move in a try/catch block so we can log the error, but not have it prevent other databases from attempting to move
            try
            {
                MoveActiveMailboxDatabase -Identity $database -ActivateOnServer $env:COMPUTERNAME -DomainController $DomainController -MountDialOverride $MountDialOverride -SkipActiveCopyChecks $SkipActiveCopyChecks -SkipAllChecks $SkipAllChecks -SkipClientExperienceChecks $SkipClientExperienceChecks -SkipCpuChecks $SkipCpuChecks -SkipHealthChecks $SkipHealthChecks -SkipLagChecks $SkipLagChecks -SkipMaximumActiveDatabasesChecks $SkipMaximumActiveDatabasesChecks -SkipMoveSuppressionChecks $SkipMoveSuppressionChecks
            }
            catch
            {
                Write-Error "$($_.Exception.Message)"
            }
        }
    }
    else
    {
        Write-Verbose "Found 0 Healthy databases with Activation Preference 1 for this server that are currently not hosted on this server"
    }
}

#region Exchange Cmdlet Wrappers
function GetExchangeServer
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController
    )

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    return (Get-ExchangeServer @PSBoundParameters)
}

function GetDatabaseAvailabilityGroup
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController
    )

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    return (Get-DatabaseAvailabilityGroup @PSBoundParameters -Status)
}

function GetServerComponentState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $Component,

        [Parameter()]
        [System.String]
        $DomainController
    )

    if ([System.String]::IsNullOrEmpty($Component))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Component'
    }

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    return (Get-ServerComponentState @PSBoundParameters)
}

function SetServerComponentState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Component,

        [Parameter(Mandatory = $true)]
        [System.String]
        $Requester,

        [Parameter(Mandatory = $true)]
        [System.String]
        $State,

        [Parameter()]
        [System.String]
        $DomainController
    )

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    Set-ServerComponentState -Identity $env:COMPUTERNAME @PSBoundParameters
}

function GetMailboxDatabase
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.String]
        $Server,

        [Parameter()]
        [switch]
        $Status
    )

    if ([System.String]::IsNullOrEmpty($Identity))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Identity'
    }

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    if ([System.String]::IsNullOrEmpty($Server))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Server'
    }

    return (Get-MailboxDatabase @PSBoundParameters)
}

function GetMailboxDatabaseCopyStatus
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.String]
        $Server
    )

    if ([System.String]::IsNullOrEmpty($Identity))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Identity'
    }

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    if ([System.String]::IsNullOrEmpty($Server))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Server'
    }

    return (Get-MailboxDatabaseCopyStatus @PSBoundParameters)
}

function GetMailboxServer
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController
    )

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    return (Get-MailboxServer @PSBoundParameters)
}

function SetMailboxServer
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [System.Collections.Hashtable]
        $AdditionalParams
    )

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    AddParameters -PSBoundParametersIn $PSBoundParameters -ParamsToAdd $AdditionalParams
    RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'AdditionalParams'

    Set-MailboxServer @PSBoundParameters
}

function GetUMActiveCalls
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $Server,

        [Parameter()]
        [System.String]
        $DomainController
    )

    $umActiveCalls = $null

    $serverVersion = Get-ExchangeVersion

    if ($serverVersion -in '2013','2016')
    {
        if ([System.String]::IsNullOrEmpty($DomainController))
        {
            RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
        }

        $umActiveCalls = Get-UMActiveCalls @PSBoundParameters
    }

    return $umActiveCalls
}

function MoveActiveMailboxDatabase
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [System.String]
        $ActivateOnServer,

        [Parameter()]
        [System.String]
        $Identity,

        [Parameter()]
        [System.String]
        $DomainController,

        [Parameter()]
        [ValidateSet('None','Lossless','GoodAvailability','BestAvailability','BestEffort')]
        [System.String]
        $MountDialOverride,

        [Parameter()]
        [System.String]
        $MoveComment,

        [Parameter()]
        [System.String]
        $Server = $env:COMPUTERNAME,

        [Parameter()]
        [System.Boolean]
        $SkipActiveCopyChecks,

        [Parameter()]
        [System.Boolean]
        $SkipAllChecks,

        [Parameter()]
        [System.Boolean]
        $SkipClientExperienceChecks,

        [Parameter()]
        [System.Boolean]
        $SkipCpuChecks,

        [Parameter()]
        [System.Boolean]
        $SkipHealthChecks,

        [Parameter()]
        [System.Boolean]
        $SkipLagChecks,

        [Parameter()]
        [System.Boolean]
        $SkipMaximumActiveDatabasesChecks,

        [Parameter()]
        [System.Boolean]
        $SkipMoveSuppressionChecks
    )

    if ([System.String]::IsNullOrEmpty($ActivateOnServer))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'ActivateOnServer'
    }

    if ([System.String]::IsNullOrEmpty($DomainController))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'DomainController'
    }

    if ([System.String]::IsNullOrEmpty($Identity))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Identity'
    }

    if ([System.String]::IsNullOrEmpty($MoveComment))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'MoveComment'
    }

    if ([System.String]::IsNullOrEmpty($Server))
    {
        RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'Server'
    }

    #Setup parameters in a format Move-ActiveMailboxDatabase expects
    $moveDBParams = @{
        Confirm     = $false
        Erroraction = 'Stop'
    }

    if ($SkipActiveCopyChecks)
    {
        $moveDBParams.Add("SkipActiveCopyChecks", $true)
    }

    if ($SkipClientExperienceChecks)
    {
        $moveDBParams.Add("SkipClientExperienceChecks", $true)
    }

    if ($SkipHealthChecks)
    {
        $moveDBParams.Add("SkipHealthChecks", $true)
    }

    if ($SkipLagChecks)
    {
        $moveDBParams.Add("SkipLagChecks", $true)
    }

    if ($SkipMaximumActiveDatabasesChecks)
    {
        $moveDBParams.Add("SkipMaximumActiveDatabasesChecks", $true)
    }

    if ((Get-ExchangeVersion) -in '2016','2019')
    {
        if ($SkipAllChecks)
        {
            $moveDBParams.Add("SkipAllChecks", $true)
        }

        if ($SkipCpuChecks)
        {
            $moveDBParams.Add("SkipCpuChecks", $true)
        }

        if ($SkipMoveSuppressionChecks)
        {
            $moveDBParams.Add("SkipMoveSuppressionChecks", $true)
        }
    }

    #Remove the PSBoundParameters we just re-formatted
    RemoveParameters -PSBoundParametersIn $PSBoundParameters -ParamsToRemove 'SkipActiveCopyChecks','SkipClientExperienceChecks','SkipLagChecks','SkipMaximumActiveDatabasesChecks','SkipMoveSuppressionChecks','SkipHealthChecks','SkipCpuChecks','SkipAllChecks'

    #Execute mailbox DB move
    Move-ActiveMailboxDatabase @PSBoundParameters @moveDBParams
}
#endregion

<#
    .SYNOPSIS
        Removes the Exchange PowerShell snapin, which is loaded by the
        Start/StopDagMaintennace.ps1 scripts in the $Exscripts
        directory. Prevents an issue where if a snapin is added by multiple
        modules during the same session, subsequent additions of the same
        module fail with 'An item with the same key has already been added'.

    .NOTES
        This similar function exists in the files
        MSFT_xExchAntiMalwareScanning.psm1 and MSFT_xExchMaintenanceMode.psm1.
        This was initially attempted to be put in xExchangeHelper.psm1 instead.
        However when xExchangeHelper.psm1 is loaded as a NestedModule from
        xExchange.psd1, functions within xExchangeHelper.psm1 do not appear to
        be able to detect added snapins loaded by scripts called from other
        modules. The added snapins were only detectable when running
        Get-PSSnapin directly from functions within
        MSFT_xExchAntiMalwareScanning.psm1 and MSFT_xExchMaintenanceMode.psm1.
#>
function Remove-HelperSnapin
{
    [CmdletBinding()]
    param()

    $snapinsToRemove = @('Microsoft.Exchange.Management.Powershell.E2010')

    foreach ($snapin in $snapinsToRemove)
    {
        if ($null -ne (Get-PSSnapin -Name $snapin -ErrorAction SilentlyContinue))
        {
            Write-Verbose -Message "'$snapin' snapin is currently loaded. Removing."

            Remove-PSSnapin -Name $snapin -ErrorAction SilentlyContinue -Confirm:$false
        }
    }
}

Export-ModuleMember -Function *-TargetResource
