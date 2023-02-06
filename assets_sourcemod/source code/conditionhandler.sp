#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <dhooks>
#include <kocwtools>

#define DEBUG

public Plugin myinfo =
{
	name = "Condition Handler",
	author = "Noclue",
	description = "Core plugin for custom conditions.",
	version = "1.0",
	url = "https://github.com/Reagy/TF2Classic-KO-Custom-Weapons"
}

//TODO: Shield parenting could be better

enum {
	TFCC_TOXIN = 0,
	TFCC_TOXINUBER,
	TFCC_TOXINPATIENT,

	TFCC_ANGELSHIELD,
	TFCC_ANGELINVULN,

	TFCC_QUICKUBER,

	TFCC_LAST
}
const int COND_BITFIELDS = (TFCC_LAST / 32) + 1;

enum struct EffectProps {
	int	iLevel;		//condition strength

	Handle 	hTick;		//handle of the timer that ticks the effect
	float	flRemoveTime;	//time until effect expires

	int	iEffectSource; 	//player that caused effect
	int	iEffectWeapon; 	//weapon that caused effect
}

EffectProps	ePlayerConds[MAXPLAYERS+1][TFCC_LAST];
int		iPlayerCondFlags[MAXPLAYERS+1][COND_BITFIELDS];

//0 contains the index of the shield, 1 contains the material manager used for the damage effect
int g_iAngelShields[MAXPLAYERS+1][2];

DynamicHook hTakeHealth;
DynamicDetour hHealConds;

Handle hCallTakeHealth;
Handle hGetBuffedMaxHealth;

bool bLateLoad;
public APLRes AskPluginLoad2( Handle myself, bool bLate, char[] error, int err_max ) {
	CreateNative( "AddCustomCond", Native_AddCond );
	CreateNative( "RemoveCustomCond", Native_RemoveCond );

	CreateNative( "HasCustomCond", Native_HasCond );

	CreateNative( "GetCustomCondLevel", Native_GetCondLevel );
	CreateNative( "SetCustomCondLevel", Native_SetCondLevel );

	CreateNative( "GetCustomCondDuration", Native_GetCondDuration );
	CreateNative( "SetCustomCondDuration", Native_SetCondDuration );

	CreateNative( "GetCustomCondSourcePlayer", Native_GetCondSourcePlayer );
	CreateNative( "SetCustomCondSourcePlayer", Native_SetCondSourcePlayer );

	CreateNative( "GetCustomCondSourceWeapon", Native_GetCondSourceWeapon );
	CreateNative( "SetCustomCondSourceWeapon", Native_SetCondSourceWeapon );

	bLateLoad = bLate;

	return APLRes_Success;
}

public void OnGameFrame() {
	ManageAngelShields();
}

public void OnPluginStart() {
	Handle hGameConf = LoadGameConfigFile( "kocw.gamedata" );

	hTakeHealth = DynamicHook.FromConf( hGameConf, "CTFPlayer::TakeHealth" );
	hHealConds = DynamicDetour.FromConf( hGameConf, "CTFPlayerShared::HealNegativeConds" );
	hHealConds.Enable( Hook_Post, Detour_HealNegativeConds );

	StartPrepSDKCall( SDKCall_Entity );
	PrepSDKCall_SetFromConf( hGameConf, SDKConf_Virtual, "CTFPlayer::TakeHealth" );
	PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
	PrepSDKCall_AddParameter( SDKType_Float, SDKPass_Plain );
	PrepSDKCall_AddParameter( SDKType_PlainOldData, SDKPass_Plain );
	hCallTakeHealth = EndPrepSDKCall();

	StartPrepSDKCall( SDKCall_Raw );
	PrepSDKCall_SetFromConf( hGameConf, SDKConf_Signature, "CTFPlayerShared::GetBuffedMaxHealth" );
	PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
	hGetBuffedMaxHealth = EndPrepSDKCall();

	if( !bLateLoad )
		return;

	for( int i = 0; i < MAXPLAYERS+1; i++ ) {
		g_iAngelShields[i][0] = -1;
		g_iAngelShields[i][1] = -1;
	}

	//lateload
	for( int i = 1; i <= MaxClients; i++ ) {
		if( !IsValidEdict( i ) )
			continue;
		
		DoPlayerHooks( i );
	}

	delete hGameConf;

#if defined DEBUG
	RegConsoleCmd( "sm_cond_test", Command_Test, "test");
#endif
}

public void OnClientConnected( int iClient ) {
	if( IsValidEdict( iClient ) )
		RequestFrame( DoPlayerHooks, iClient );
}

void DoPlayerHooks( int iPlayer ) {
	hTakeHealth.HookEntity( Hook_Pre, iPlayer, Hook_TakeHealth );
}

