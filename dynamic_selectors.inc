#if defined _dynamic_selectors_included
#endinput
#endif
#define _dynamic_selectors_included

typeset DtsTargetFilter {
	/**
	 * This function will filter whether the client can be added to the target list.
	 * If you're encoutnering a format/input error and you want to blame the user,
	 * use STD_SetFilterError(fmt,...) and return any value.
	 *
	 * @param sender - the client currently issuing this filtering (@s / @me)
	 * @param client - the client that's currently filtered
	 * @param argument - an argument name you registered
	 * @param value - the value that was specified for this argument
	 *        consider ! as negation prefix, or DTS_XInRange for range syntax.
	 *        note that DTS_XInRange already allows !range for negation.
	 * @return true if this client passed the filter
	 */
	function bool (int sender, int client, const char[] argument, const char[] value);
}

/**
 * Use this inside DtsTargetFilter if you want to blame the sender for messing up
 * the input format for your values.
 * Has no effect outside DtsTargetFilter.
 */
native void DTS_SetFilterError(const char[] format, any...);

/**
 * Use this to register an argument to be handled by your plugin.
 *
 * @param argument - the argument name you want to listen to
 * @param filter - your filter function that applies to the argument
 * @return false if the filter was already registered
 */
native bool DTS_RegisterTargetFilter(const char[] argument, DtsTargetFilter filter);

/**
 * Release your argument callback. This should probably be called in OnPluginEnd
 * to support late-loading
 * 
 * @param argument name - the name of the argument OR NULL_STRING to drop all callbacks
 * @return true on success
 */
native bool DTS_DropTargetFilter(const char[] argument=NULL_STRING);

//===== These stocks are included to maybe make range parsing somewhat consistent =====//
//     If you do not feel like using them, don't; they won't bloat your smx either

/**
 * @param value - value to check
 * @param rangeSyntax - value OR min.. OR min..max OR ..max (! prefix for negation)
 * @return 1 if in range (start and end inclusive), 0 if out of range, -1 if parse error
 */
stock int DTS_IntInRange(int value, const char[] rangeSyntax) {
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
stock int DTS_FloatInRange(float value, const char[] rangeSyntax) {
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


public SharedPlugin __pl_DynamicTargetSelectors = {
	name = "DynamicTargetSelectors",
	file = "dynamic_selectors.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_DynamicTargetSelectors_SetNTVOptional() {
	MarkNativeAsOptional("DTS_SetFilterError");
	MarkNativeAsOptional("DTS_RegisterTargetFilter");
	MarkNativeAsOptional("DTS_DropTargetFilter");
}
#endif
