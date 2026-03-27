param(
    [string]$principalNameToAssign,
    [string]$sqlServer,
    [string]$dbName,
    [string]$sqlSuffix,
    [string]$subscriptionId,
    [string]$resourceGroupName,
    [string]$scriptVersion = "1.0.0"
)
try {
    Write-Host "Starting RBAC assignment for user: $principalNameToAssign"
    Write-Host "SQL Server: $sqlServer"
    Write-Host "Database: $dbName"
    Write-Host "SQL Suffix: $sqlSuffix"
    Write-Host "Script version: $scriptVersion"

    # Validate input parameters
    if ([string]::IsNullOrWhiteSpace($principalNameToAssign)) { throw "PrincipalNameToAssign cannot be empty" }
    if ($principalNameToAssign -match "[\[\]']") { throw "PrincipalNameToAssign contains invalid characters" }
    if ([string]::IsNullOrWhiteSpace($sqlServer)) { throw "SQL Server name cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($dbName)) { throw "Database name cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($sqlSuffix)) { throw "SQL Suffix cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) { throw "Subscription ID cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($resourceGroupName)) { throw "Resource Group name cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($scriptVersion)) { throw "ScriptVersion cannot be empty" }

    # Get access token for SQL Database
    # Avoid -AsPlainText: not all deployment-script container images support it.
    # Handle both plain string (Az < 12) and SecureString (Az 12+) transparently.
    $resourceUrl = "https://database.windows.net"
    Write-Host "Requesting access token for: $resourceUrl"
    $accessTokenObj = Get-AzAccessToken -ResourceUrl $resourceUrl
    if ($accessTokenObj.Token -is [System.Security.SecureString]) {
        # Use PtrToStringBSTR (not PtrToStringAuto) — PtrToStringAuto uses the OS
        # default encoding which on Linux (the deployment script container) is UTF-8,
        # but BSTR is always UTF-16, producing a garbled token.
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($accessTokenObj.Token)
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    } else {
        $token = $accessTokenObj.Token
    }
    if (-not $token) {
        throw "Failed to obtain access token"
    }
    Write-Host "Successfully obtained access token (length: $($token.Length), starts: $($token.Substring(0, [Math]::Min(10, $token.Length)))...)"

    # Connect to SQL Database
    $sqlFqdn = if ($sqlSuffix.StartsWith('.')) { "$sqlServer$sqlSuffix" } else { "$sqlServer.$sqlSuffix" }
    Write-Host "Connecting to: $sqlFqdn"
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=tcp:$sqlFqdn;Database=$dbName;Connection Timeout=30;Encrypt=True;TrustServerCertificate=False;"
    $conn.AccessToken = $token
    $conn.Open()
    Write-Host "Connected to SQL Database successfully"

    # Create user if it doesn't exist
    # Parameter binding is not supported for DDL; principal name is validated above to block injection.
    $createUserSQL = "IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = @principalName) BEGIN CREATE USER [$principalNameToAssign] FROM EXTERNAL PROVIDER END"
    Write-Host "Executing user creation command"
    $createUser = $conn.CreateCommand()
    $createUser.CommandText = $createUserSQL
    $null = $createUser.Parameters.AddWithValue("@principalName", $principalNameToAssign)
    $result = $createUser.ExecuteNonQuery()
    $createUser.Dispose()
    Write-Host "User creation command executed. Rows affected: $result"

    # Add user to db_datareader role
    $addRoleSQL = "ALTER ROLE db_datareader ADD MEMBER [$principalNameToAssign]"
    Write-Host "Executing role assignment command"
    $addToRole = $conn.CreateCommand()
    $addToRole.CommandText = $addRoleSQL
    $result = $addToRole.ExecuteNonQuery()
    $addToRole.Dispose()
    Write-Host "Role assignment command executed. Rows affected: $result"

    $conn.Close()
    $conn.Dispose()
    Write-Host "RBAC assignment completed successfully"

    # Also create the user in the master database so that tools like the Azure Portal
    # Query Editor (which connects to master first) can authenticate successfully.
    Write-Host "Ensuring user exists in master database for portal access"
    $masterConn = New-Object System.Data.SqlClient.SqlConnection
    $masterConn.ConnectionString = "Server=tcp:$sqlFqdn;Database=master;Connection Timeout=30;Encrypt=True;TrustServerCertificate=False;"
    $masterConn.AccessToken = $token
    try {
        $masterConn.Open()
        Write-Host "Connected to master database"
        $masterCmd = $masterConn.CreateCommand()
        $masterCmd.CommandText = "IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = @principalName) BEGIN CREATE USER [$principalNameToAssign] FROM EXTERNAL PROVIDER END"
        $null = $masterCmd.Parameters.AddWithValue("@principalName", $principalNameToAssign)
        $result = $masterCmd.ExecuteNonQuery()
        $masterCmd.Dispose()
        Write-Host "Master database user ensured. Rows affected: $result"
        $masterConn.Close()
        $masterConn.Dispose()
    } catch {
        Write-Warning "Could not create user in master database: $($_.Exception.Message)"
        Write-Warning "Users may not be able to access the database via the Azure Portal Query Editor."
        try { $masterConn.Close(); $masterConn.Dispose() } catch {}
    }

    # Tag the database to indicate RBAC has been applied
    Write-Host "Tagging database to indicate RBAC has been applied"
    $dbResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Sql/servers/$sqlServer/databases/$dbName"

    # Get current tags and add the sqlRBACApplied tag
    $currentTags = @{}
    try {
        $dbResource = Get-AzResource -ResourceId $dbResourceId
        if ($dbResource.Tags) {
            $currentTags = $dbResource.Tags
        }
    } catch {
        Write-Warning "Could not retrieve current tags: $($_.Exception.Message)"
    }

    $currentTags['sqlRBACApplied'] = $scriptVersion
    Set-AzResource -ResourceId $dbResourceId -Tag $currentTags -Force
    Write-Host "Database tagged successfully with sqlRBACApplied=$scriptVersion"

}
catch {
    Write-Error "Error occurred: $($_.Exception.Message)"
    Write-Error "Stack trace: $($_.Exception.StackTrace)"
    if ($conn) {
        try { $conn.Close(); $conn.Dispose() } catch { Write-Warning "Failed to close connection: $($_.Exception.Message)" }
        Write-Host "Connection closed due to error"
    }
    throw
}