public void OnMapStart() {
	PrecacheSound( "items/powerup_pickup_plague_infected_loop.wav" );
	PrecacheSound( "weapons/buffed_off.wav" );
	PrecacheModel( "models/effects/resist_shield/resist_shield.mdl" );
}

#if defined DEBUG
Action Command_Test( int iClient, int iArgs ) {
	if(iArgs < 1) return Plugin_Handled;

	int iCondIndex = GetCmdArgInt( 1 );
	for( int i = 1; i <= MaxClients; i++ ) {
		if( IsClientInGame( i ) ) {
			AddCond( i, iCondIndex );
			SetCondDuration( i, iCondIndex, 10.0, false );
		}
			
	}
	
	return Plugin_Handled;
}
#endif

int GetFlagArrayOffset( int iCond ) {
	if( iCond == 0 ) return 0;
	return ( iCond / 32 );
}
int GetFlagArrayBit( int iCond ) {
	int iIndex = iCond % 32 ;
	return ( 1 << iIndex );
}

bool IsNegativeCond( int iCond ) {
	return iCond == TFCC_TOXIN;
}

/*
	Copious amounts of boilerplate
*/

//native bool TFCC_AddCond( int player, int effect )
public any Native_AddCond( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	return AddCond( iPlayer, iEffect );
}
bool AddCond( int iPlayer, int iCond ) {
	if( iCond < 0 || iCond >= TFCC_LAST )
		return false;

	if( HasCond( iPlayer, iCond ) ) 
		return false;
	if( IsNegativeCond( iCond ) && ( HasCond( iPlayer, TFCC_ANGELSHIELD ) || HasCond( iPlayer, TFCC_ANGELINVULN ) ) )
		return false;

	bool bGaveCond = false;
	switch( iCond ) {
	case TFCC_TOXIN: {
		AddToxin( iPlayer );
		bGaveCond = true;
	}
	case TFCC_TOXINPATIENT: {
		AddToxinPatient( iPlayer );
		bGaveCond = true;
	}
	case TFCC_ANGELSHIELD: {
		AddAngelShield( iPlayer );
		bGaveCond = true;
	}
	case TFCC_ANGELINVULN: {
		AddAngelInvuln( iPlayer );
		bGaveCond = true;
	}
	case TFCC_QUICKUBER: {
		bGaveCond = AddQuickUber( iPlayer );
	}
	case TFCC_TOXINUBER: {
		bGaveCond = AddToxinUber( iPlayer );
	}
	}

	if( bGaveCond ) {
		int iBit = GetFlagArrayBit( iCond );
		int iOffset = GetFlagArrayOffset( iCond );
		iPlayerCondFlags[ iPlayer ][ iOffset ] |= iBit;

		ePlayerConds[iPlayer][iCond].flRemoveTime = GetGameTime();
	}

	return bGaveCond;
}

public any Native_HasCond( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	return HasCond( iPlayer, iEffect );
}
bool HasCond( int iPlayer, int iCond ) {
	int iFlag = GetFlagArrayBit( iCond );
	int iOffset = GetFlagArrayOffset( iCond );

	return iPlayerCondFlags[iPlayer][iOffset] & iFlag != 0;
}

public any Native_RemoveCond( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);

	return RemoveCond( iPlayer, iEffect );
}
bool RemoveCond( int iPlayer, int iCond ) {
	if( iCond < 0 || iCond >= TFCC_LAST )
		return false;

	if( !HasCond( iPlayer, iCond ) )
		return false;

	switch(iCond) {
	case TFCC_TOXIN: {
		RemoveToxin( iPlayer );
	}
	/*case TFCC_TOXINPATIENT: {
	}*/
	case TFCC_ANGELSHIELD: {
		RemoveAngelShield( iPlayer );
	}
	/*case TFCC_ANGELINVULN: {
		RemoveAngelInvuln( iPlayer );
	}*/
	case TFCC_QUICKUBER: {
		RemoveQuickUber( iPlayer );
	}
	case TFCC_TOXINUBER: {
		RemoveToxinUber( iPlayer );
	}
	}

	if( IsValidHandle( ePlayerConds[iPlayer][iCond].hTick ) ) {
		KillTimer(ePlayerConds[iPlayer][iCond].hTick);
		ePlayerConds[iPlayer][iCond].hTick = null;
	}
	ePlayerConds[iPlayer][iCond].iLevel =		0;
	ePlayerConds[iPlayer][iCond].flRemoveTime =	0.0;
	ePlayerConds[iPlayer][iCond].iEffectSource =	INVALID_ENT_REFERENCE;
	ePlayerConds[iPlayer][iCond].iEffectWeapon =	INVALID_ENT_REFERENCE;

	int iBit = GetFlagArrayBit( iCond );
	int iOffset = GetFlagArrayOffset( iCond );

	iPlayerCondFlags[ iPlayer ][ iOffset ] &= ~iBit;

	return true;
}

