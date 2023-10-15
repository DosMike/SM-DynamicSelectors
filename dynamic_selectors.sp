#include <sourcemod>
#include <regex>
#include <admin>

#pragma semicolon 1
#pragma newdecls required

// I don't know why there's no defines for that in SM, but for ranges with float
// these are extremely usefull, ans SourceMod does understand them
// IEEE754 BitPattern for +Inf
#define FLOAT_PINFINITY view_as<float>(0x7F800000)
// IEEE754 BitPattern for -Inf
#define FLOAT_NINFINITY view_as<float>(0xFF800000)

#define PLUGIN_VERSION "23w41a"

// uncomment to allow server console to use dynamic selectors.
// note: this method is ugly and requires a reload if plugins change!
//#define ALT_HOOK_METHOD

public Plugin myinfo = {
	name = "Dynamic Target Selectors",
	author = "reBane",
	description = "Use Target Selectors like Minecraft has them",
	version = PLUGIN_VERSION,
	url = "http://forums.alliedmods.net"
};

Regex g_selectorPattern;
char g_targetFilterError[256];
bool g_bTargetFilterError;
void SetFilterError(const char[] format, any...) {
	VFormat(g_targetFilterError, sizeof(g_targetFilterError), format, 2);
	g_bTargetFilterError = true;
}

enum struct DynamicSelector {
	int sender;
	char pattern[128];
	int myTick; //stick around a bit until we might be called
	int targets[MAXPLAYERS];
	int targetCount;
	bool filled;
	void From(int client, const char[] buffer) {
		this.sender = client ? GetClientUserId(client) : 0;
		strcopy(this.pattern, sizeof(DynamicSelector::pattern), buffer);
		this.myTick = GetGameTickCount();
		this.filled = false;
	}
}
typeset DtsTargetFilter {
	function bool (int sender, int client, const char[] key, const char[] value);
}
enum struct DtsTargetForward {
	Handle plugin;
	Function fun; //type: DtsTargetFilter
	
	/** check g_bTargetFilterError after call! */
	bool Test(int sender, int client, const char[] key, const char[] value) {
		g_bTargetFilterError = false;
		Call_StartFunction(this.plugin, this.fun);
		Call_PushCell(sender);
		Call_PushCell(client);
		Call_PushString(key);
		Call_PushString(value);
		bool result;
		int error = Call_Finish(result);
		if (error != SP_ERROR_NONE) {
			char name[64];
			GetPluginInfo(this.plugin, PlInfo_Name, name, sizeof(name));
			//Might even want to SetFailState, the api consumer should really handle these!
			ThrowError("Error processing selector argument (%s=%s) on client %i in plugin '%s'", key, value, client, name);
		}
		return result;
	}
}

StringMap g_targetFilters;
ArrayList g_activeSelectors;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	CreateNative("DTS_SetFilterError", Native_SetFilterError);
	CreateNative("DTS_RegisterTargetFilter", Native_RegisterFilter);
	CreateNative("DTS_DropTargetFilter", Native_DropFilter);
	RegPluginLibrary("DynamicTargetSelectors");
	
	g_activeSelectors = new ArrayList(sizeof(DynamicSelector));
	g_targetFilters = new StringMap();
	RegisterDefaultFilters();
	
	return APLRes_Success;
}

public void ConVarLocked(ConVar convar, const char[] oldValue, const char[] newValue) {
	char buf[64];
	convar.GetString(buf, sizeof(buf));
	if (!StrEqual(buf, PLUGIN_VERSION)) convar.SetString(PLUGIN_VERSION);
}


