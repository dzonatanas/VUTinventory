# Pester 5 tests for the pure logic of Register-SnipeAsset.ps1.
# Only the function definitions are loaded (via the AST); the script body - hardware queries,
# token lookup, API calls - never runs. Run: Invoke-Pester .\tests

BeforeAll {
    $scriptPath  = Join-Path (Split-Path $PSScriptRoot) 'Register-SnipeAsset.ps1'
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

Describe 'Script file' {
    It 'parses without errors in this PowerShell version' {
        $parseErrors | Should -BeNullOrEmpty
    }
    It 'is pure ASCII (PS 5.1 reads BOM-less files as ANSI)' {
        $bytes = [IO.File]::ReadAllBytes($scriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Test-JunkSerial' {
    It 'rejects placeholder "<Value>"' -TestCases @(
        @{ Value = '' }, @{ Value = '0' }, @{ Value = '0000000' }, @{ Value = 'None' }
        @{ Value = 'Default string' }, @{ Value = 'To be filled by O.E.M.' }, @{ Value = 'System Serial Number' }
        @{ Value = 'Not Specified' }, @{ Value = 'N/A' }, @{ Value = 'NA' }, @{ Value = 'Chassis Serial Number' }
    ) {
        Test-JunkSerial $Value | Should -BeTrue
    }
    It 'accepts real serial "<Value>"' -TestCases @(
        @{ Value = '5CG1234XYZ' }, @{ Value = 'PF3ABCDE' }, @{ Value = '0001' }, @{ Value = 'NAB123' }
    ) {
        Test-JunkSerial $Value | Should -BeFalse
    }
}

Describe 'Get-LaptopModelString' {
    It '<Case>' -TestCases @(
        @{ Case = 'HP: vendor already in model, SKU appended'
           Mfg = 'HP'; Model = 'HP EliteBook 840 G8 Notebook PC'; Version = ''; Sku = '3C8M3EA#ABB'
           Expected = 'HP EliteBook 840 G8 Notebook PC (3C8M3EA#ABB)' }
        @{ Case = 'Lenovo: Version is the name, Model the machine type'
           Mfg = 'LENOVO'; Model = '21CBS0AB00'; Version = 'ThinkPad T14 Gen 3'; Sku = 'LENOVO_MT_21CB'
           Expected = 'Lenovo ThinkPad T14 Gen 3 (21CBS0AB00)' }
        @{ Case = 'Dell: vendor prefixed'
           Mfg = 'Dell Inc.'; Model = 'Latitude 5440'; Version = ''; Sku = '0C1B'
           Expected = 'Dell Latitude 5440 (0C1B)' }
        @{ Case = 'junk SKU omitted, unknown vendor kept as is'
           Mfg = ' Micro-Star International Co., Ltd. '; Model = 'Modern 14'; Version = ''; Sku = 'Default string'
           Expected = 'Micro-Star International Co., Ltd. Modern 14' }
        @{ Case = 'SKU equal to model omitted'
           Mfg = 'Microsoft Corporation'; Model = 'Surface Laptop 5'; Version = ''; Sku = 'Surface Laptop 5'
           Expected = 'Microsoft Surface Laptop 5' }
        @{ Case = 'empty SKU'
           Mfg = 'ASUSTeK COMPUTER INC.'; Model = 'ExpertBook B1402CVA'; Version = ''; Sku = ''
           Expected = 'ASUS ExpertBook B1402CVA' }
    ) {
        Get-LaptopModelString -Manufacturer $Mfg -Model $Model -Version $Version -Sku $Sku | Should -BeExactly $Expected
    }
}

Describe 'Test-InternalDisk' {
    It '<BusType> fixed=<Fixed> size=<Size> -> <Expected>' -TestCases @(
        @{ BusType = 'NVMe'; Size = 512e9; Fixed = $true; Expected = $true }
        @{ BusType = 'SATA'; Size = 1e12;  Fixed = $true; Expected = $true }
        @{ BusType = 'RAID'; Size = 512e9; Fixed = $true; Expected = $true }
        @{ BusType = 'MMC';  Size = 64e9;  Fixed = $true; Expected = $true }
        @{ BusType = 'SD';   Size = 128e9; Fixed = $true; Expected = $true }
        @{ BusType = 'SD';   Size = 128e9; Fixed = $false; Expected = $false }
        @{ BusType = 'MMC';  Size = 64e9;  Fixed = $false; Expected = $false }
        @{ BusType = 'USB';  Size = 32e9;  Fixed = $true; Expected = $false }
        @{ BusType = 'File Backed Virtual'; Size = 1e9; Fixed = $true; Expected = $false }
        @{ BusType = 'NVMe'; Size = 0;     Fixed = $true; Expected = $false }
    ) {
        Test-InternalDisk -BusType $BusType -Size $Size -IsFixedMedia $Fixed | Should -Be $Expected
    }
}

Describe 'Get-DiskTypeLabel' {
    It '<BusType>/<MediaType>/"<Name>" -> <Expected>' -TestCases @(
        @{ BusType = 'NVMe'; MediaType = 'Unspecified'; Name = 'KXG60ZNV512G';          Expected = 'NVMe SSD' }
        @{ BusType = 'SATA'; MediaType = 'SSD';         Name = 'Samsung SSD 870';       Expected = 'SATA SSD' }
        @{ BusType = 'SATA'; MediaType = 'HDD';         Name = 'ST1000LM035';           Expected = 'SATA HDD' }
        @{ BusType = 'RAID'; MediaType = 'SSD';         Name = 'NVMe INTEL SSDPEKNW51'; Expected = 'NVMe SSD' }
        @{ BusType = 'RAID'; MediaType = 'Unspecified'; Name = 'x NVMe Micron 2450';    Expected = 'NVMe SSD' }
        @{ BusType = 'RAID'; MediaType = 'SSD';         Name = 'Samsung SSD 980 PRO';   Expected = 'SSD' }
        @{ BusType = 'RAID'; MediaType = 'Unspecified'; Name = 'Volume0';               Expected = 'RAID' }
        @{ BusType = 'MMC';  MediaType = 'Unspecified'; Name = 'BJTD4R';                Expected = 'eMMC' }
        @{ BusType = 'SD';   MediaType = 'Unspecified'; Name = 'DA4064';                Expected = 'eMMC' }
        @{ BusType = 'SAS';  MediaType = 'Unspecified'; Name = 'x';                     Expected = 'SAS' }
    ) {
        Get-DiskTypeLabel -BusType $BusType -MediaType $MediaType -Name $Name | Should -BeExactly $Expected
    }
}

Describe 'Format-StorageType' {
    It 'one disk: type only' {
        Format-StorageType -Disks @([pscustomobject]@{ Type = 'NVMe SSD'; Gb = 512 }) | Should -BeExactly 'NVMe SSD'
    }
    It 'several disks: type and size each' {
        $d = @([pscustomobject]@{ Type = 'NVMe SSD'; Gb = 512 }, [pscustomobject]@{ Type = 'SATA HDD'; Gb = 1000 })
        Format-StorageType -Disks $d | Should -BeExactly 'NVMe SSD 512 GB; SATA HDD 1000 GB'
    }
    It 'no disks: empty (script then reports storage_type missing)' {
        Format-StorageType -Disks @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-SnipeHttpError' {
    It 'includes status code and cuts the body to 300 chars' {
        $err = [pscustomobject]@{
            Exception    = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 503 }; Message = 'x' }
            ErrorDetails = [pscustomobject]@{ Message = "<html>`n" + ('a' * 1000) }
        }
        $msg = Get-SnipeHttpError -ErrorRecord $err -Method GET -Path '/hardware'
        $msg | Should -BeLike 'Snipe-IT HTTP 503 (GET /hardware): <html> aaa*...'
        $msg.Length | Should -Be ('Snipe-IT HTTP 503 (GET /hardware): '.Length + 303)
    }
    It 'reports a network error when there is no response' {
        $err = [pscustomobject]@{ Exception = [pscustomobject]@{ Response = $null; Message = 'Unable to connect' } }
        Get-SnipeHttpError -ErrorRecord $err -Method POST -Path '/hardware' |
            Should -BeExactly 'Snipe-IT network error (POST /hardware): Unable to connect'
    }
}

Describe 'Invoke-Snipe retry policy' {
    BeforeAll {
        # Read by Invoke-Snipe at call time (dynamic scope); Set-Variable because the analyzer
        # cannot see that use and would flag plain assignments as unused
        Set-Variable -Name base    -Value 'https://snipe.invalid/api/v1'
        Set-Variable -Name headers -Value @{ Accept = 'application/json' }
    }
    BeforeEach {
        Mock Start-Sleep { }
    }
    It 'GET: retries network errors, 3 attempts in total' {
        Mock Invoke-RestMethod { throw [Net.WebException]::new('unreachable') }
        { Invoke-Snipe -Method GET -Path '/x' } | Should -Throw 'Snipe-IT network error (GET /x)*'
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly
    }
    It 'GET: succeeds on a later attempt' {
        $script:calls = 0
        Mock Invoke-RestMethod {
            $script:calls++
            if ($script:calls -lt 2) { throw [Net.WebException]::new('unreachable') }
            [pscustomobject]@{ total = 1 }
        }
        (Invoke-Snipe -Method GET -Path '/x').total | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }
    It 'POST: no retry on network error (write may have happened)' {
        Mock Invoke-RestMethod { throw [Net.WebException]::new('timeout') }
        { Invoke-Snipe -Method POST -Path '/hardware' -Body @{ a = 1 } } | Should -Throw
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
    It 'status=error in a 200 body: throws, no retry' {
        Mock Invoke-RestMethod { [pscustomobject]@{ status = 'error'; messages = 'nope' } }
        { Invoke-Snipe -Method GET -Path '/x' } | Should -Throw 'Snipe-IT API error (GET /x)*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
    It '-AllowError returns the error body' {
        Mock Invoke-RestMethod { [pscustomobject]@{ status = 'error'; messages = 'nope' } }
        (Invoke-Snipe -Method GET -Path '/x' -AllowError).messages | Should -Be 'nope'
    }
    It 'passes a 30 s timeout' {
        Mock Invoke-RestMethod { [pscustomobject]@{ total = 0 } }
        Invoke-Snipe -Method GET -Path '/x' | Out-Null
        Should -Invoke Invoke-RestMethod -ParameterFilter { $TimeoutSec -eq 30 } -Times 1 -Exactly
    }
}