//cond level
public any Native_GetCondLevel( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);

	return GetCondLevel( iPlayer, iEffect );
}
int GetCondLevel( int iPlayer, int iCond ) {
	return ePlayerConds[iPlayer][iCond].iLevel;
}
public any Native_SetCondLevel( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	int iLevel =  GetNativeCell(3);

	SetCondLevel( iPlayer, iEffect, iLevel);
	return 0;
}
void SetCondLevel( int iPlayer, int iCond, int iNewLevel ) {
	ePlayerConds[iPlayer][iCond].iLevel = iNewLevel;
}

//cond duration
public any Native_GetCondDuration( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);

	return GetCondDuration( iPlayer, iEffect );
}
float GetCondDuration( int iPlayer, int iCond ) {
	return ePlayerConds[iPlayer][iCond].flRemoveTime - GetGameTime();
}
public any Native_SetCondDuration( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	float iDuration = GetNativeCell(3);
	bool bAdd = GetNativeCell(4);

	SetCondDuration( iPlayer, iEffect, iDuration, bAdd );
	return 0;
}
void SetCondDuration( int iPlayer, int iCond, float flDuration, bool bAdd = false ) {
	ePlayerConds[iPlayer][iCond].flRemoveTime = bAdd ? ePlayerConds[iPlayer][iCond].flRemoveTime + flDuration : GetGameTime() + flDuration;
}

//cond player source
public any Native_GetCondSourcePlayer( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);

	return GetCondSourcePlayer( iPlayer, iEffect );
}
int GetCondSourcePlayer( int iPlayer, int iCond ) {
	return EntRefToEntIndex( ePlayerConds[iPlayer][iCond].iEffectSource );
}
public any Native_SetCondSourcePlayer( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	int iSource = GetNativeCell(3);

	SetCondSourcePlayer( iPlayer, iEffect, iSource );
	return 0;
}
void SetCondSourcePlayer( int iPlayer, int iCond, int iSource ) {
	ePlayerConds[iPlayer][iCond].iEffectSource = EntIndexToEntRef( iSource );
}

//cond weapon source
public any Native_GetCondSourceWeapon( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);

	return GetCondSourceWeapon( iPlayer, iEffect );
}
int GetCondSourceWeapon( int iPlayer, int iCond ) {
	return EntRefToEntIndex( ePlayerConds[iPlayer][iCond].iEffectWeapon );
}
public any Native_SetCondSourceWeapon( Handle hPlugin, int iNumParams ) {
	int iPlayer = GetNativeCell(1);
	int iEffect = GetNativeCell(2);
	int iWeapon = GetNativeCell(3);

	SetCondSourceWeapon( iPlayer, iEffect, iWeapon );
	return 0;
}
void SetCondSourceWeapon( int iPlayer, int iCond, int iWeapon ) {
	ePlayerConds[iPlayer][iCond].iEffectWeapon = EntIndexToEntRef( iWeapon );
}

/*

*/

MRESReturn Detour_HealNegativeConds( Address aThis, DHookReturn hReturn ) {
	bool bRemovedCond = hReturn.Value;
	int iPlayer = GetPlayerFromShared( aThis );
	if( HasCond( iPlayer, TFCC_TOXIN ) ) {
		RemoveCond( iPlayer, TFCC_TOXIN );
		bRemovedCond = true;
	}
		
	hReturn.Value = bRemovedCond;
	return MRES_ChangedOverride;
}

/*
	TOXIN
*/

static char szToxinParticle[] = "toxin_particles";
int g_iToxinEmitters[MAXPLAYERS+1] = { -1, ... };

const float	TOXIN_FREQUENCY		= 0.5; //tick interval in seconds
const float	TOXIN_DAMAGE		= 2.0; //damage per tick
const float	TOXIN_HEALING_MULT	= 0.5; //multiplier for healing while under toxin

