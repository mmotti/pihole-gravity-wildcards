#!/usr/bin/env bash

# Variables
db_gravity='/etc/pihole/gravity.db'
file_gravity='/etc/pihole/gravity.list'
file_whitelist='/etc/pihole/whitelist.txt'
file_setupVars='/etc/pihole/setupVars.conf'
file_ftl='/etc/pihole/pihole-FTL.conf'
file_output='/etc/dnsmasq.d/mmotti_generated_wildcards.conf'
limit_subdomains=20

# Determine whether we are using Pi-hole DB
if [[ -s "${db_gravity}" ]]; then
	echo '[i] Pi-hole DB detected'
	usingDB=true
fi

# Functions
function fetchResults() {

	local table="${1}" queryStr

	# Select domains from gravity view
	queryStr="Select domain FROM vw_${table}"

	# Execute SQL query
	sqlite3 ${db_gravity} "${queryStr}" 2>&1

	# Check exit status
	status="$?"
	[[ "${status}" -ne 0 ]]  && { (>&2 echo '[i] An error occured whilst fetching results'); return 1; }

	return
}

function determineBlockingMode {

	# Set local variables
	local IPv6_enabled IPv4_enabled blockingMode

	# Check for IPv6 Address
	IPv6_enabled=$(grep -F 'IPV6_ADDRESS=' "${file_setupVars}" | cut -d'=' -f2 | cut -d'/' -f1)
	# Check for IPv4 Address
	IPv4_enabled=$(grep -F 'IPV4_ADDRESS=' "${file_setupVars}" |cut -d'=' -f2 | cut -d'/' -f1)
	# Check for blocking mode
	blockingMode=$(grep -F 'BLOCKINGMODE=' "${file_ftl}" | cut -d'=' -f2)

	# Switch statement for blocking mode
	# Note: There doesn't seem to be a way to force DNSMASQ to return NODATA at this time.
	case "${blockingMode}" in

		NULL)
			blockingMode='#'
		;;

		NXDOMAIN)
			blockingMode=''
		;;

		IP-NODATA-AAAA)
			blockingMode=$IPv4_enabled
		;;

		IP)
			blockingMode=$IPv4_enabled
			[[ -n "${IPv6_enabled}" ]] && blockingMode+=" ${IPv6_enabled}"
		;;

		*)
			blockingMode='#'
		;;

	esac

	echo "${blockingMode}"

	return
}

function generateDNSMASQ () {

	local domains="${1}" blockingMode="${2}"

	# Conditional exit if no blocking mode is specified
	[[ -z "${domains}" ]] || [[ -z "${blockingMode}" ]] && { (>&2 echo '[i] Error: generateDNSMASQ did not receieve all of the required information'); return 1; }

	# Construct output
	awk -v mode="${blockingMode}" 'BEGIN{n=split(mode, modearr, " ")}n>0{for(m in modearr)print "address=/"$0"/"modearr[m]; next} {print "address=/"$0"/"}' <(echo "${domains}")

	return
}

function convertToFMatchPatterns() {
	# Conditional exit
	[[ -z "${1}" ]] && { (>&2 echo '[i] Failed to supply string for conversion'); return 1; }
	# Convert exact domains (pattern source) - something.com -> ^something.com$
	match_exact=$(sed 's/^/\^/;s/$/\$/' <<< "${1}")
	# Convert wildcard domains (pattern source) - something.com - .something.com$
	match_wildcard=$(sed 's/^/\./;s/$/\$/' <<< "${1}")
	# Output combined match patterns
	printf '%s\n' "${match_exact}" "${match_wildcard}"

	return 0
}

function convertToFMatchTarget() {
	# Conditional exit
	[[ -z "${1}" ]] && { (>&2 echo '[i] Failed to supply string for conversion'); return 1; }
	# Convert target - something.com -> ^something.com$
	sed 's/^/\^/;s/$/\$/' <<< "${1}"

	return 0
}

