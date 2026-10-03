# Snipe-IT automation — agent context

## Goal
PowerShell tooling around a self-hosted **Snipe-IT** instance (REST API v1) for:
1. **Asset auto-registration** after a Windows computer is prepared — DONE, tested on one HP laptop against live instance: `Register-SnipeAsset.ps1`
2. **Bulk checkout ("shipment") + shipment report** — TODO, design agreed, see below

Owner: IT / cybersecurity manager (Lithuania). Asset management evidence is used for ISO 27001 audits (A.5.9 inventory of assets, A.5.11 return of assets) — traceability matters.

## Environment
- Windows endpoints, **PowerShell 5.1** compatibility required (no PS7-only syntax: no `??`, no ternary, no `-Parallel`)
- Microsoft 365 / Entra ID / Intune in use
- Snipe-IT URL: `https://inventorius.liepu27.lt` (default of `-SnipeUrl`). IDs stay parameters; `StatusId = 2` still unverified
- Repo: https://github.com/Visos-Upes-Teka/VUTinventory (private)
- Locale: Lithuanian. CSV output must use **`;` separator** and UTF-8 (with BOM for Excel). User-facing document text (shipment act) in Lithuanian.

## Snipe-IT API conventions & gotchas (apply everywhere)
- Base: `{SnipeUrl}/api/v1`, header `Authorization: Bearer <token>`, `Accept: application/json` (without Accept you get an HTML redirect)
- **Logical errors return HTTP 200** with `{"status":"error","messages":...}` — always check body `status`
- Names in responses are **HTML-encoded** → `[Net.WebUtility]::HtmlDecode()` before comparing
- PS 5.1 mangles non-ASCII in request bodies → send `[Text.Encoding]::UTF8.GetBytes($json)` with `application/json; charset=utf-8`
- Force TLS 1.2: `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'`
- Default rate limit 120 req/min (`API_THROTTLE_PER_MINUTE`) — throttle/back off in loops
- Custom fields are set by DB column name (e.g. `_snipeit_cpu_1`); values are silently dropped if the model's fieldset doesn't contain the field
- **No bulk checkout endpoint** — loop `POST /hardware/{id}/checkout`
- Useful endpoints:
  - `GET /hardware/byserial/{serial}`, `GET /hardware/bytag/{tag}` — byserial not found = HTTP 200 `{"status":"error","messages":"<translated text>","payload":null}`; detect by shape, never by message text
  - `POST /hardware`, `PATCH /hardware/{id}`
  - `POST /hardware/{id}/checkout` — body: `checkout_to_type` (`user`|`location`|`asset`), `assigned_user` / `assigned_location` / `assigned_asset`, `note`, optional `checkout_at`, `expected_checkin`
  - `GET /reports/activity?search=&action_type=checkout&target_type=&target_id=`
  - `GET/POST /models`, `/manufacturers`, `/categories`, `/statuslabels`, `/locations`, `/users`

## Shared script conventions (established in Register-SnipeAsset.ps1 — keep consistent)
- Token lookup order: `-ApiToken` > `$env:SNIPEIT_TOKEN` > `snipeit.token` file next to the script (git-ignored); **never hardcode or commit**. Token belongs to a dedicated least-privilege service account.
- PowerShell variables are case-insensitive: never name a local variable like a parameter (`$modelName` overwrote `-ModelName` once)
- `$ErrorActionPreference = 'Stop'`, single top-level try/catch
- Machine-readable output: **one JSON line on stdout** + exit codes (`0` success, `1` error, `2` business "already exists"/rejected)
- `-DryRun` switch: collect + validate + read-only API calls, no writes
- Helper `Invoke-Snipe -Method -Path -Body [-AllowError]` that throws on `status=error`

## Task 1 — Register-SnipeAsset.ps1 (works; tested on one HP EliteBook)
- All laptops use one fixed Snipe-IT model **"VUT laptop"** (id 2, resolved by name, never created). Real make/model goes to custom field "Laptop model"
- Custom fields (all format ANY / free text) — DB columns:
  `_snipeit_laptop_model_8`, `_snipeit_cpu_2`, `_snipeit_ram_3` (`32 GB`), `_snipeit_storage_gb_4` (`512`, sum of internal disks incl. soldered eMMC; USB, removable SD/MMC and virtual disks excluded),
  `_snipeit_storage_type_5` (`NVMe SSD`, `eMMC`, or `SATA SSD 960 GB; NVMe SSD 2000 GB`), `_snipeit_operating_system_6` (`Windows 11 Pro 25H2`),
  `_snipeit_batery_health_7` (`87%` = FullChargeCapacity / DesignCapacity, NOT charge level; optional)
- MAC address intentionally NOT collected (user decision)
- Battery: root\wmi first, fallback `powercfg /batteryreport /xml` (HP lacks `BatteryStaticData`). Fallback untested on a real laptop yet
- Rejects junk serials (`Default string`, `To be filled by O.E.M.`, …); `-Serial` override for testing (only with `-DryRun`; enforced, exit 1 otherwise)
- Duplicate check by serial → if exists: exit 2 + existing `asset_tag`
- Creates asset without `asset_tag` (auto-increment ON, prefix `VUT`, e.g. `VUT00002`); hostname = asset name
- Stamps asset tag + hostname + S/N onto desktop wallpaper (`C:\ProgramData\SnipeIT\wallpaper.png`): admin → HKLM PersonalizationCSP (all users, locks wallpaper; UNVERIFIED on Windows Pro), non-SYSTEM → SystemParametersInfo for current user. Wallpaper failure never fails registration. `-NoWallpaper` to skip; `-DryRun` renders preview to %TEMP%
- Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-SnipeAsset.ps1 [-DryRun]` (execution policy is Restricted on endpoints)
- Possible follow-ups: `-Update` mode (PATCH custom fields of existing asset); Pester tests; retry/backoff; logging; code signing (AllSigned)

## Task 2 — Bulk checkout / shipment script (TODO)
Agreed design:
1. Input: list of asset tags (CSV or scanned list), target (user or location), **shipment ID** (e.g. `SIUNTA-2026-014`)
2. **Pre-check all items before any write** — tag exists, status deployable, not already checked out. If any item fails → abort whole shipment, report failures (no partial shipments)
3. Checkout each asset with `note` = shipment ID (this makes the shipment reconstructable from Snipe-IT activity log)
4. Generate outputs:
   - **Handover act PDF** (perdavimo–priėmimo aktas, Lithuanian): shipment ID, date, recipient, table (asset tag, serial, model, CPU/RAM/storage), signature lines for sender and recipient
   - **CSV** (`;`, UTF-8 BOM) for archive
5. Separate mode/script to **regenerate the report from Snipe-IT** by shipment ID via `/reports/activity?search=<ID>&action_type=checkout`
6. `-DryRun`, JSON result line, exit codes as above; partial failure during checkout loop must be reported explicitly (list succeeded vs failed IDs)

**Open questions — ask the user before implementing:**
- Typical target: **user** or **location** (branch/client)? (support both if cheap)
- Handover act template: existing template (Confluence/Word) or design new?
- PDF generation method acceptable on their machines (HTML→PDF via Edge headless `msedge --headless --print-to-pdf`, or other)?

## Working style expected by the user
- Concise, technical, no fluff; recommend one option with justification rather than listing neutral options
- Communicate with the user in **Lithuanian**; code, comments and identifiers in English
- Flag weak assumptions; mark anything not verified against the live API as untested