bool AddToxin( int iPlayer ) {
	ePlayerConds[iPlayer][TFCC_TOXIN].hTick = CreateTimer( TOXIN_FREQUENCY, TickToxin, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	EmitSoundToAll( "items/powerup_pickup_plague_infected_loop.wav",  iPlayer, SNDCHAN_STATIC );

	SetCondDuration( iPlayer, TFCC_TOXIN, 0.0, false );

	RemoveToxinEmitter( iPlayer );

	//int iTeam = GetEntProp( iPlayer, Prop_Send, "m_iTeamNum" ) - 2;
	int iEmitter = CreateEntityByName( "info_particle_system" );
	DispatchKeyValue( iEmitter, "effect_name", szToxinParticle );

	float vecPos[3]; GetClientAbsOrigin( iPlayer, vecPos );
	TeleportEntity( iEmitter, vecPos );

	ParentModel( iEmitter, iPlayer );

	DispatchSpawn( iEmitter );
	ActivateEntity( iEmitter );
	AcceptEntityInput( iEmitter, "Start" );

	g_iToxinEmitters[iPlayer] = EntIndexToEntRef( iEmitter );
	return true;
}

void RemoveToxinEmitter( int iPlayer ) {
	int iEmitter = EntRefToEntIndex( g_iToxinEmitters[iPlayer] );
	if( iEmitter != -1 ) {
		RemoveEntity( iEmitter );
	}
	g_iToxinEmitters[iPlayer] = -1;
}

Action TickToxin( Handle hTimer, int iPlayer ) {
	if( !IsClientInGame( iPlayer ) || !IsPlayerAlive( iPlayer ) ) {
		RemoveCond( iPlayer, TFCC_TOXIN );
		return Plugin_Stop;
	}

	if( ePlayerConds[iPlayer][TFCC_TOXIN].flRemoveTime <= GetGameTime() ) {
		RemoveCond( iPlayer, TFCC_TOXIN );
		return Plugin_Stop;
	}

	int iDamagePlayer = GetCondSourcePlayer( iPlayer, TFCC_TOXIN );
	int iDamageWeapon = GetCondSourceWeapon( iPlayer, TFCC_TOXIN );

	if( iDamagePlayer == -1 )
		iDamagePlayer = 0;
	if( iDamageWeapon == -1 )
		iDamageWeapon = 0;
	
	//todo: prevent this from applying more toxin
	SDKHooks_TakeDamage( iPlayer, iDamagePlayer, iDamagePlayer, TOXIN_DAMAGE, DMG_SLASH, iDamageWeapon );

	
	ePlayerConds[iPlayer][TFCC_TOXIN].hTick = CreateTimer( MinFloat( GetCondDuration( iPlayer, TFCC_TOXIN ), TOXIN_FREQUENCY ), TickToxin, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	
	return Plugin_Continue;
}

void RemoveToxin( int iPlayer ) {
	StopSound( iPlayer, SNDCHAN_STATIC, "items/powerup_pickup_plague_infected_loop.wav" );
	RemoveToxinEmitter( iPlayer );
}

float flHealthBuffer[MAXPLAYERS+1] = { 0.0, ... }; //buffer for health cut off by rounding
//name is misleading, TakeHealth is used to RESTORE health because valve
MRESReturn Hook_TakeHealth( int iThis, DHookReturn hReturn, DHookParam hParams ) {
	if( !IsValidPlayer( iThis ) )
		return MRES_Ignored;

	if( !HasCond( iThis, TFCC_TOXIN ) )
		return MRES_Ignored;

	float	flAddHealth = hParams.Get( 1 );
	//int	iDamageFlags = hParams.Get( 1 ); //don't need these for anything yet

	flAddHealth *= TOXIN_HEALING_MULT;

	//need to buffer values below 1 since otherwise they get rounded out
	flAddHealth += flHealthBuffer[ iThis ];
	int iRoundedHealth = RoundToFloor( flAddHealth );
	flHealthBuffer[ iThis ] = flAddHealth - float( iRoundedHealth );

	hParams.Set( 1, flAddHealth );

	return MRES_ChangedHandled;
}

void ToxinTakeDamage( TFDamageInfo tfInfo ) {
	int iAttacker = tfInfo.iAttacker;
	if( !IsValidPlayer( iAttacker ) )
		return;
	
	if( HasCond( iAttacker, TFCC_TOXINPATIENT ) ) {
		tfInfo.iCritType = CT_MINI;
	}
}

void CheckApplyToxin( int iTarget, TFDamageInfo tfInfo ) {
	int iAttacker = tfInfo.iAttacker;
	int iWeapon = tfInfo.iWeapon;

	if( !IsValidPlayer(iAttacker) )
		return;

	float flAttrib = AttribHookFloat( 0.0, iWeapon, "custom_onhit_toxin" );
	if( flAttrib == 0.0 )
		return;

	if( tfInfo.flDamage > 0.0 ) {
		AddCond( iTarget, TFCC_TOXIN );

		float flCurrentDuration = GetCondDuration( iTarget, TFCC_TOXIN );
		float flNewDuration = MinFloat( flCurrentDuration + flAttrib, 10.0 );

		SetCondDuration( iTarget, TFCC_TOXIN, flNewDuration );
		SetCondSourcePlayer( iTarget, TFCC_TOXIN, iAttacker );
		SetCondSourceWeapon( iTarget, TFCC_TOXIN, iWeapon );
	}
}

/*
	TOXIN UBER
*/

#define TOXINUBER_PULSERATE 0.5
static char szToxinUberParticles[][] = {
	"biowastepump_uber_red",
	"biowastepump_uber_blue",
	"biowastepump_uber_green",
	"biowastepump_uber_yellow"
};

int g_iToxinUberEmitters[MAXPLAYERS+1] = { -1, ... };

bool AddToxinUber( int iPlayer ) {
	RemoveToxinUberEmitter( iPlayer );
	ePlayerConds[iPlayer][TFCC_TOXINUBER].hTick = CreateTimer( TOXINUBER_PULSERATE, TickToxinUber, iPlayer, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT );

	int iTeam = GetEntProp( iPlayer, Prop_Send, "m_iTeamNum" ) - 2;
	int iEmitter = CreateEntityByName( "info_particle_system" );
	DispatchKeyValue( iEmitter, "effect_name", szToxinUberParticles[ iTeam ] );

	float vecPos[3]; GetClientAbsOrigin( iPlayer, vecPos );
	TeleportEntity( iEmitter, vecPos );

	ParentModel( iEmitter, iPlayer );

	DispatchSpawn( iEmitter );
	ActivateEntity( iEmitter );
	AcceptEntityInput( iEmitter, "Start" );

	g_iToxinUberEmitters[iPlayer] = EntIndexToEntRef( iEmitter );

	return true;
}
Action TickToxinUber( Handle hTimer, int iPlayer ) {
	float vecSource[3]; GetClientAbsOrigin( iPlayer, vecSource );

	int iTarget = -1;
	while ( ( iTarget = FindEntityInSphere( iTarget, vecSource, 150.0 ) ) != -1 ) {
		if( !IsValidPlayer( iTarget ) )
			continue;

		if( TF2_GetClientTeam( iTarget ) == TF2_GetClientTeam( iPlayer ) )
			continue;

		AddCond( iTarget, TFCC_TOXIN );
		SetCondDuration( iTarget, TFCC_TOXIN, 2.0, true );

		int iSourcePlayer = GetCondSourcePlayer( iPlayer, TFCC_TOXINUBER );
		if( iSourcePlayer != -1 )
			SetCondSourcePlayer( iTarget, TFCC_TOXIN, iSourcePlayer );

		int iSourceWeapon = GetCondSourceWeapon( iPlayer, TFCC_TOXINUBER );
		if( iSourceWeapon != -1 )
			SetCondSourceWeapon( iTarget, TFCC_TOXIN, iSourceWeapon );
	}

	return Plugin_Continue;
}
void RemoveToxinUber( int iPlayer ) {
	RemoveToxinUberEmitter( iPlayer );
}

void RemoveToxinUberEmitter( int iPlayer ) {
	int iEmitter = EntRefToEntIndex( g_iToxinUberEmitters[ iPlayer ] );
	if( iEmitter != -1 )
		RemoveEntity( iEmitter );

	g_iToxinUberEmitters[ iPlayer ] = -1;
}

/*
	TOXIN PATIENT
*/

bool AddToxinPatient( int iPlayer ) {
	ePlayerConds[iPlayer][TFCC_TOXINPATIENT].hTick = CreateTimer( TOXIN_FREQUENCY, TickToxinPatient, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	return true;
}
Action TickToxinPatient( Handle hTimer, int iPlayer ) {
	if( !IsClientInGame( iPlayer ) || !IsPlayerAlive( iPlayer ) ) {
		RemoveCond( iPlayer, TFCC_TOXINPATIENT );
		return Plugin_Stop;
	}

	if( ePlayerConds[iPlayer][TFCC_TOXINPATIENT].flRemoveTime <= GetGameTime() ) {
		RemoveCond( iPlayer, TFCC_TOXINPATIENT );
		return Plugin_Stop;
	}
	ePlayerConds[iPlayer][TFCC_TOXINPATIENT].hTick = CreateTimer( MinFloat( GetCondDuration( iPlayer, TFCC_TOXINPATIENT ), TOXIN_FREQUENCY ), TickToxinPatient, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	
	return Plugin_Continue;
}

/*
	ANGEL SHIELD
*/

const int ANGSHIELD_HEALTH = 120;
const float ANGSHIELD_DURATION = 3.0;

float g_flLastDamagedShield[MAXPLAYERS+1];

static char szShieldMats[][] = {
	"models/effects/resist_shield/resist_shield",
	"models/effects/resist_shield/resist_shield_blue",
	"models/effects/resist_shield/resist_shield_green",
	"models/effects/resist_shield/resist_shield_yellow"
};

static char szShieldOverlays[][] = {
	"effects/invuln_overlay_red",
	"effects/invuln_overlay_blue",
	"effects/invuln_overlay_green",
	"effects/invuln_overlay_yellow"
};

int GetAngelShield( int iPlayer, int iType ) {
	return EntRefToEntIndex( g_iAngelShields[iPlayer][iType] );
}

bool AddAngelShield( int iPlayer ) {
	ePlayerConds[iPlayer][TFCC_ANGELSHIELD].hTick = CreateTimer( ANGSHIELD_DURATION, ExpireAngelShield, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	ePlayerConds[iPlayer][TFCC_ANGELSHIELD].iLevel = ANGSHIELD_HEALTH;

	g_flLastDamagedShield[iPlayer] = GetGameTime();

	if( IsValidEntity( GetAngelShield( iPlayer, 0 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 0 ) );
	}
	if( IsValidEntity( GetAngelShield( iPlayer, 1 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 1 ) );
	}

	int iNewShield = CreateEntityByName( "prop_dynamic" );
	SetEntityModel( iNewShield, "models/effects/resist_shield/resist_shield.mdl" );
	SetEntityCollisionGroup( iNewShield, 0 );
	DispatchKeyValue( iNewShield, "disableshadows", "1" );
	SetEntPropEnt( iNewShield, Prop_Send, "m_hOwnerEntity", iPlayer );

	int iTeamNum = GetEntProp( iPlayer, Prop_Send, "m_iTeamNum" ) - 2;
	SetEntProp( iNewShield, Prop_Send, "m_nSkin", iTeamNum );

	SDKHook( iNewShield, SDKHook_SetTransmit, Hook_NewShield );

	DispatchSpawn( iNewShield );
	g_iAngelShields[iPlayer][0] = EntIndexToEntRef( iNewShield );

	int iNewManager = CreateEntityByName( "material_modify_control" );

	ParentModel( iNewManager, iNewShield );

	DispatchKeyValue( iNewManager, "materialName", szShieldMats[iTeamNum] );
	DispatchKeyValue( iNewManager, "materialVar", "$shield_falloff" );

	DispatchSpawn( iNewManager );
	g_iAngelShields[iPlayer][1] = EntIndexToEntRef( iNewManager );

	TF2_RemoveCondition( iPlayer, TFCond_Bleeding );
	TF2_RemoveCondition( iPlayer, TFCond_OnFire );
	TF2_RemoveCondition( iPlayer, TFCond_KingRune ); //tranq
	RemoveCond( iPlayer, TFCC_TOXIN );

	static char szCommand[64];
	Format( szCommand, sizeof(szCommand), "r_screenoverlay %s", szShieldOverlays[iTeamNum] );

	ClientCommand( iPlayer, szCommand ); 

	return true;
}
Action ExpireAngelShield( Handle hTimer, int iPlayer ) {
	RemoveCond( iPlayer, TFCC_ANGELSHIELD );

	return Plugin_Stop;
}
void RemoveAngelShield( int iPlayer ) {
	bool bBroken = ePlayerConds[iPlayer][TFCC_ANGELSHIELD].iLevel <= 0;
	//TF2_RemoveCondition( iPlayer, TFCond_UberchargedOnTakeDamage );

	if( bBroken ) {
		AddCond( iPlayer, TFCC_ANGELINVULN );
		CreateTimer( ANGINVULN_DURATION, RemoveAngelShield2, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
		return;
	}

	ClientCommand( iPlayer, "r_screenoverlay 0");
	EmitSoundToAll( "weapons/buffed_off.wav", iPlayer, SNDCHAN_AUTO, 100 );

	if( IsValidEntity( GetAngelShield( iPlayer, 0 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 0 ) );
	}
	if( IsValidEntity( GetAngelShield( iPlayer, 1 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 1 ) );
	}

	SetEntProp( iPlayer, Prop_Data, "m_takedamage", 2 );

	g_iAngelShields[iPlayer][0] = -1;
	g_iAngelShields[iPlayer][1] = -1;
}

static char szShieldKillParticle[][] = {
	"angel_shieldbreak_red",
	"angel_shieldbreak_blue",
	"angel_shieldbreak_green",
	"angel_shieldbreak_yellow"
};

Action RemoveAngelShield2( Handle hTimer, int iPlayer ) {
	EmitSoundToAll( "weapons/teleporter_explode.wav", iPlayer );
	ClientCommand( iPlayer, "r_screenoverlay 0"); 

	int iTeam = GetEntProp( iPlayer, Prop_Send, "m_iTeamNum" ) - 2;
	int iEmitter = CreateEntityByName( "info_particle_system" );
	DispatchKeyValue( iEmitter, "effect_name", szShieldKillParticle[iTeam] );

	float vecPos[3]; GetClientAbsOrigin( iPlayer, vecPos );
	TeleportEntity( iEmitter, vecPos );

	ParentModel( iEmitter, iPlayer );

	DispatchSpawn( iEmitter );
	ActivateEntity( iEmitter );

	AcceptEntityInput( iEmitter, "Start" );

	CreateTimer( 1.0, RemoveEmitter, EntIndexToEntRef( iEmitter ), TIMER_FLAG_NO_MAPCHANGE );

	if( IsValidEntity( GetAngelShield( iPlayer, 0 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 0 ) );
	}
	if( IsValidEntity( GetAngelShield( iPlayer, 1 ) ) ) {
		RemoveEntity( GetAngelShield( iPlayer, 1 ) );
	}

	g_iAngelShields[iPlayer][0] = -1;
	g_iAngelShields[iPlayer][1] = -1;

	return Plugin_Continue;
}
Action RemoveEmitter( Handle hTimer, int iEmitter ) {
	iEmitter = EntRefToEntIndex( iEmitter );
	if( iEmitter != -1 )
		RemoveEntity( iEmitter );

	return Plugin_Continue;
}

void AngelShieldTakeDamage( int iTarget, TFDamageInfo tfInfo ) {
	ePlayerConds[iTarget][TFCC_ANGELSHIELD].iLevel -= RoundToFloor( tfInfo.flDamage );

	float vecTarget[3];
	GetEntPropVector( iTarget, Prop_Send, "m_vecOrigin", vecTarget );

	TF2_AddCondition( iTarget, TFCond_UberchargedOnTakeDamage, 0.1 );

	Event eFakeDamage = CreateEvent( "player_hurt", true );
	eFakeDamage.SetInt( "userid", GetClientUserId( iTarget ) );
	eFakeDamage.SetInt( "health", 300 );
	eFakeDamage.SetInt( "attacker", GetClientUserId( tfInfo.iAttacker ) );
	eFakeDamage.SetInt( "damageamount", RoundToFloor( tfInfo.flDamage ) );
	eFakeDamage.SetInt( "bonuseffect", 2 );

	eFakeDamage.Fire();

	EmitGameSoundToAll( "Player.ResistanceHeavy", iTarget );

	if( ePlayerConds[iTarget][TFCC_ANGELSHIELD].iLevel <= 0 ) {
		RemoveCond( iTarget, TFCC_ANGELSHIELD );
		g_flLastDamagedShield[ iTarget ] = GetGameTime() + 100;
	}
	else
		g_flLastDamagedShield[ iTarget ] = GetGameTime();

	return;
}
void AngelShieldTakeDamagePost( int iTarget ) {
	TF2_RemoveCondition( iTarget, TFCond_UberchargedOnTakeDamage );
}

void ManageAngelShields() {
	for( int i = 1; i <= MaxClients; i++ ) {
		int iAngelShield = GetAngelShield( i, 0 );
		if( !IsClientInGame( i ) || iAngelShield == -1 )
			continue;

		float flVecPos[3];
		GetEntPropVector( i, Prop_Send, "m_vecOrigin", flVecPos );
		TeleportEntity( GetAngelShield( i, 0 ), flVecPos );

		int iAngelManager = GetAngelShield( i, 1 );
		if( iAngelManager == -1 )
			continue;

		float flLastDamaged = GetGameTime() - g_flLastDamagedShield[ i ];

		float flShieldFalloff = RemapValClamped( flLastDamaged, 0.0, 0.5, 5.0, -5.0 );

		static char szFalloff[8];
		FloatToString(flShieldFalloff, szFalloff, 8);

		SetVariantString( szFalloff );
		AcceptEntityInput( iAngelManager, "SetMaterialVar" );
	}
}

Action Hook_NewShield( int iEntity, int iClient ) {
	if( GetEntPropEnt( iEntity, Prop_Send, "m_hOwnerEntity") == iClient ) {
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

/*
	ANGEL SHIELD INVULN
*/

const float ANGINVULN_DURATION = 0.5;

bool AddAngelInvuln( int iPlayer ) {
	ePlayerConds[iPlayer][TFCC_ANGELINVULN].hTick = CreateTimer( ANGINVULN_DURATION, ExpireAngelInvuln, iPlayer, TIMER_FLAG_NO_MAPCHANGE );
	return true;
}
Action ExpireAngelInvuln( Handle hTimer, int iPlayer ) {
	RemoveCond( iPlayer, TFCC_ANGELINVULN );

	return Plugin_Stop;
}
/*void RemoveAngelInvuln( int iPlayer ) {

}*/

void AngelInvulnTakeDamage( int iTarget ) {
	TF2_AddCondition( iTarget, TFCond_UberchargedOnTakeDamage, 0.1 );
}
void AngelInvulnTakeDamagePost( int iTarget ) {
	TF2_RemoveCondition( iTarget, TFCond_UberchargedOnTakeDamage );
}

public void OnTakeDamageTF( int iTarget, Address aTakeDamageInfo ) {
	TFDamageInfo tfInfo = TFDamageInfo( aTakeDamageInfo );

	if( HasCond( iTarget, TFCC_TOXIN ) )
		ToxinTakeDamage( tfInfo );

	if( HasCond( iTarget, TFCC_ANGELSHIELD ) )
		AngelShieldTakeDamage( iTarget, tfInfo );
	if( HasCond( iTarget, TFCC_ANGELINVULN ) )
		AngelInvulnTakeDamage( iTarget );
}
public void OnTakeDamageAlivePostTF( int iTarget, Address aTakeDamageInfo ) {
	if( HasCond( iTarget, TFCC_ANGELSHIELD ) )
		AngelShieldTakeDamagePost( iTarget );
	if( HasCond( iTarget, TFCC_ANGELINVULN ) )
		AngelInvulnTakeDamagePost( iTarget );
}
public void OnTakeDamagePostTF( int iTarget, Address aTakeDamageInfo ) {
	TFDamageInfo tfInfo = TFDamageInfo( aTakeDamageInfo );
	CheckApplyToxin( iTarget, tfInfo );
}

/*
	QUICK FIX UBER
*/

int g_iQuickFixEmitters[MAXPLAYERS+1] = { -1, ... };
void RemoveQuickFixEmitter( int iPlayer ) {
	int iEmitter = EntRefToEntIndex( g_iQuickFixEmitters[iPlayer] );
	if( iEmitter != -1 ) {
		RemoveEntity( iEmitter );
	}
	g_iQuickFixEmitters[iPlayer] = -1;
}

static char g_szQFixParticle[][] = {
	"quickfix_pulse_red",
	"quickfix_pulse_blue",
	"quickfix_pulse_green",
	"quickfix_pulse_yellow"
};

#define QUICKUBER_SELFHEAL_INTERVAL 0.1

bool AddQuickUber( int iPlayer ) {
	ePlayerConds[iPlayer][TFCC_QUICKUBER].hTick = CreateTimer( QUICKUBER_SELFHEAL_INTERVAL, TickQuickUber, iPlayer, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT );
	RemoveQuickFixEmitter( iPlayer );

	int iTeam = GetEntProp( iPlayer, Prop_Send, "m_iTeamNum" ) - 2;
	int iEmitter = CreateEntityByName( "info_particle_system" );
	DispatchKeyValue( iEmitter, "effect_name", g_szQFixParticle[ iTeam ] );

	float vecPos[3]; GetClientAbsOrigin( iPlayer, vecPos );
	TeleportEntity( iEmitter, vecPos );

	ParentModel( iEmitter, iPlayer );

	DispatchSpawn( iEmitter );
	ActivateEntity( iEmitter );
	AcceptEntityInput( iEmitter, "Start" );

	g_iQuickFixEmitters[iPlayer] = EntIndexToEntRef( iEmitter );

	TF2_AddCondition( iPlayer, TFCond_MegaHeal );
	static char szCommand[64];
	Format( szCommand, sizeof(szCommand), "r_screenoverlay %s", szShieldOverlays[iTeam] );

	ClientCommand( iPlayer, szCommand ); 

	return true;
}

Action TickQuickUber( Handle hTimer, int iPlayer ) {
	if( GetCondLevel( iPlayer, TFCC_QUICKUBER ) != 1 )
		return Plugin_Continue;

	//todo: unhardcode this
	float flRate = 108.0 * QUICKUBER_SELFHEAL_INTERVAL;

	Address aShared = GetSharedFromPlayer( iPlayer );

	int iMaxHealth = SDKCall( hGetBuffedMaxHealth, aShared );
	int iHealth = GetClientHealth( iPlayer );

	int iDiff = iMaxHealth - iHealth;
	float flGive = MinFloat( float( iDiff ), flRate );

	SDKCall( hCallTakeHealth, iPlayer, flGive, 1 << 1 );

	return Plugin_Continue;
}

void RemoveQuickUber( int iPlayer ) {
	RemoveQuickFixEmitter( iPlayer );
	TF2_RemoveCondition( iPlayer, TFCond_MegaHeal );
	ClientCommand( iPlayer, "r_screenoverlay 0");
}

/*
	RADIAL HEAL
*/