function removeWildcardConflicts() {
	# Conditional exit if the required arguments aren't available
	[[ -z "${1}" ]] && { (>&2 echo '[i] Failed to supply match pattern string'); return 1; }
	[[ -z "${2}" ]] && { (>&2 echo '[i] Failed to supply match target string'); return 1; }
	# Gather F match strings for LTR match
	ltr_match_patterns=$(convertToFMatchPatterns "${1}")
	ltr_match_target=$(convertToFMatchTarget "${2}")
	# Invert LTR match
	ltr_result=$(grep -vFf <(echo "${ltr_match_patterns}") <<< "${ltr_match_target}" | sed 's/[\^$]//g')
	# Conditional exit if no domains remain after match inversion
	[[ -z "${ltr_result}" ]] && return 0
	# Gather F match strings for RTL match
	rtl_match_patterns=$(convertToFMatchPatterns "${ltr_result}")
	rtl_match_target=$(convertToFMatchTarget "${1}")
	# Find conflicting wildcards
	rtl_conflicts=$(grep -Ff <(echo "${rtl_match_patterns}") <<< "${rtl_match_target}" | sed 's/[\^$]//g')
	# Identify source of match conflicts and remove
	[[ -n "${rtl_conflicts}" ]] && awk 'NR==FNR{Domains[$0];next}$0 in Domains{badDoms[$0]}{for(d in Domains)if(index($0, d".")==1)badDoms[d]}END{for(d in Domains)if(!(d in badDoms))print d}' <(rev <<< "${ltr_result}") <(rev <<< "${rtl_conflicts}") | rev | sort || echo "${ltr_result}"

	return 0
}

# Start by updating gravity
echo '[i] Updating gravity'
pihole -g > /dev/null

# Fetch gravity domains
if [[ "${usingDB}" == true ]]; then
	echo '[i] Fetching domains from gravity table'
	# Read from DB
	str_gravity=$(fetchResults "gravity")
	# Conditional exit if empty
	[[ -z "${str_gravity}" ]] && { echo '[i] No domains were returned from the DB query'; exit 1; }
	# Create temp file
	tmp_gravity=$(mktemp --suffix='.gravity')
	# Output domains to temp file
	echo "${str_gravity}" > "${tmp_gravity}"
else
	echo '[i] Fetching domains from gravity.list'
	[[ ! -s "${file_gravity}" ]] && { echo '[i] No domains were found in gravity.list'; exit 1; }
	# Create temp file
	tmp_gravity=$(mktemp --suffix='.gravity')
	# Copy gravity.list to temp file
	cp "${file_gravity}" "${tmp_gravity}"
fi

# Find domains with more than x subdomains
echo "[i] Identifying domains with >= ${limit_subdomains} subdomains"
domains=$(awk -v limit="${limit_subdomains}" -F'.' 'BEGIN{i=0}index($0,prev FS)!=1{if(i>=limit){print prev;}prev=$0;i=0;next}{++i}' <(rev "${tmp_gravity}" | sort) | rev | sort)
[[ -z "${domains}" ]] && { echo "No domains were found to have >= ${limit_subdomains} subdomains"; exit 0; }
echo "[i] $(wc -l <<< ${domains}) domains found"

# Make sure we aren't wildcarding any domains that will interfere with the whitelist
if [[ "${usingDB}" == true ]]; then
	echo '[i] Fetching domains from whitelist table'
	# Read from DB
	str_whitelist=$(fetchResults "whitelist")
else
	echo '[i] Fetching domains from whitelist.txt'
	# Read from whitelist.txt
	str_whitelist=$(cat "${file_whitelist}")
fi

# If there are whitelisted domains
# Remove any conflicts with the whitelist
if [[ -n "${str_whitelist}" ]]; then
	echo '[i] Checking for whitelist conflicts'
	domains=$(removeWildcardConflicts "${str_whitelist}" "${domains}")
	echo "[i] $(wc -l <<< ${domains}) domains remain after conflict resolution"
else
	echo '[i] No whitelisted domains detected'
fi

# Determine blocking mode
echo '[i] Determining blocking mode'
blockingMode=$(determineBlockingMode)
[[ -z "${blockingMode}" ]] && { echo "Error: Blocking mode was not returned"; exit 1; }

# Output domains
echo "[i] Outputting domains to: ${file_output}"
generateDNSMASQ "${domains}" "${blockingMode}" | sudo tee "${file_output}" > /dev/null

# Restart Pi=hole service
echo '[i] Restarting Pi-hole service'
sudo service pihole-FTL restart

# Remove temp file
rm -f "${tmp_gravity}"