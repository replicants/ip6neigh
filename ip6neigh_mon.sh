#!/bin/sh

##################################################################################
#
#  Copyright (C) 2016 André Lange
#
#  See the file "LICENSE" for information on usage and redistribution
#  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#  Distributed under GPLv2 License
#
##################################################################################


#	Script to automatically generate and update a hosts file giving local DNS
#	names to IPv6 addresses that IPv6 enabled devices took via SLAAC mechanism.
#
#	by André Lange		Dec 2016

#Dependencies
. /lib/functions.sh
. /lib/functions/network.sh

#Loads UCI configuration file
reset_cb
config_load ip6neigh
config_get LAN_IFACE config interface lan
config_get LL_LABEL config ll_label LL
config_get ULA_label config ula_label
config_get gua_label config gua_label
config_get TMP_LABEL config tmp_label TMP
config_get PROBE_EUI64 config probe_eui64 1
config_get_bool PROBE_IID config probe_iid 1
config_get UNKNOWN config unknown "Unknown"
config_get_bool LOAD_STATIC config load_static 1
config_get LOG config log 0

#Gets the physical device
network_get_physdev LAN_DEV "$LAN_IFACE"

#DNS suffix to append
DOMAIN=$(uci get dhcp.@dnsmasq[0].domain)
if [ -z "$DOMAIN" ]; then DOMAIN="lan"; fi

#Adds entry to hosts file
add() {
	local name="$1"
	local addr="$2"
	echo "$addr $name" >> /tmp/hosts/ip6neigh
	killall -1 dnsmasq

	logmsg "Added: $name $addr"
	
	return 0
}

#Removes entry from hosts file
remove() {
	local addr="$1"
	grep -q "^$addr " /tmp/hosts/ip6neigh || return 0
	#Must save changes to another temp file and then move it over the main file.
	grep -v "^$addr " /tmp/hosts/ip6neigh > /tmp/ip6neigh
	mv /tmp/ip6neigh /tmp/hosts/ip6neigh

	logmsg "Removed: $addr"
	return 0
}

#Renames a previously added entry
rename() {
	local oldname="$1"
	local newname="$2"

	#Must save changes to another temp file and then move it over the main file.
	sed "s/ ${oldname}/ ${newname}/g" /tmp/hosts/ip6neigh > /tmp/ip6neigh
	mv /tmp/ip6neigh /tmp/hosts/ip6neigh

	logmsg "Replaced names: $oldname to $newname"
	return 0
}

#Writes message to log
logmsg() {
	#Check if logging is disabled
	[ "$LOG" = "0" ] && return 0
	
	if [ "$LOG" = "1" ]; then
		#Log to syslog
		logger -t ip6neigh "$1"
	else
		#Log to file
		echo "$(date) $1" >> "$LOG"
	fi
	return 0
}

#Returns 0 if the supplied IPv6 address has an EUI-64 interface identifier.
is_eui64() {
	echo "$1" | grep -q -E ':[^:]{0,2}ff:fe[^:]{2}:[^:]{1,4}$'
	return "$?"	
}

#Returns 0 if the supplied non-LL IPv6 address has the same IID as the LL address for that same host.
is_other_static() {
	local addr="$1"
	
	#Gets the interface identifier from the address
	iid=$(echo "$addr" | grep -o -m 1 -E "[^:]{1,4}:[^:]{1,4}:[^:]{1,4}:[^:]{1,4}$")
	
	#Aborts with false if could not get IID
	[ -n "$iid" ] || return 1
	
	#Builds match string
	local match
	if [ -n "$LL_LABEL" ]; then
		match="^fe80::${iid} [^ ]*${LL_LABEL}.${DOMAIN}$"
	else
		match="^fe80::${iid} [^ ]*$"
	fi

	#Looks for match and returns true if it finds one.
	grep -q "$match" /tmp/hosts/ip6neigh
	return "$?"	
}

#Generates EUI-64 interface identifier based on MAC address
gen_eui64() {
	local mac=$(echo "$2" | tr -d ':')
	local iid1="${mac:0:4}"
	local iid2="${mac:4:2}ff:fe${mac:6:2}:${mac:8:4}"

	#Flip U/L bit
	iid1=$(printf %x $((0x${iid1} ^ 0x0200)))
		
	eval "$1=${iid1}:${iid2}"
	return 0
}

