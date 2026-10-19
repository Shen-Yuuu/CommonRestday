[CmdletBinding(DefaultParameterSetName = 'Summary')]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [ValidateRange(128, 512)][int]$PartLength = 512,
  [Parameter(Mandatory = $true, ParameterSetName = 'Part')][ValidateRange(0, 32)][int]$CopyPart,
  [Parameter(Mandatory = $true, ParameterSetName = 'Environment')][switch]$CopyEnvironmentJson
)

$ErrorActionPreference = 'Stop'
try {
  $pushInput = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($pushField in @('project_id', 'key_id', 'private_key', 'sub_account')) {
    if ($pushInput.$pushField -isnot [string] -or [string]::IsNullOrWhiteSpace($pushInput.$pushField)) { throw 'invalid' }
  }
  if ($pushInput.project_id -notmatch '^[0-9]+$' -or
    -not $pushInput.private_key.Contains('-----BEGIN PRIVATE KEY-----') -or
    -not $pushInput.private_key.Contains('-----END PRIVATE KEY-----')) { throw 'invalid' }
  $pushJson = [ordered]@{
    project_id = $pushInput.project_id; key_id = $pushInput.key_id
    private_key = $pushInput.private_key; sub_account = $pushInput.sub_account
  } | ConvertTo-Json -Compress
  if ([System.Text.Encoding]::UTF8.GetByteCount($pushJson) -gt 16384) { throw 'invalid' }
  $pushParts = [System.Collections.Generic.List[string]]::new()
  for ($pushOffset = 0; $pushOffset -lt $pushJson.Length; $pushOffset += $PartLength) {
    $pushParts.Add($pushJson.Substring($pushOffset, [Math]::Min($PartLength, $pushJson.Length - $pushOffset)))
  }
  if ($pushParts.Count -gt 32) { throw 'invalid' }
} catch {
  throw 'PUSH_ACCOUNT_INPUT_INVALID: Check the local file and its four required string fields. No contents were printed.'
}

$pushVariables = [ordered]@{ FORTWO_PUSH_SERVICE_ACCOUNT_PARTS = [string]$pushParts.Count }
for ($pushIndex = 0; $pushIndex -lt $pushParts.Count; $pushIndex++) {
  $pushVariables['FORTWO_PUSH_SERVICE_ACCOUNT_' + ($pushIndex + 1)] = $pushParts[$pushIndex]
}
if ($PSCmdlet.ParameterSetName -eq 'Part') {
  if ($CopyPart -gt $pushParts.Count) { throw 'PUSH_ACCOUNT_PART_OUT_OF_RANGE' }
  $pushName = if ($CopyPart -eq 0) { 'FORTWO_PUSH_SERVICE_ACCOUNT_PARTS' } else { 'FORTWO_PUSH_SERVICE_ACCOUNT_' + $CopyPart }
  Set-Clipboard -Value $pushVariables[$pushName]
  Write-Output ($pushName + ': value copied to clipboard; paste only in the cloud configuration.')
} elseif ($CopyEnvironmentJson) {
  Set-Clipboard -Value ($pushVariables | ConvertTo-Json -Compress)
  Write-Output 'Account environment JSON copied to clipboard. Merge these entries; preserve the other cloud variables.'
} else {
  Write-Output ('Parts: ' + $pushParts.Count + '; max part length: ' + $PartLength + '; no credential values printed.')
  foreach ($pushName in $pushVariables.Keys) { Write-Output ($pushName + ': ' + $pushVariables[$pushName].Length + ' characters') }
}
