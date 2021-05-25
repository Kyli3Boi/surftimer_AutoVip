#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <autoexecconfig>
#pragma newdecls required
#pragma semicolon 1

#define MAXPLAYERSALLOWED 20

public Plugin myinfo =
{
	name = "SurfTimer_AutoVip",
	author = "Kyli3_Boi",
	description = "Automatically manage VIP for highest ranked players. For use on a surf server running SurfTimer",
	version = "2.0",
	url = "https://github.com/Kyli3Boi"
};

////////////////////////////////////////////////////////////////////////////////////////////////////////

// ConVars //
ConVar g_hAutoVipEnabled = null;					// Enable/Disable
ConVar g_hAutoVipNumber = null; 					// Number of top players to give VIP
ConVar g_hAutoVipLevel = null; 						// The level of VIP to give top players 1|2|3
ConVar g_hAutoVipTitleLevel1 = null;				// Title to give VIPs for VIP level 1
ConVar g_hAutoVipTitleLevel2 = null;				// Title to give VIPs for VIP level 2
ConVar g_hAutoVipTitleLevel3 = null;				// Title to give VIPs for VIP level 3
ConVar g_hAutoVipRemoveType = null;					// On VIP removal do you want to just disable player or delete player
ConVar g_hAutoVipEnableDebug = null;				// Enable/Disable debug messages
ConVar g_hAutoVipAdminFlag = null;					// Flag to give temp admins

// Array Handles // 
Handle g_szSteamID = null;
Handle g_szName = null; 
Handle g_szCurrentVipList = null;
Handle g_szAutoVipList = null;

// Bool
bool g_bAutoVipDebug = false;						// Bool for debug messages

// Int
int g_iAdminFlag;

// SQL //
Handle g_hDb = null;								// Database Handle

// Prepared SQL Statements //
char sql_CheckPlayerRank[] = "SELECT steamid FROM ck_playerrank LIMIT 1";
char sql_CheckVipAdmins[] = "SELECT steamid FROM ck_vipadmins LIMIT 1";
char sql_CheckAutoVip[] = "SELECT steamid FROM autovip LIMIT 1";
char sql_GetTopPlayers[] = "SELECT steamid, name FROM ck_playerrank where style = 0 ORDER BY points DESC LIMIT %i";
char sql_GetCurrentVipList[] = "SELECT steamid, inuse, vip, active FROM ck_vipadmins";
char sql_InsertVip[] = "INSERT INTO ck_vipadmins (steamid, title, namecolour, textcolour, inuse, vip, admin, zoner) VALUES ('%s', '%s', 0, 0, 1 , %i, 0, 0)";
char sql_UpdateVip[] = "UPDATE ck_vipadmins SET inuse = 1, vip = %i, active = 1 WHERE steamid = '%s'";
char sql_DisableVip[] = "UPDATE ck_vipadmins SET inuse = 0, vip = 0, active = 0 WHERE steamid = '%s'";
char sql_DeleteVip[] = "DELETE FROM ck_vipadmins where steam id = '%s'";
char sql_CreateAutoVipTable[] = "CREATE TABLE IF NOT EXISTS `autovip` (`steamid` varchar(32) NOT NULL DEFAULT '', PRIMARY KEY (`steamid`)) DEFAULT CHARSET=utf8mb4;";
char sql_TruncateAutoVip[] = "TRUNCATE TABLE autovip";
char sql_SaveTopPlayer[] = "INSERT INTO autovip (steamid) VALUES ('%s')";
char sql_GetAutoVipList[] = "SELECT steamid FROM autovip";

////////////////////////////////////////////////////////////////////////////////////////////////////////

