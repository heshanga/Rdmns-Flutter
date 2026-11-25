<?php
/**
 * ----------------------------------------------------------------------
 * Rdmns App - 60-Second Time-Based Dynamic Token Verification Script
 * ----------------------------------------------------------------------
 */

$SECRET_KEY = "Rdmns_App_Secure_Key_2026";

// Extract device ID & token from URL parameters OR HTTP Headers
$headers = getallheaders();
$deviceId = $_GET['device_id'] ?? $headers['X-Device-Token'] ?? $headers['x-device-token'] ?? '';
$clientToken = $_GET['token'] ?? $headers['X-Dynamic-Token'] ?? $headers['x-dynamic-token'] ?? '';
$clientTimeSlot = $_GET['ts'] ?? $headers['X-Time-Slot'] ?? $headers['x-time-slot'] ?? null;

if (empty($deviceId) || empty($clientToken)) {
    http_response_code(403);
    header('Content-Type: application/json');
    echo json_encode([
        "status" => "error",
        "message" => "Access Denied: Missing Rdmns Device Token."
    ]);
    exit();
}

// Current 60-second time slot
$currentTimeSlot = floor(time() / 60);

function generateExpectedToken($secretKey, $slot, $deviceId) {
    $raw = $secretKey . "_" . $slot . "_" . $deviceId;
    return strtoupper(substr(hash('sha256', $raw), 0, 16));
}

// Verify with ±1 minute clock drift tolerance
$isValid = false;
for ($offset = -1; $offset <= 1; $offset++) {
    $targetSlot = $currentTimeSlot + $offset;
    $expectedToken = generateExpectedToken($SECRET_KEY, $targetSlot, $deviceId);
    
    if (hash_equals($expectedToken, strtoupper($clientToken))) {
        $isValid = true;
        break;
    }
}

if (!$isValid) {
    http_response_code(403);
    header('Content-Type: application/json');
    echo json_encode([
        "status" => "error",
        "message" => "Access Denied: Invalid or Expired Dynamic Security Token.",
        "server_time_slot" => $currentTimeSlot
    ]);
    exit();
}
?>
