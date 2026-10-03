# VUT inventory

PowerShell automation for the VUT Snipe-IT instance (https://inventorius.liepu27.lt).
Agent / project context: [AGENTS.md](AGENTS.md).

## Register-SnipeAsset.ps1

Registers a prepared Windows laptop in Snipe-IT (model "VUT laptop") with CPU, RAM, storage,
OS and battery health in custom fields, then stamps the generated asset tag onto the desktop wallpaper.

### Setup

1. Put the API token into `snipeit.token` next to the script (one line, no quotes).
   The file is git-ignored — **never commit it**. Alternatives: `$env:SNIPEIT_TOKEN` or `-ApiToken`.
2. Run PowerShell **as administrator** (needed for the device-wide wallpaper).

### Usage

```powershell
# Check only: collects data, read-only API calls, wallpaper preview to %TEMP%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-SnipeAsset.ps1 -DryRun

# Register
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-SnipeAsset.ps1
```

Output is one JSON line. Exit codes: `0` created, `2` already registered (serial exists), `1` error.

Audit trail: every result line (including `-DryRun` and errors) is appended to
`C:\ProgramData\SnipeIT\register.log` as `timestamp<TAB>version<TAB>DOMAIN\user<TAB>json`.
New assets get a `notes` entry: script version, timestamp, Windows account and hostname.

| Switch / parameter | Purpose |
|---|---|
| `-DryRun` | No writes to Snipe-IT, wallpaper only previewed |
| `-NoWallpaper` | Skip wallpaper stamping |
| `-Serial <s>` | Override BIOS serial (testing). Only with `-DryRun`, otherwise exit 1 |
| `-StatusName` | Status label for new assets, resolved by name (default `Ready to Deploy`) |
| `-ModelName` | Snipe-IT model, resolved by name (default `VUT laptop`) |
| `-StatusId`, `-ModelId` | Set to skip the name lookup |
| `-Field*` | Custom field DB columns |

### Snipe-IT prerequisites

- Auto-increment asset tags ON, unique serial numbers ON
- Model "VUT laptop" with a fieldset containing the custom fields listed in AGENTS.md
- Status label "Ready to Deploy" (or pass `-StatusName` / `-StatusId`)
- Service account with: Assets view/create, Models view, Status Labels view, Self → Create API keys