public void OnPluginStart()
{
	//Create ConVars
	AutoExecConfig_SetCreateDirectory(true);
	AutoExecConfig_SetCreateFile(true);
	AutoExecConfig_SetFile("surftimer_AutoVip");

	g_hAutoVipEnabled = AutoExecConfig_CreateConVar("sm_autovip_enabled", "1", "Give VIP to top players 0 - Disabled | 1 - Enabled", FCVAR_NOTIFY);
	g_hAutoVipNumber = AutoExecConfig_CreateConVar("sm_autovip_number", "1", "Number of top players that should recieve VIP", FCVAR_NOTIFY, true, 1.0, true, 20.0);
	g_hAutoVipLevel = AutoExecConfig_CreateConVar("sm_autovip_viplevel", "1", "The level of VIP top players should recieve");
	g_hAutoVipTitleLevel1 = AutoExecConfig_CreateConVar("sm_autovip_title1", "[{lime}VIP{default}]", "Title to give when using VIP level 1");
	g_hAutoVipTitleLevel2 = AutoExecConfig_CreateConVar("sm_autovip_title2", "[{pink}Super VIP{default}]", "Title to give when using VIP level 2");
	g_hAutoVipTitleLevel3 = AutoExecConfig_CreateConVar("sm_autovip_title3", "[{darkred}Superior VIP{default}]", "Title to give when using VIP level 3");
	g_hAutoVipRemoveType = AutoExecConfig_CreateConVar("sm_autovip_removetype", "0", "The way in which to remove VIP from a player 0 - Disable player VIP | 1 - Delete player from VIP table in database");
	g_hAutoVipEnableDebug = AutoExecConfig_CreateConVar("sm_autovip_debug", "0", "Print debug messages to server 0 - Disabled | 1 - Enabled");
	g_hAutoVipAdminFlag = AutoExecConfig_CreateConVar("sm_autovip_adminflag", "a", "The admin flag to give to VIPs (surftimer default \"a\")");

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();		
	
	// Connect to DB
	db_Connect();
	
	// Set debug bool
	g_bAutoVipDebug = GetConVarBool(g_hAutoVipEnableDebug);

	// Make sure VIP flag is valid
	char szAdminFlag[24]; 
	AdminFlag bufferAdminFlag;
	bool adminFlagValid;

	GetConVarString(g_hAutoVipAdminFlag, szAdminFlag, sizeof(szAdminFlag));
	adminFlagValid = FindFlagByChar(szAdminFlag[0], bufferAdminFlag);
	if(!adminFlagValid)
	{
		PrintToServer("[surftimer_AutoVip] Invalid sm_autovip_adminflag, setting to default");
		g_iAdminFlag = ADMFLAG_RESERVATION;
	}
	else
	{
		g_iAdminFlag = FlagToBit(bufferAdminFlag);
	}
}

public void OnMapStart()
{
	// Create Arrays
	g_szSteamID = CreateArray(32);
	g_szName = CreateArray(64);
	g_szCurrentVipList = CreateArray(32);
	g_szAutoVipList = CreateArray(32);

	db_GetTopPlayers();
}

public void OnClientPostAdminFilter(int client)
{
	if (!IsFakeClient(client))
	{
		CreateTempVip(client);
	}
}

public void CreateTempVip(int client)
{
	if (g_bAutoVipDebug)
	{
		PrintToServer("[surftimer_AutoVip] Checking if player should be assigned VIP flag");
	}
	
	if (!IsFakeClient(client))
	{
		char szSteamId[32];
		int index;

		GetClientAuthId(client, AuthId_Steam2, szSteamId, sizeof(szSteamId), true);
		
		index = FindStringInArray(g_szSteamID, szSteamId);

		if (index != -1)
		{
			SetUserFlagBits(client, g_iAdminFlag);
		}
	}
}

public void db_Connect()
{
	if (GetConVarInt(g_hAutoVipEnabled) == 1)
	{
		char szError[255];
		g_hDb = SQL_Connect("surftimer", false, szError, 255);

		if (g_hDb == null)
		{
			SetFailState("[surftimer_AutoVip] Unable to connect to database (%s)", szError);
		}
		else
		{
			if (g_bAutoVipDebug)
			{
				PrintToServer("[surftimer_AutoVip] Connection to database successful");
			}

			db_CheckTables();
		}
	}
	else
	{
		SetFailState("[surftimer_AutoVip] is not enabled");
	}
}

