# Generate STORAGE_ENCRYPTION_KEY
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)

$storageKey = -join ($bytes | ForEach-Object {
    $_.ToString("x2")
})

# Generate OMNIROUTE_WS_BRIDGE_SECRET
$bytes2 = New-Object byte[] 32
$rng.GetBytes($bytes2)

$wsSecret = [Convert]::ToBase64String($bytes2)

$rng.Dispose()

@"
OMNIROUTE_MEMORY_MB=1024
STORAGE_ENCRYPTION_KEY=$storageKey
OMNIROUTE_WS_BRIDGE_SECRET=$wsSecret
"@ | Set-Content -Encoding ASCII .env
