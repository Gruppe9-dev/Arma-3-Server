// =============================================================================
// CBA / ACE3 Server Settings – Profile: main
// Loaded automatically by CBA on server start from the userconfig\ folder.
// Reference: https://ace3.acemod.org/wiki/framework/settings-system.html
//
// Syntax:  force <setting_name> = <value>;
//   "force" overrides client-side settings so players cannot change them.
//   Remove "force" to allow players to change the setting locally.
// =============================================================================

// ---------------------------------------------------------------------------
// ACE Medical
// ---------------------------------------------------------------------------
force ace_medical_level                 = 2;    // 0=basic, 1=basic+, 2=advanced
force ace_medical_enableRevive          = 1;    // 0=off, 1=incapacitation, 2=full revive
force ace_medical_maxReviveTime         = 600;  // seconds before patient dies in revive state
force ace_medical_maxReviveTimeCoeff    = 1;
force ace_medical_allowSelfStitch       = false;
force ace_medical_allowLimbClamping     = true;
force ace_medical_unconciousnessChance  = 0.7;  // 0–1: chance of being KO'd by injury
force ace_medical_clearTrauma           = true; // clear trauma after treatment
force ace_medical_fractures             = 1;    // 0=off, 1=on

// ---------------------------------------------------------------------------
// ACE Respawn (if mission uses ACE respawn module)
// ---------------------------------------------------------------------------
force ace_respawn_removeDeadBodiesDisconnected = true;

// ---------------------------------------------------------------------------
// ACE General
// ---------------------------------------------------------------------------
force ace_nametags_enabled              = false; // disable nametags (we have friendly tags off)
force ace_gestures_enabled              = true;
force ace_fatigueEnabled                = true;
force ace_movement_overrideHighReady    = false;

// ---------------------------------------------------------------------------
// ACE Map / GPS
// ---------------------------------------------------------------------------
force ace_map_BFT_enabled               = false; // no Blue Force Tracker
force ace_map_BFT_showPlayerNames       = false;
force ace_map_mapGlow                   = true;
force ace_map_defaultChannel            = 0;

// ---------------------------------------------------------------------------
// ACE Interaction
// ---------------------------------------------------------------------------
force ace_interaction_enableTeamManagement = true;
force ace_interaction_enableTacticalAwareness = false;

// ---------------------------------------------------------------------------
// ACE Misc
// ---------------------------------------------------------------------------
force ace_dragging_enabled              = true;
force ace_carrying_enabled              = true;
force ace_weaponrest_enabled            = true;
force ace_ballistics_enabled            = true;  // advanced ballistics (windage, drag)
force ace_missileguidance_enabled       = true;
force ace_laser_enabled                 = true;
force ace_nightvision_adjustment        = true;