#Adds an address to the probe list
add_probe() {
	local addr="$1"
	
	#Do not add if the address already exist in some hosts file.
	grep -q "^$addr " /tmp/hosts/* && return 0
	
	#Adds to the list
	probe_list="${probe_list}${addr} "
	
	return 0
}

#Probe addresses related to the supplied base address and MAC.
probe_addresses() {
	local name="$1"
	local baseaddr="$2"
	local mac="$3"
	local scope="$4"

	#Initializes probe list
	probe_list=""

	#Check if is configured for probing addresses with the same IID
	local base_iid=""
	if [ "$PROBE_IID" -gt 0 ]; then
		#Gets the interface identifier from the base address
		base_iid=$(echo "$baseaddr" | grep -o -m 1 -E "[^:]{1,4}:[^:]{1,4}:[^:]{1,4}:[^:]{1,4}$")
		
		#Proceed if successful in getting the IID from the address
		if [ -n "$base_iid" ]; then
			#Probe same IID for different scopes than this one.
			if [ "$scope" != 0 ]; then add_probe "fe80::${base_iid}"; fi
			if [ "$scope" != 1 ] && [ -n "$ula_prefix" ]; then add_probe "${ula_prefix}:${base_iid}"; fi
			if [ "$scope" != 2 ] && [ -n "$gua_prefix" ]; then add_probe "${gua_prefix}:${base_iid}"; fi
		fi
	fi

	#Check if is configured for probing MAC-based addresses
	if [ "$PROBE_EUI64" -gt 0 ]; then
		#Generates EUI-64 interface identifier
		local eui64_iid
		gen_eui64 eui64_iid "$mac"

		#Only add to list if EUI-64 IID is different from the one that has been just added.
		if [ "$eui64_iid" != "$base_iid" ]; then
			if [ "$PROBE_EUI64" = "1" ] && [ "$scope" != 0 ]; then add_probe "fe80::${eui64_iid}"; fi
			if [ "$PROBE_EUI64" = "1" ] || [ "$scope" = 1 ]; then
				if [ -n "$ula_prefix" ]; then add_probe "${ula_prefix}:${eui64_iid}"; fi
			fi
			if [ "$PROBE_EUI64" = "1" ] || [ "$scope" = 2 ]; then
				if [ -n "$gua_prefix" ]; then add_probe "${gua_prefix}:${eui64_iid}"; fi
			fi
		fi
	fi
	
	#Exit if there is nothing to probe.
	[ -n "$probe_list" ] || return 0
	
	logmsg "Probing other possible addresses for ${name}: ${probe_list}"
	
	#Ping each address once.
	local addr
	IFS=' '
	for addr in $probe_list; do
		if [ -n "$addr" ]; then
		 	ping6 -q -W 1 -c 1 -s 0 -I "$LAN_DEV" "$addr" >/dev/null 2>/dev/null
		fi
	done
	
	#Clears the probe list.
	probe_list=""

	return 0
}

#Try to get a name from DHCPv6/v4 leases based on MAC.
dhcp_name() {
	local mac="$2"
	local match
	local dname

	#Look for a DHCPv6 lease with DUID-LL or DUID-LLT matching the neighbor's MAC address.
	match=$(echo "$mac" | tr -d ':')
	dname=$(grep -m 1 -E "^# ${LAN_DEV} (00010001.{8}|00030001)${match} [^ ]* [^-]" /tmp/hosts/odhcpd | cut -d ' ' -f5)

	#If couldn't find a match in DHCPv6 leases then look into the DHCPv4 leases file.
	if [ -z "$dname" ]; then
		dname=$(grep -m 1 -E " $mac [^ ]{7,15} ([^*])" /tmp/dhcp.leases | cut -d ' ' -f4)
	fi
	
	#If succeded, returns the name and success.
	if [ -n "$dname" ]; then
		eval "$1='$dname'"
		return 0
	fi
	
	#Failed. Return error.
	return 1
}

#Searches for the OUI of the MAC in a manufacturer list.
oui_name() {
	local mac="$2"
	local oui="${mac:0:6}"
	
	#Fails if OUI file does not exist.
	[ -f "/root/oui.gz" ] || return 1
	
	#Check if the MAC is locally administered.
	if [ "$((0x${oui:0:2} & 0x02))" != 0 ]; then
		#Returns this name and success.
		eval "$1='LocAdmin'"
		return 0
	fi

	#Searches for the OUI in the database.
	local reg=$(gunzip -c /root/oui.gz | grep -m 1 "^$oui")
	local oname="${reg:6}"
	
	#Check if found.
	if [ -n "$oname" ]; then
		#Returns the manufacturer name and success code.
		eval "$1='$oname'"
		return 0
	fi

	#Manufacturer not found. Returns fail code.
	return 2
}

#Creates a name for the host.
create_name() {
	local mac="$2"
	local generate="$3"
	local cname
	
	#Try to get a name from DHCPv6/v4 leases. If it fails, decide what to do based on type.
	if ! dhcp_name cname "$mac"; then
		#Create a name based on MAC address if allowed to do so.
		if [ "$generate" -gt 0 ] && [ "${UNKNOWN}" != 0 ]; then
			local upmac=$(echo "$mac" | tr -d ':' | awk '{print toupper($0)}')
			local nic="${upmac:6}"
			local manuf
			
			#Tries to get a name based on the OUI part of the MAC.
			if oui_name manuf "$upmac"; then
				cname="_${manuf}-${nic}"
			else
				#If it fails, use the specified unknown string.
				cname="_${UNKNOWN}-${nic}"
			fi
		else
			#No source for name. Returns error.
			return 1
		fi
	fi
	
	#Success
	eval "$1='$cname'"
	return 0
}

#Gets the current name for an IPv6 address from the hosts file
get_name() {
	local addr="$2"
	local matched
	
	#Check if the address already exists
	matched=$(grep "^$addr " /tmp/hosts/*)
	
	#Address is new? (not found)
	[ "$?" != 0 ] && return 3
	
	#Check what kind of name it has
	local gname=$(echo "$matched" | cut -d ' ' -f2)
	local fname=$(echo "$gname" | cut -d '.' -f1)
	eval "$1='$fname'"
	
	#Unknown name?
	if [ "$UNKNOWN" != "0" ]; then
		echo "$gname" | grep -q -E "^_[0-9,a-z,A-Z]+-[0-9,A-F]{6}(\.|$)"
		[ "$?" = 0 ] && return 2
	fi
	
	#Temporary name?
	echo "$gname" | grep -q "^[^\.]*${TMP_LABEL}\."
	[ "$?" = 0 ] && return 1
	
	#Existent non-temporary name
	return 0
}

#Main routine: Process the changes in reachability status.
process() {
	local addr="$1"
	local mac="$3"
	local status

	#Ignore STALE events
	for status; do true; done
	[ "$status" != "STALE" ] || return 0

	case "$status" in
		#Neighbor is unreachable. Remove it from hosts file.
		"FAILED") remove "$addr";;

		#Neighbor is reachable. Must be processed.
		"REACHABLE")
			#Check current name and decide what to do based on its type.
			local name
			local currname
			local type
			get_name currname "$addr"
			type="$?"
			
			case "$type" in
				#Address already has a stable name. Nothing to be done.
				0) return 0;;
				
				#Address named as temporary. Check if it is possible to classify it as non-temporary now.
				1)
					if is_other_static "$addr"; then
						#Removes the temporary address entry to be re-added as non-temp.
						logmsg "Address $addr was believed to be temporary but a LL address with same IID is now found. Replacing entry."
						remove "$addr"
						
						#Create name for address, allowing to generate unknown.
						if ! create_name name "$mac" 1; then
							#Nothing to be done if could not get a name.
							return 0
						fi
					else
						#Still temporary. Nothing to be done.
						return 0
					fi
				;;
				
				#Address was already named as unknown.
				2)
					#Create name for address, not allowing to generate unknown.
					if create_name name "$mac" 0; then
						#Success creating name. Replaces the unknown name.
						logmsg "Unknown host $currname now has got a proper name. Replacing all entries."
						rename "$currname" "$name"
					fi

					return 0
				;;
				
				#Address is new.
				3)
					#Create name for address, allowing to generate unknown.
					if ! create_name name "$mac" 1; then
						#Nothing to be done if could not get a name.
						return 0
					fi
				;;
			esac

			#Check address scope and assign proper labels.
			local suffix=""
			local scope
			if [ "${addr:0:4}" = "fe80" ]; then
				#Is link-local. Append corresponding label.
				suffix="${LL_LABEL}"
				
				#Sets scope ID to LL
				scope=0
			elif [ "${addr:0:2}" = "fd" ]; then
				#Is ULA. Append corresponding label.
				suffix="${ULA_LABEL}"
				
				#Check if interface identifier is static
				if ! is_eui64 "$addr" && ! is_other_static "$addr"; then
					#Interface identifier does not appear to be static. Adds temporary address label.
					suffix="${TMP_LABEL}${suffix}"
				fi

				#Sets scope ID to ULA
				scope=1
			else
				#The address is globally unique. Append corresponding label.
				suffix="${GUA_LABEL}"

				#Check if interface identifier is static
				if ! is_eui64 "$addr" && ! is_other_static "$addr"; then
					#Interface identifier does not appear to be static. Adds temporary address label.
					suffix="${TMP_LABEL}${suffix}"					
				fi 

				#Sets scope ID to GUA
				scope=2
			fi

			#Cat strings to generate output name
			local hostsname
			if [ -n "$suffix" ]; then
				#Names with labels get FQDN
				hostsname="${name}${suffix}.${DOMAIN}"
			else
				#Names without labels 
				hostsname="${name}"
			fi
			
			#Adds entry to hosts file
			add "$hostsname" "$addr"
			
			#Probe other addresses related to this one
			probe_addresses "$name" "$addr" "$mac" "$scope"
		;;
	esac
	return 0
}

#Process entry in /etc/config/dhcp
config_host() {
	local name
	local mac
	local slaac

	config_get name "$1" name
	config_get mac "$1" mac
	config_get slaac "$1" slaac "0"

	#Ignore entry if required options are absent or disabled.
	if [ -z "$name" ] || [ -z "$slaac" ] || [ "$slaac" = "0" ]; then
		return 0
	fi

	#slaac option is enabled. Check if it contains a custom IID.
	local iid=""
	if [ "$slaac" != "1" ]; then
		#Use custom IID
		iid=$(echo "$slaac" | awk '{print tolower($0)}')
	elif [ -n "$mac" ]; then
		#Generates EUI-64 interface identifier based on MAC
		mac=$(echo "$mac" | awk '{print tolower($0)}')
		gen_eui64 iid "$mac"
	fi

	#Load custom interface identifiers for each scope of address.
	#Uses EUI-64 when not specified.
	local ll_iid
	local ula_iid
	local gua_iid
	config_get ll_iid "$1" ll_iid "$iid"
	config_get ula_iid "$1" ula_iid "$iid"
	config_get gua_iid "$1" gua_iid "$iid"
	
	logmsg "Generating predefined SLAAC addresses for $name"

	#Creates hosts file entries with link-local, ULA and GUA prefixes with corresponding IIDs.
	local suffix
	suffix=""
	if [ -n "$ll_iid" ] && [ "$ll_iid" != "0" ]; then
		if [ -n "${LL_LABEL}" ]; then suffix="${LL_LABEL}.${DOMAIN}"; fi
		echo "fe80::${ll_iid} ${name}${suffix}" >> /tmp/hosts/ip6neigh
	fi
	
	suffix=""
	if [ -n "$ula_prefix" ] && [ -n "$ula_iid" ] && [ "$ula_iid" != "0" ]; then
		if [ -n "${ULA_LABEL}" ]; then suffix="${ULA_LABEL}.${DOMAIN}"; fi
		echo "${ula_prefix}:${ula_iid} ${name}${suffix}" >> /tmp/hosts/ip6neigh
	fi
	
	suffix=""
	if [ -n "$gua_prefix" ] && [ -n "$gua_iid" ] && [ "$gua_iid" != "0" ]; then
		if [ -n "${GUA_LABEL}" ]; then suffix="${GUA_LABEL}.${DOMAIN}"; fi
		echo "${gua_prefix}:${gua_iid} ${name}${suffix}" >> /tmp/hosts/ip6neigh
	fi
}

#Clears the log file if one is set
if [ "$LOG" != "0" ] && [ "$LOG" != "1" ]; then
	> "$LOG"
fi

#Startup message
logmsg "Starting ip6neigh script for physdev $LAN_DEV with domain $DOMAIN"

#Finds ULA and global addresses on LAN interface.
ula_cidr=$(ip -6 addr show "$LAN_DEV" scope global 2>/dev/null | grep "inet6 fd" | grep -m 1 -v "dynamic" | awk '{print $2}')
gua_cidr=$(ip -6 addr show "$LAN_DEV" scope global dynamic 2>/dev/null | grep -m 1 -E "inet6 ([^fd])" | awk '{print $2}')
ula_address=$(echo "$ula_cidr" | cut -d "/" -f1)
gua_address=$(echo "$gua_cidr" | cut -d "/" -f1)
ula_prefix=$(echo "$ula_address" | cut -d ":" -f1-4)
gua_prefix=$(echo "$gua_address" | cut -d ":" -f1-4)

#Decides if the GUAs should get a label based in config file and the presence of ULAs
if [ -n "$gua_label" ]; then
	#Use label specified in config file.
	GUA_LABEL="$gua_label"
	logmsg "Using custom label for GUAs: ${GUA_LABEL}"
else
	#No label has been specified for GUAs. Check if the network setup has ULAs.
	if [ -n "$ula_prefix" ]; then
		#Yes. Use default label for GUAs.
		GUA_LABEL="PUB"
		logmsg "Network has ULA prefix ${ula_prefix}::/64. Using default label for GUAs: ${GUA_LABEL}"
	else
		#No ULAs. So do not use label for GUAs.
		GUA_LABEL=""
		logmsg "Network does not have ULA prefix. Clearing label for GUAs."
	fi
fi

#Adds a dot before each label
if [ -n "$LL_LABEL" ]; then LL_LABEL=".${LL_LABEL}" ; fi
if [ -n "$ULA_LABEL" ]; then ULA_LABEL=".${ULA_LABEL}" ; fi
if [ -n "$GUA_LABEL" ]; then GUA_LABEL=".${GUA_LABEL}" ; fi
if [ -n "$TMP_LABEL" ]; then TMP_LABEL=".${TMP_LABEL}" ; fi

#Clears the output file
> /tmp/hosts/ip6neigh

#Process /etc/config/dhcp an look for hosts with 'slaac' options set
if [ "$LOAD_STATIC" -gt 0 ]; then
	echo "#Predefined SLAAC addresses" >> /tmp/hosts/ip6neigh
	config_load dhcp
	config_foreach config_host host
	echo -e >> /tmp/hosts/ip6neigh
fi
	
echo "#Discovered IPv6 neighbors" >> /tmp/hosts/ip6neigh

#Send signal to dnsmasq to reload hosts files.
killall -1 dnsmasq

#Flushes the neighbors cache and pings "all nodes" multicast address with various source addresses to speedup discovery.
ip -6 neigh flush dev "$LAN_DEV"

ping6 -q -W 1 -c 3 -s 0 -I "$LAN_DEV" ff02::1 >/dev/null 2>/dev/null
[ -n "$ula_address" ] && ping6 -q -W 1 -c 3 -s 0 -I "$ula_address" ff02::1 >/dev/null 2>/dev/null
[ -n "$gua_address" ] && ping6 -q -W 1 -c 3 -s 0 -I "$gua_address" ff02::1 >/dev/null 2>/dev/null

#Infinite loop. Keeps monitoring changes in IPv6 neighbor's reachability status and call process() routine.
ip -6 monitor neigh dev "$LAN_DEV" |
	while IFS= read -r line
	do
		process $line
	done