public void db_CheckTables()
{
	if (g_bAutoVipDebug)
	{
		PrintToServer("[surftimer_AutoVip] Checking if surftimer tables exist");
	}

	if (!SQL_FastQuery(g_hDb, sql_CheckPlayerRank) || !SQL_FastQuery(g_hDb, sql_CheckVipAdmins))
	{
		SetFailState("[surftimer_AutoVip] Unable to find required surftimer DB tables, please troubleshoot your surftimer installation");
	}
	else
	{
		if (g_bAutoVipDebug)
		{
			PrintToServer("[surftimer_AutoVip] Required surftimer DB tables found");
		}
	}

	if (!SQL_FastQuery(g_hDb, sql_CheckAutoVip))
	{
		SQL_FastQuery(g_hDb, sql_CreateAutoVipTable);
	}
	else
	{
		if (g_bAutoVipDebug)
		{
			PrintToServer("[surftimer_AutoVip] Required autovip DB table found");
		}
	}
}


public void db_GetTopPlayers()
{
	char szQuery[128];
	int number = GetConVarInt(g_hAutoVipNumber);

	Format(szQuery, 128, sql_GetTopPlayers, number);
	SQL_TQuery(g_hDb, db_GetTopPlayersCallback, szQuery, DBPrio_Low);
}

public void db_GetTopPlayersCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_GetTopPlayersCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		char szSteamId[32];
		char szName[64];

		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szSteamId, 32);
			SQL_FetchString(hndl, 1, szName, 64);

			PushArrayString(g_szSteamID, szSteamId);
			PushArrayString(g_szName, szName);
		}

		for (int i = 0; i < GetArraySize(g_szSteamID); i++)
		{
			GetArrayString(g_szSteamID, i, szSteamId, sizeof(szSteamId));
			
			if (g_bAutoVipDebug)
			{
				PrintToServer("SteamID[%i]: %s", i, szSteamId);
			}
		}

		for (int i = 0; i < GetArraySize(g_szName); i++)
		{
			GetArrayString(g_szName, i, szName, sizeof(szName));
			
			if (g_bAutoVipDebug)
			{
				PrintToServer("Name[%i]: %s", i, szName);
			}
		}

		db_GetCurrentAutoVipPlayers();
		db_GetCurrentVipList();
	}
	else
	{
		PrintToServer("[surftimer_AutoVip] No top players found!");
	}
}

public void db_GetCurrentAutoVipPlayers()
{
	SQL_TQuery(g_hDb, db_GetCurrentAutoVipPlayersCallback, sql_GetAutoVipList, DBPrio_Low);
}

public void db_GetCurrentAutoVipPlayersCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_GetCurrentAutoVipPlayersCallback): %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) != GetArraySize(g_szSteamID))
	{
		db_SaveTopPlayers();
	}

	if (SQL_HasResultSet(hndl))
	{
		char szSteamId[32];
		
		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szSteamId, 32);

			PushArrayString(g_szAutoVipList, szSteamId);
		}

		CompareTopPlayers();
	}
}

public void CompareTopPlayers()
{
	bool newTopPlayer;
	char szSteamId[32];
	int index; 

	for (int i = 0; i < GetArraySize(g_szAutoVipList); i++)
	{
		GetArrayString(g_szAutoVipList, i, szSteamId, sizeof(szSteamId));

		index = FindStringInArray(g_szSteamID, szSteamId);

		if (index == -1)
		{
			db_RemoveVip(szSteamId);
			newTopPlayer = true;
		}
	}

	if (newTopPlayer)
	{
		db_SaveTopPlayers();
	}
}

