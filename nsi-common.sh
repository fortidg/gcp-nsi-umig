#!/bin/bash

# Shared helpers for setup-nsi.sh and cleanup-nsi.sh. Sourced, not executed.
#
# Both scripts must derive the exact same association names from
# CONSUMER_NETWORKS, or cleanup cannot find what setup created. Keeping that
# logic here, in one place, is what guarantees they agree.

# Parse CONSUMER_NETWORKS into the CONSUMER_NETWORK_LIST array.
#
# CONSUMER_NETWORKS is a comma- and/or space-separated list of VPC network names
# in PROJECT_ID, e.g. "prod-vpc,staging-vpc". Duplicates are dropped. Returns 1 if
# any entry is not a valid GCE network name.
parse_consumer_networks() {
    CONSUMER_NETWORK_LIST=()
    local net existing seen invalid=0

    for net in ${CONSUMER_NETWORKS//,/ }; do
        if ! [[ "$net" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
            print_error "Invalid network name in CONSUMER_NETWORKS: '$net'"
            print_error "Use bare VPC names in project $PROJECT_ID (lowercase letters, digits, hyphens)."
            invalid=1
            continue
        fi

        seen=0
        for existing in "${CONSUMER_NETWORK_LIST[@]}"; do
            [ "$existing" = "$net" ] && seen=1 && break
        done
        [ "$seen" -eq 0 ] && CONSUMER_NETWORK_LIST+=("$net")
    done

    return "$invalid"
}

# Deterministic association name for a consumer network: "<prefix>-<network>".
#
# GCE resource names are capped at 63 characters. Long network names are
# truncated and suffixed with a hash of the full name, so two long networks that
# share a prefix still get distinct association names.
# Usage: consumer_assoc_name <prefix> <network>
consumer_assoc_name() {
    local prefix="$1" net="$2"
    local name="${prefix}-${net}"

    if [ ${#name} -gt 63 ]; then
        local hash keep
        # cksum is POSIX, so this hashes identically on macOS and Linux.
        hash=$(printf '%s' "$net" | cksum | awk '{printf "%08x", $1}')
        keep=$((63 - ${#prefix} - 1 - 1 - ${#hash}))
        name="${prefix}-${net:0:$keep}-${hash}"
    fi

    echo "$name"
}

# Name prefixes for consumer-network associations. Distinct from the fixed web
# VPC association names, so the two can never collide.
CONSUMER_EPG_ASSOC_PREFIX="newfgt-nsi-epga"
CONSUMER_POLICY_ASSOC_PREFIX="newfgt-nsi-fpa"

# Print "<association name> <network>" for every association on a global network
# firewall policy, one per line. Prints nothing if the policy does not exist.
# Usage: firewall_policy_associations <policy> <project>
firewall_policy_associations() {
    gcloud compute network-firewall-policies describe "$1" \
        --global --project "$2" --format=json 2>/dev/null |
        jq -r '(if type == "array" then .[0] else . end)
            | .associations[]?
            | "\(.name) \(.attachmentTarget | split("/") | last)"'
}

# Succeeds if the first argument equals any of the remaining ones.
# Usage: in_list <needle> <item>...
in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Print "<association name> <network>" for every intercept endpoint group
# association attached to the given endpoint group, one per line.
#
# The API reports interceptEndpointGroup with the project NUMBER, not the project
# ID, so match on the trailing "/interceptEndpointGroups/<name>" only.
#
# Exits non-zero if the list call fails, so callers polling for "none left" do
# not mistake an API error for an empty result.
# Usage: endpoint_group_associations <endpoint group name> <project>
endpoint_group_associations() {
    local out
    out=$(gcloud beta network-security intercept-endpoint-group-associations list \
        --location=global --project="$2" --format=json) || return 1
    jq -r --arg suffix "/interceptEndpointGroups/$1" '
            .[]
            | select((.interceptEndpointGroup // "") | endswith($suffix))
            | "\(.name | split("/") | last) \(.network | split("/") | last)"' <<<"$out"
}