public void OnPluginStart() {
	g_selectorPattern = new Regex("(?<=^| )@[!]?[praes](?:\\[" //sm negation, plain pattern
		..."(?:[^\\s=,\\\"\\'\\[\\]]+=[^\\s=,\\\"\\'\\[\\]]+" //key = value
		..."(?:,[^\\s=,\\\"\\'\\[\\]]+=[^\\s=,\\\"\\'\\[\\]]+)*)?" //repeat
		..."\\])?(?= |$)", PCRE_UTF8); // value in [] is optional as well as [] itself
	
	ConVar version = CreateConVar("dynamic_selectors_version", PLUGIN_VERSION, "Plugin version for Dynamic Selectors", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	version.AddChangeHook(ConVarLocked);
	ConVarLocked(version,"","");
	delete version;
	
#if defined ALT_HOOK_METHOD
	char namebuf[128];
	Handle cmdit = GetCommandIterator();
	while (ReadCommandIterator(cmdit, namebuf, sizeof(namebuf))) {
		AddCommandListener(OnSourcemodCommand, namebuf);
	}
	delete cmdit;
#endif
}

public void OnPluginEnd() {
	for (int i; i<g_activeSelectors.Length; i+=1) {
		DynamicSelector selector;
		g_activeSelectors.GetArray(i, selector);
		RemoveMultiTargetFilter(selector.pattern, DynamicFilterProcessor);
	}
}


int FindActiveSelector(const char[] pattern, int client=0, DynamicSelector selector={}) {
	int user = client ? GetClientUserId(client) : 0;
	for (int at; at < g_activeSelectors.Length; at += 1) {
		g_activeSelectors.GetArray(at, selector);
		if( StrEqual(selector.pattern, pattern) &&
			(user == 0 || user == selector.sender) &&
			selector.myTick == GetGameTickCount() ) return at;
	}
	return -1;
}

public void OnGameFrame() {
	int tick = GetGameTickCount();
	for (int at=g_activeSelectors.Length-1; at>=0; at-=1) {
		if (g_activeSelectors.Get(at, DynamicSelector::myTick) != tick)
			g_activeSelectors.Erase(at);
	}
}

#if defined ALT_HOOK_METHOD
Action OnSourcemodCommand(int client, const char[] name, int argc) {
#else
public Action OnClientCommand(int client, int argc) {
#endif
	char args[256];
	char buffer[128];
	PrintToServer("Requester: %N", client);
	
	GetCmdArgString(args, sizeof(args));
	
	int matches = g_selectorPattern.MatchAll(args);
	if (matches <= 0) return Plugin_Continue; //no selectors for us
	
	char rebuild[256];
	
	strcopy(rebuild, sizeof(rebuild), args);
	for (int match; match < matches; match += 1) {
		g_selectorPattern.GetSubString(0, buffer, sizeof(buffer), match);
		//PrintToServer("Match %i: %s", match+1, buffer);
		DynamicSelector selector;
		if (FindActiveSelector(buffer, client, selector)<0) {
			selector.From(client, buffer);
			g_activeSelectors.PushArray(selector);
			AddMultiTargetFilter(buffer, DynamicFilterProcessor, "<Dynamic Selection>", false);
		}
	}
	
	return Plugin_Continue;
}

public bool DynamicFilterProcessor(const char[] pattern, ArrayList clients) {
	DynamicSelector selector;
	int selectorIndex = FindActiveSelector(pattern, _, selector);
	if (selectorIndex < 0) return false;
	
	//we already processed this
	if (selector.filled) {
		for (int i=0; i<selector.targetCount; i+=1) clients.Push(selector.targets[i]);
		return true;
	}
	
	// prepare data
	int sender = GetClientOfUserId(selector.sender);
	
	bool passFilter = pattern[1]!='!';
	char type = pattern[passFilter?1:2];
	
	//store client on cell 2 so we can sort by arbitrary 1st cell
	ArrayList base = new ArrayList(2);
	StringMap data = new StringMap();
	char key[64], value[64];
	
	//parse "variable", so type and collect base clients list
	int limit=0;
	switch (type) {
		case 'p': {
			int pushable[2];
			for (int client=1;client<=MaxClients;client++) {
				if (!IsClientConnected(client)) continue;
				pushable[1]=client;
				base.PushArray(pushable);
			}
			data.SetString("sort", "nearest");
			limit = 1;
		}
		case 'r': {
			int pushable[2];
			for (int client=1;client<=MaxClients;client++) {
				if (!IsClientConnected(client)) continue;
				pushable[1]=client;
				base.PushArray(pushable);
			}
			data.SetString("sort", "random");
			limit = 1;
		}
		case 's': {
			int pushable[2];
			if (passFilter) { //self
				pushable[1]=sender;
				base.PushArray(pushable);
			} else { //not self
				for (int client=1;client<=MaxClients;client++) {
					if (client == sender || !IsClientConnected(client)) continue;
					pushable[1]=client;
					base.PushArray(pushable);
				}
			}
		}
		case 'a','e': {
			int pushable[2];
			for (int client=1;client<=MaxClients;client++) {
				if (!IsClientConnected(client)) continue;
				pushable[1]=client;
				base.PushArray(pushable);
			}
		}
		//if this matches, i effed up somewhere
		default: ThrowError("Unknown dynamic patten variable '%c'", type);
	}
	
	//parse keyvalues
	int paramStart = passFilter?2:3;
	int paramEnd = strlen(pattern)-1;
	if (pattern[paramStart] == '[' && pattern[paramEnd] == ']') {
		paramStart+=1; //skip [
		// *paramEnd-=1;* threat ] like 0, so dont subtract for buffer len
		int start=paramStart;
		bool ab;
		for (int pos=paramStart; pos<=paramEnd; pos+=1) {
			if (!ab && pattern[pos]=='=') {
				int sz=pos-start+1;
				if (sz>sizeof(key)) sz=sizeof(key);
				strcopy(key, sz, pattern[start]);
				start = pos+1;
				ab = true;
			} else if (ab && (pattern[pos]==','||pos==paramEnd)) {
				int sz=pos-start+1;
				if (sz>sizeof(value)) sz=sizeof(value);
				strcopy(value, sz, pattern[start]);
				start = pos+1;
				ab = false;
				
				//found another key
				PrintToServer("Pushing '%s'='%s'", key, value);
				data.SetString(key, value);
			}
		}
	}
	
	//pre-process keyvalues
	if (data.GetString("c", value, sizeof(value))) {
		int num;
		if (StringToIntEx(value, num)!=strlen(value)) {
			ReplyToCommand(sender, "[DynSel] Argument 'c' requires integer value");
			selector.filled=true;
			g_activeSelectors.SetArray(selectorIndex, selector);
			delete base;
			delete data;
			return true; //return no hits for this
		}
		if (num==0) {
			selector.filled=true;
			g_activeSelectors.SetArray(selectorIndex, selector);
			delete base;
			delete data;
			return true;
		}
		else if (num>0) {
			data.SetString("sort", "nearest");
			limit = num;
		} else {
			data.SetString("sort", "furthest");
			limit = -num;
		}
		data.Remove("limit");
		data.Remove("c");
	}
	if (data.GetString("sort", value, sizeof(value))) {
		//set sort cell 0 base on client in cell 1
		if (StrEqual(value, "nearest")||StrEqual(value, "near")) {
			//sort by distance positive
			for (int i;i<base.Length;i++)
				base.Set(i, clientDist(sender, base.Get(i, 1)), 0);
			base.Sort(Sort_Ascending, Sort_Float);
		} else if (StrEqual(value, "furthest")||StrEqual(value, "far")) {
			for (int i;i<base.Length;i++)
				base.Set(i, clientDist(sender, base.Get(i, 1)), 0);
			base.Sort(Sort_Descending, Sort_Float);
		} else if (StrEqual(value, "random")||StrEqual(value, "rng")) {
			for (int i;i<base.Length;i++)
				base.Set(i, GetRandomInt(0,100), 0);
			base.Sort(Sort_Ascending, Sort_Integer);
		} else if (StrEqual(value, "arbitrary")||StrEqual(value, "any")||StrEqual(value, "")) {
			//it is what it is
		} else {
			ReplyToCommand(sender, "[DynSel] Unknown value for argument 'sorting': %s", value);
			selector.filled=true;
			g_activeSelectors.SetArray(selectorIndex, selector);
			delete base;
			delete data;
			return true; //return no hits for this
		}
		data.Remove("sort");
	}
	if (data.GetString("limit", value, sizeof(value))) {
		int num;
		if (StringToIntEx(value, num)!=strlen(value) || num < 0) {
			ReplyToCommand(sender, "[DynSel] Argument 'limit' requires positive integer value");
			selector.filled=true;
			g_activeSelectors.SetArray(selectorIndex, selector);
			delete base;
			delete data;
			return true; //return no hits for this
		}
		if (num==0) {
			selector.filled=true;
			g_activeSelectors.SetArray(selectorIndex, selector);
			delete base;
			delete data;
			return true;
		} //you want 0? you get 0
		data.Remove("limit");
	}
	
	//process target filters
	StringMapSnapshot snap = data.Snapshot();
	for (int i; i<snap.Length; i++) {
		// for ([key,value] in data) {...
		snap.GetKey(i, key, sizeof(key));
		data.GetString(key, value, sizeof(value));
		// base.filter(client->g_targetFilters(sender,client,key,value))
		DtsTargetForward filter;
		if (!g_targetFilters.GetArray(key, filter, sizeof(DtsTargetForward))) {
			ReplyToCommand(sender, "[DynSel] Unknown argument type: '%s'", key);
			base.Clear();
			break;
		} else {
			for (int j=base.Length-1; j>=0; j-=1) {
				bool keep = filter.Test(sender, base.Get(j, 1), key, value);
				if (g_bTargetFilterError) {
					ReplyToCommand(sender, "[DynSel] Error: %s", g_targetFilterError);
					base.Clear();
					break;
				}
				if ( !keep ) base.Erase(j);
			}
			if (base.Length==0) break; //oopsie, no more targets... ignore other filters
		}
	}
	delete snap;
	delete data;
	//copy back filtered clients
	if (limit<=0) limit = MAXPLAYERS; //no limit == all results
	for (int at; at<base.Length && limit; at += 1, limit -= 1) {
		clients.Push(selector.targets[selector.targetCount] = base.Get(at, 1));
		selector.targetCount+=1;
	}
	selector.filled=true;
	g_activeSelectors.SetArray(selectorIndex, selector);
	delete base;
	return true;
}

/** for sorting purpose */
float clientDist(int clientA, int clientB, bool square=true) {
	float vecA[3], vecB[3];
	if (!IsClientInGame(clientA) || !IsClientInGame(clientB)) return FLOAT_PINFINITY;
	GetClientAbsOrigin(clientA, vecA);
	GetClientAbsOrigin(clientB, vecB);
	return GetVectorDistance(vecA, vecB, square);
}

/**
 * @param value - value to check
 * @param rangeSyntax - value OR min.. OR min..max OR ..max (! prefix for negation)
 * @return 1 if in range (start and end inclusive), 0 if out of range, -1 if parse error
 */
stock int IntInRange(int value, const char[] rangeSyntax) {
	int low=0x80000000, high=0x80000001, read;
	bool positive = rangeSyntax[0]!='!';
	int parseFrom = positive?0:1;
	int paramLen = strlen(rangeSyntax);
	//parse first number
	int parsed = StringToIntEx(rangeSyntax[parseFrom], read);
	if (parsed == paramLen) return (value == read) == positive;
	else if (parsed) { low = read; parseFrom += parsed; }
	//now require ..high
	if (rangeSyntax[parseFrom] != '.' || rangeSyntax[parseFrom+1] != '.') return -1;
	parseFrom+=2;
	//check and parse rest is optional number
	if (rangeSyntax[parseFrom] && (parsed = StringToIntEx(rangeSyntax[parseFrom], high))+parseFrom < paramLen) return -1;
	return (low <= value <= high) == positive;
}
/**
 * This will still parse the bounds as int because separator .. and suffix . get confusing
 * @param value - value to check
 * @param rangeSyntax - value OR min.. OR min..max OR ..max (! prefix for negation)
 * @return 1 if in range (start and end inclusive), 0 if out of range, -1 if parse error
 */
stock int FloatInRange(float value, const char[] rangeSyntax) {
	float low=FLOAT_NINFINITY, high=FLOAT_PINFINITY, fread; int read;
	bool positive = rangeSyntax[0]!='!';
	int parseFrom = positive?0:1;
	int paramLen = strlen(rangeSyntax);
	//parse first number
	int parsed = StringToIntEx(rangeSyntax[parseFrom], read); fread=float(read);
	if (parsed == paramLen) return ((FloatAbs(value-fread)<0.0001) == positive) ? 1 : 0; //comparing floats is iffy, idealy we'd use abs(a-b)<=max(eps(a),eps(b))
	else if (parsed) { low = fread; parseFrom += parsed; }
	//now require ..high
	if (rangeSyntax[parseFrom] != '.' || rangeSyntax[parseFrom+1] != '.') return -1;
	parseFrom+=2;
	//check and parse rest is optional number
	if (rangeSyntax[parseFrom]) {
		if ((parsed = StringToIntEx(rangeSyntax[parseFrom], read))+parseFrom != paramLen) return -1;
		else high = float(read);
	}
	return ((low <= value <= high) == positive) ? 1 : 0;
}
static void RegisterDefaultFilters() {
	DtsTargetForward data;
	data.plugin = GetMyHandle();
	
	data.fun = DTF_minDist;
	g_targetFilters.SetArray("rm",data,sizeof(data));
	data.fun = DTF_maxDist;
	g_targetFilters.SetArray("r",data,sizeof(data));
	data.fun = DTF_distance;
	g_targetFilters.SetArray("distance",data,sizeof(data));
	data.fun = DTF_posX;
	g_targetFilters.SetArray("x",data,sizeof(data));
	data.fun = DTF_posY;
	g_targetFilters.SetArray("y",data,sizeof(data));
	data.fun = DTF_posZ;
	g_targetFilters.SetArray("z",data,sizeof(data));
	data.fun = DTF_deltaX;
	g_targetFilters.SetArray("dx",data,sizeof(data));
	data.fun = DTF_deltaY;
	g_targetFilters.SetArray("dy",data,sizeof(data));
	data.fun = DTF_deltaZ;
	g_targetFilters.SetArray("dz",data,sizeof(data));
	data.fun = DTF_team;
	g_targetFilters.SetArray("team",data,sizeof(data));
	data.fun = DTF_flag;
	g_targetFilters.SetArray("flag",data,sizeof(data));
	data.fun = DTF_health;
	g_targetFilters.SetArray("hp",data,sizeof(data));
}
public bool DTF_minDist(int sender, int client, const char[] key, const char[] value) {
	float dist;
	return StringToFloatEx(value,dist) == strlen(value) && clientDist(sender,client,false) > dist;
}
public bool DTF_maxDist(int sender, int client, const char[] key, const char[] value) {
	float dist;
	return StringToFloatEx(value,dist) == strlen(value) && clientDist(sender,client,false) <= dist;
}
public bool DTF_distance(int sender, int client, const char[] key, const char[] value) {
	float dist = clientDist(sender,client,false);
	int result = FloatInRange(dist, value);
	if (result == -1) SetFilterError("Invalid value for argument 'distance', value or range expected");
	return result==1;
}
public bool DTF_posX(int sender, int client, const char[] key, const char[] value) {
	float vec[3];
	if (!IsClientInGame(client)) return false;
	GetClientAbsOrigin(client, vec);
	int result = FloatInRange(vec[0], value);
	if (result == -1) SetFilterError("Invalid value for argument 'x', value or range expected");
	return result==1;
}
public bool DTF_posY(int sender, int client, const char[] key, const char[] value) {
	float vec[3];
	if (!IsClientInGame(client)) return false;
	GetClientAbsOrigin(client, vec);
	int result = FloatInRange(vec[1], value);
	if (result == -1) SetFilterError("Invalid value for argument 'y', value or range expected");
	return result==1;
}
public bool DTF_posZ(int sender, int client, const char[] key, const char[] value) {
	float vec[3];
	if (!IsClientInGame(client)) return false;
	GetClientAbsOrigin(client, vec);
	int result = FloatInRange(vec[2], value);
	if (result == -1) SetFilterError("Invalid value for argument 'z', value or range expected");
	return result==1;
}
public bool DTF_deltaX(int sender, int client, const char[] key, const char[] value) {
	if (!IsClientInGame(sender) || !IsClientInGame(client)) return false;
	float vecA[3], vecB[3];
	GetClientAbsOrigin(sender, vecA);
	GetClientAbsOrigin(client, vecB);
	SubtractVectors(vecB,vecA,vecA);
	int result = FloatInRange(FloatAbs(vecA[0]), value);
	if (result == -1) SetFilterError("Invalid value for argument 'dx', value or range expected");
	return result==1;
}
public bool DTF_deltaY(int sender, int client, const char[] key, const char[] value) {
	if (!IsClientInGame(sender) || !IsClientInGame(client)) return false;
	float vecA[3], vecB[3];
	GetClientAbsOrigin(sender, vecA);
	GetClientAbsOrigin(client, vecB);
	SubtractVectors(vecB,vecA,vecA);
	int result = FloatInRange(FloatAbs(vecA[1]), value);
	if (result == -1) SetFilterError("Invalid value for argument 'dy', value or range expected");
	return result==1;
}
public bool DTF_deltaZ(int sender, int client, const char[] key, const char[] value) {
	if (!IsClientInGame(sender) || !IsClientInGame(client)) return false;
	float vecA[3], vecB[3];
	GetClientAbsOrigin(sender, vecA);
	GetClientAbsOrigin(client, vecB);
	SubtractVectors(vecB,vecA,vecA);
	int result = FloatInRange(FloatAbs(vecA[2]), value);
	if (result == -1) SetFilterError("Invalid value for argument 'dz', value or range expected");
	return result==1;
}
public bool DTF_team(int sender, int client, const char[] key, const char[] value) {
	if (!IsClientInGame(client)) return false;
	int team;
	bool positive = value[0]!='!';
	int readFrom = positive?0:1;
	if (StringToIntEx(value[readFrom],team) == strlen(value)) return (GetClientTeam(client)==team)==positive;
	if (StrEqual(value[readFrom], "none")) return (GetClientTeam(client)==0)==positive;
	if (StrEqual(value[readFrom], "spec")) return (GetClientTeam(client)==1)==positive;
	if (StrEqual(value[readFrom], "T") || 
		StrEqual(value[readFrom],"RED") || 
		StrEqual(value[readFrom],"survivor",false) || 
		StrEqual(value[readFrom],"combine",false)) return (GetClientTeam(client)==2)==positive;
	if (StrEqual(value[readFrom], "CT") || 
		StrEqual(value[readFrom],"BLU") || 
		StrEqual(value[readFrom],"infected",false) || 
		StrEqual(value[readFrom],"rebel",false)) return (GetClientTeam(client)==3)==positive;
	SetFilterError("Unknown team identifier");
	return false;
}
public bool DTF_flag(int sender, int client, const char[] key, const char[] value) {
	bool positive = value[0]!='!';
	int readFrom = positive?0:1;
	if (!IsClientConnected(client)) return false;
	AdminId admin=GetUserAdmin(client);
	return ( GetAdminFlags(admin, Access_Effective) == ReadFlagString(value[readFrom]) )==positive;
}
public bool DTF_health(int sender, int client, const char[] key, const char[] value) {
	if (!IsClientInGame(client)) return false;
	int result = IntInRange(GetClientHealth(client), value);
	if (result == -1) SetFilterError("Invalid value for argument 'hp', value or range expected");
	return result==1;
}

public any Native_SetFilterError(Handle plugin, int numParams) {
	FormatNativeString(0, 1, 2, sizeof(g_targetFilterError), _, g_targetFilterError);
	g_bTargetFilterError = true;
	return 0;
}
public any Native_RegisterFilter(Handle plugin, int numParams) {
	char argument[64];
	GetNativeString(1, argument, sizeof(argument));
	
	DtsTargetForward fwd;
	fwd.plugin = plugin;
	fwd.fun = GetNativeFunction(2);
	
	DtsTargetForward tmp;
	tmp.plugin = INVALID_HANDLE;
	return (!g_targetFilters.GetArray(argument, tmp, sizeof(DtsTargetForward)) || tmp.plugin==INVALID_HANDLE) &&
		g_targetFilters.SetArray(argument, fwd, sizeof(DtsTargetForward));
}
public any Native_DropFilter(Handle plugin, int numParams) {
	DtsTargetForward fwd;
	char argument[64];
	if (IsNativeParamNullString(1)) {
		int amount;
		StringMapSnapshot snap = g_targetFilters.Snapshot();
		for (int j=0;j<snap.Length;j+=1) {
			snap.GetKey(j, argument, sizeof(argument));
			g_targetFilters.GetArray(argument, fwd, sizeof(fwd));
			if (fwd.plugin == plugin) {
				g_targetFilters.Remove(argument);
				amount+=1;
			}
		}
		delete snap;
		return amount>0;
	} else {
		fwd.plugin = INVALID_HANDLE;
		GetNativeString(1, argument, sizeof(argument));
		g_targetFilters.GetArray(argument, fwd, sizeof(DtsTargetForward));
		return (fwd.plugin == plugin) && g_targetFilters.Remove(argument);
	}
}