public void db_SaveTopPlayers()
{
	SQL_FastQuery(g_hDb, sql_TruncateAutoVip);

	char szSteamId[32], szQuery[128];

	for (int i = 0; i < GetArraySize(g_szSteamID); i++)
	{
		GetArrayString(g_szSteamID, i, szSteamId, sizeof(szSteamId));
		
		Format(szQuery, 128, sql_SaveTopPlayer, szSteamId);
		SQL_FastQuery(g_hDb, szQuery);
	}
}

public void db_GetCurrentVipList()
{
	SQL_TQuery(g_hDb, db_GetCurrentVipListCallback, sql_GetCurrentVipList, DBPrio_Low);
}

public void db_GetCurrentVipListCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_GetCurrentVipListCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		char szSteamId[32];

		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szSteamId, 32);

			PushArrayString(g_szCurrentVipList, szSteamId);
		}

		for (int i = 0; i < GetArraySize(g_szCurrentVipList); i++)
		{
			GetArrayString(g_szCurrentVipList, i, szSteamId, sizeof(szSteamId));
			if (g_bAutoVipDebug)
			{
				PrintToServer("VipList[%i]: %s", i, szSteamId);
			}
		}

		CheckVipStatus();
	}
	else
	{
		if (g_bAutoVipDebug)
		{
			PrintToServer("[surftimer_AutoVip] No VIPs found!");
		}
	}
}

public void CheckVipStatus()
{
	char szSteamId[32];
	int index;

	for (int i = 0; i < GetArraySize(g_szSteamID); i++)
	{
		GetArrayString(g_szSteamID, i, szSteamId, sizeof(szSteamId));

		index = FindStringInArray(g_szCurrentVipList, szSteamId);

		if (index != -1)
		{
			db_UpdateVip(szSteamId);
		}
		else
		{
			db_InsertVip(szSteamId);
		}
	}
}

public void db_UpdateVip(char[] szSteamId)
{
	char szQuery[256];
	int iVipLevel;

	iVipLevel = GetConVarInt(g_hAutoVipLevel);

	Format(szQuery, 256, sql_UpdateVip, iVipLevel, szSteamId);
	SQL_TQuery(g_hDb, db_UpdateVipCallback, szQuery, DBPrio_Low);
}

public void db_UpdateVipCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_UpdateVipCallback): %s", error);
		return;
	}
}

public void db_InsertVip(char[] szSteamId)
{
	char szQuery[256], szTitle[128];
	int iVipLevel;

	iVipLevel = GetConVarInt(g_hAutoVipLevel);

	switch (iVipLevel)
	{
		case 1: 
		{
			GetConVarString(g_hAutoVipTitleLevel1, szTitle, sizeof(szTitle));
		}
		case 2: 
		{
			GetConVarString(g_hAutoVipTitleLevel2, szTitle, sizeof(szTitle));
		}
		case 3: 
		{
			GetConVarString(g_hAutoVipTitleLevel3, szTitle, sizeof(szTitle));
		}
	}

	Format(szQuery, 256, sql_InsertVip, szSteamId, szTitle, iVipLevel);
	SQL_TQuery(g_hDb, db_InsertVipCallback, szQuery, DBPrio_Low);
}

public void db_InsertVipCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_InsertVipCallback): %s", error);
		return;
	}
}

public void db_RemoveVip(char[] szSteamId)
{
	char szQuery[256];
	
	if (GetConVarInt(g_hAutoVipRemoveType) == 0)
	{
		Format(szQuery, 256, sql_DisableVip, szSteamId);
	}
	else
	{
		Format(szQuery, 256, sql_DeleteVip, szSteamId);
	}
	
	SQL_TQuery(g_hDb, db_InsertVipCallback, szQuery, DBPrio_Low);
}

public void db_RemoveVipCallback(Handle owner, Handle hndl, const char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[surftimer_AutoVip] SQL Error (db_RemoveVipCallback): %s", error);
		return;
	}
}

public void OnMapEnd()
{
	CloseHandle(g_szSteamID);
	CloseHandle(g_szName);
	CloseHandle(g_szCurrentVipList);
	CloneHandle(g_szAutoVipList);
}