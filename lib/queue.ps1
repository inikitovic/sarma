# lib\queue.ps1 — Task queue backed by Azure Storage Table (no Queue dependency)
# Uses the sarmatasks table with status-based polling instead of Azure Queue.

function Send-SarmaTask {
    <#
    .SYNOPSIS
        Submit a task by writing it to the tasks table with status=pending.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$TaskData
    )
    Set-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId -Properties $TaskData
}

function Receive-SarmaTask {
    <#
    .SYNOPSIS
        Poll for a pending task matching the given types. Returns $null if none found.
        Uses optimistic concurrency — claims the task by setting status=running.
    #>
    param(
        [string[]]$TaskTypes = $script:SarmaConfig.WorkerTaskTypes
    )

    foreach ($type in $TaskTypes) {
        $filter = "PartitionKey eq 'task' and status eq 'pending' and taskType eq '$type'"
        $tasks = Get-SarmaTableEntities -TableName "sarmatasks" -Filter $filter
        if ($tasks -and $tasks.Count -gt 0) {
            $task = $tasks[0]
            # Claim it by setting status to running (optimistic — first worker wins)
            try {
                Set-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $task.RowKey -Properties @{
                    status    = "running"
                    workerId  = $script:SarmaConfig.WorkerId
                    startedAt = [datetime]::UtcNow.ToString("o")
                }
                return $task
            } catch {
                # Another worker claimed it first, try next
                continue
            }
        }
    }
    return $null
}

