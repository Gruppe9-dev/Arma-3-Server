// =============================================================================
// initServer.sqf - Headless Client setup
// Drop into your mission folder. Arma 3 executes this automatically on server.
//
// ACE3 handles Headless Client AI transfer and load balancing when
// acex_headless_enabled is enabled through CBA settings.
//
// Optional local script:
//   - hc_fps_monitor.sqf keeps Zeus-readable server/HC FPS markers.
//
// Legacy custom transfer:
//   - hc_transfer_legacy.sqf contains the previous manual setGroupOwner balancer.
//     Do not run it together with ACE Headless.
// =============================================================================

if (!isServer) exitWith {};

execVM "hc_fps_monitor.sqf";

diag_log "[HC] initServer loaded. ACE Headless is expected to handle AI balancing.";
