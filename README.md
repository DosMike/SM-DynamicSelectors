# Dynamic Selectors

So I was bored this weekend and implemented dynamic target selectors, like Mincraft has them for SourceMod.
This means there are now 4 new target selectors you can filter.

* `@p` Nearest player (sort=nearest,limit=1)
* `@r` Random player (sort=random,limit=1)
* `@s` Self (equal to @me, but filterable)
* `@!s` Everyone but Self (equal to @!me, but filterable)
* `@a` Everyone (no sorting or limit; equal to @all, but filterable)

These will populate the base list of targets that can then be filtered.

Filters are specified in square brackes and can not contains spaces, more square brackets, quotes, or argument/value separators.
Specify As many or little as you want, duplicate argument will use the last value.

Arguments available by default:

* `sort=Sorting` Sorting being one of:
  * `nearest`, `near` Nearest players first
  * `furthest`, `far` Furthest players first
  * `random`, `rng` Random target sorting
  * `arbitrary`, `any` Undefined order
* `limit=Number` Number of targets to return (positive integer)
* `c=Number` combination of `sort` and `limit`
  * positive is nearest N players
  * positive is furthest -N players
* `r=Number` Maximum distance to caller in HU
* `rm=Number` Minimum distance to caller in HU
* `distance=Range` Distance range to caller in HU
* `x=Range` The targets x coordinate has to be within the range
* `y=Range` The targets y coordinate has to be within the range
* `z=Range` The targets z coordinate has to be within the range
* `dx=Range` Distance between targets x and callers x has to be within range
* `dy=Range` Distance between targets y and callers y has to be within range
* `dz=Range` Distance between targets z and callers z has to be within range
* `team=Team` Team specifyer (can be negated with ! prefix)
  * `0`, `none` Unassigned
  * `1`, `spec` Spectators
  * `2`, `T`, `RED`, `survivor`, `combine` for Team 2
  * `3`, `CT`, `BLU`, `infected`, `rebel` for Team 3
* `flag=Flags` Check for all admin flags (can be negted with ! prefix)
* `hp=Range` Target health has to be within range

Range values are formatted according to this list and can be negated using a ! prefix:

* A literal value: attrib=100
* An upper bound: attrib=..100
* A lower bound: attrib=100..
* Both bounds: attribg=-100..100

### Store selection

If a plugin appears to be broken when using a dynamic selector, or if you dont want to re-type
the selector every time you run a batch of commands, you can use `/select` and `@selected`.

As you might guess, `/select` stores any arbitrary argument as target parameter, later accessible
as `@selected`. `/select` by default is accessible to everyone. For example:
`sm_select @r[flag=!z]; sm_slay @selected`

This still uses target selectors, so you can't just make commands magically longer!

### Plugin Devs

Plugins can also register additional argument parsers with these natives:
```php
OnPluginStart() {
	DTS_RegisterTargetFilter("hp", dts_healthFilter);
}
OnPluginEnd() {
	DTS_DropTargetFilter();
}

bool dts_healthFilter(int caller, int target, const char[] key, const char[] value) {
	if (!IsClientInGame(target)) return false;
	int result = DTS_IntInRange(GetClientHealth(target), value);
	if (result == -1) {
		SetFilterError("Invalid value for argument 'hp', value or range expected!");
	return result == 1;
}
```

Full command example: `sm_slay @a[rm=100,team=BLU]`