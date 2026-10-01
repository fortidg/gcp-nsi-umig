#!/bin/bash

# NSI Cleanup Script
# Run this script before terraform destroy to clean up manually created NSI resources

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Shared CONSUMER_NETWORKS helpers. setup-nsi.sh sources the same file, which is
# what keeps the association names the two scripts derive identical.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=nsi-common.sh
source "$SCRIPT_DIR/nsi-common.sh" || {
    print_error "Could not load $SCRIPT_DIR/nsi-common.sh"
    exit 1
}

# Check if required variables are set
check_variables() {
    if [ -z "$PROJECT_ID" ]; then
        print_error "PROJECT_ID environment variable is required"
        print_error "Usage: PROJECT_ID=your-project-id ORGANIZATION_ID=your-org-id $0"
        exit 1
    fi
    
    if [ -z "$ORGANIZATION_ID" ]; then
        print_error "ORGANIZATION_ID environment variable is required"
        print_error "Usage: PROJECT_ID=your-project-id ORGANIZATION_ID=your-org-id $0"
        exit 1
    fi
    
    print_status "Using PROJECT_ID: $PROJECT_ID"
    print_status "Using ORGANIZATION_ID: $ORGANIZATION_ID"

    # Needed to tell our own references apart from other projects' when an
    # org-level resource reports itself as still in use.
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
    if [ -z "$PROJECT_NUMBER" ]; then
        print_warning "Could not resolve project number for $PROJECT_ID"
    else
        print_status "Project number: $PROJECT_NUMBER"
    fi

    # Must match the naming scheme in setup-nsi.sh: these are org-level resources
    # sharing one namespace across the whole organization.
    NSI_NAME_PREFIX="${NSI_NAME_PREFIX:-$PROJECT_ID}"
    SECURITY_PROFILE="${NSI_NAME_PREFIX}-ftnt-sp1"
    SECURITY_PROFILE_GROUP="${NSI_NAME_PREFIX}-ftnt-spg1"

    # Project-level resource names. Every one of these must stay identical to the
    # matching variable in setup-nsi.sh, or cleanup silently skips resources that
    # setup created and terraform destroy then fails on the VPCs.
    DEPLOYMENT_GROUP="newfgt-nsi-ftnt-dg"
    ENDPOINT_GROUP="newfgt-nsi-ftnt-epg"
    ENDPOINT_GROUP_ASSOC="new-fgt-nsi-ftnt-epg-assoc"
    ENDPOINT_GROUP_ASSOC_WEB2="new-fgt-nsi-ftnt-epg-assoc-web2"
    FIREWALL_POLICY="newfgt-nsi"
    POLICY_ASSOC="newfgt-nsi-policy-assoc"
    POLICY_ASSOC_WEB2="newfgt-nsi-policy-assoc-web2"

    print_status "Security profile: $SECURITY_PROFILE"
    print_status "Security profile group: $SECURITY_PROFILE_GROUP"

    # Must be the same CONSUMER_NETWORKS that setup-nsi.sh was run with.
    parse_consumer_networks || exit 1
    if [ ${#CONSUMER_NETWORK_LIST[@]} -gt 0 ]; then
        print_status "Consumer networks: ${CONSUMER_NETWORK_LIST[*]}"
    fi

    # Every association this run will delete. Anything else still attached to
    # our firewall policy or endpoint group blocks the cleanup (see
    # preflight_check_associations).
    KNOWN_POLICY_ASSOCS=("$POLICY_ASSOC" "$POLICY_ASSOC_WEB2")
    KNOWN_EPG_ASSOCS=("$ENDPOINT_GROUP_ASSOC" "$ENDPOINT_GROUP_ASSOC_WEB2")
    local net
    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        KNOWN_POLICY_ASSOCS+=("$(consumer_assoc_name "$CONSUMER_POLICY_ASSOC_PREFIX" "$net")")
        KNOWN_EPG_ASSOCS+=("$(consumer_assoc_name "$CONSUMER_EPG_ASSOC_PREFIX" "$net")")
    done
}

# Refuse to start if the firewall policy or endpoint group has an association this
# run will not delete -- one made by hand, or for a network left out of
# CONSUMER_NETWORKS. Neither parent can be deleted while it is attached, and
# carrying on would tear down the intercept deployments while that VPC's traffic
# is still being steered to them. Checking first means nothing has been deleted
# yet when we stop.
preflight_check_associations() {
    local name net out unknown=0

    while read -r name net; do
        [ -z "$name" ] && continue
        if ! in_list "$name" "${KNOWN_POLICY_ASSOCS[@]}"; then
            print_error "Firewall policy $FIREWALL_POLICY is also associated with network $net (association $name)"
            unknown=1
        fi
    done < <(firewall_policy_associations "$FIREWALL_POLICY" "$PROJECT_ID")

    if out=$(endpoint_group_associations "$ENDPOINT_GROUP" "$PROJECT_ID" 2>/dev/null); then
        while read -r name net; do
            [ -z "$name" ] && continue
            if ! in_list "$name" "${KNOWN_EPG_ASSOCS[@]}"; then
                print_error "Endpoint group $ENDPOINT_GROUP is also associated with network $net (association $name)"
                unknown=1
            fi
        done <<<"$out"
    else
        print_warning "Could not list endpoint group associations; skipping the pre-flight check for them."
    fi

    if [ "$unknown" -ne 0 ]; then
        print_error "Nothing has been deleted. Either add those networks to CONSUMER_NETWORKS"
        print_error "(if setup-nsi.sh created them), or delete the associations listed above, then re-run."
        exit 1
    fi
}

# Does this gcloud error mean "the resource is already gone"?
#
# Deliberately narrow. "Could not fetch resource" is gcloud's generic wrapper for
# the compute API and also fronts resource-in-use and permission errors, so
# matching on it alone would silently report a still-referenced firewall policy as
# "not found, skipping" and let terraform destroy fail later on the VPC. Match the
# specific absent-resource wording each command actually emits instead.
is_not_found() {
    grep -qE "NOT_FOUND|was not found|does not have a rule at priority|does not have an association with|already deleted" <<<"$1"
}

# Helper: delete a resource and treat NOT_FOUND as success; count other errors
delete_or_skip() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        print_status "Deleted: $desc"
    elif is_not_found "$output"; then
        print_warning "$desc not found, skipping"
    else
        print_error "Failed to delete $desc:"
        echo "$output" >&2
        CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi
}

# Org-level resources (security profiles / profile groups) live under the
# organization, not the project, so other projects in the same org may reference
# them. Deleting one that is still in use elsewhere is not our failure to fix:
# report which projects hold it and leave it in place.
delete_or_skip_shared() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1)
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        print_status "Deleted: $desc"
        return
    fi

    if is_not_found "$output"; then
        print_warning "$desc not found, skipping"
        return
    fi

    if echo "$output" | grep -q "already being used by"; then
        # Collect the project numbers still referencing this resource
        local refs others
        refs=$(echo "$output" | grep -o 'projects/[0-9]\{4,\}' | sed 's|projects/||' | sort -u)
        others=$(echo "$refs" | grep -v "^${PROJECT_NUMBER}$" || true)

        if [ -n "$others" ]; then
            print_warning "$desc is shared and still referenced by other project(s) in org $ORGANIZATION_ID:"
            for n in $others; do
                local pid
                pid=$(gcloud projects describe "$n" --format="value(projectId)" 2>/dev/null || echo "$n")
                print_warning "    - ${pid:-$n} (project number $n)"
            done
            print_warning "Leaving $desc in place. Deleting it would break those deployments."
            SHARED_LEFT_IN_PLACE=1
            return
        fi
    fi

    print_error "Failed to delete $desc:"
    echo "$output" >&2
    CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
}

# Poll until a list command returns no results, so we do not race async deletes.
# Usage: wait_until_gone "<description>" <timeout_seconds> <list command...>
wait_until_gone() {
    local desc="$1" timeout="$2"
    shift 2
    local waited=0 interval=10 out rc remaining

    while [ "$waited" -lt "$timeout" ]; do
        out=$("$@" 2>&1)
        rc=$?
        if [[ $rc -eq 0 ]]; then
            remaining=$(grep -c . <<<"$out" || true)
            if [ "${remaining:-0}" -eq 0 ]; then
                [ "$waited" -gt 0 ] && print_status "$desc cleared after ${waited}s"
                return 0
            fi
            print_status "Waiting for $desc to clear (${remaining} remaining, ${waited}s elapsed)..."
        else
            # A failed list says nothing about whether the resources are gone. Keep
            # waiting instead of reading the empty output as "cleared" and deleting
            # the parent too early.
            print_warning "Could not list $desc (${waited}s elapsed); retrying..."
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done

    print_warning "$desc did not clear within ${timeout}s; continuing anyway"
    return 1
}

# Discover the deployment zones from Terraform outputs so cleanup follows
# var.region / var.zones instead of hardcoded zone names.
get_zones() {
    ZONES=()

    if ! forwarding_rules_json=$(terraform output -json forwarding_rules 2>/dev/null); then
        print_warning "Could not read Terraform outputs; skipping intercept deployment cleanup."
        return
    fi

    while IFS= read -r zone; do
        ZONES+=("$zone")
    done < <(jq -r 'keys[]' <<<"$forwarding_rules_json" 2>/dev/null)

    if [ ${#ZONES[@]} -eq 0 ]; then
        print_warning "No zones found in Terraform outputs; skipping intercept deployment cleanup."
        return
    fi

    print_status "Zones: ${ZONES[*]}"
}

# Delete NSI resources in the correct order (reverse of creation)
cleanup_nsi_resources() {
    CLEANUP_ERRORS=0
    SHARED_LEFT_IN_PLACE=0
    get_zones
    preflight_check_associations

    print_step "1. Removing firewall policy associations..."

    # Remove association from Web2 VPC
    delete_or_skip "firewall policy association $POLICY_ASSOC_WEB2" \
        gcloud compute network-firewall-policies associations delete \
            --name "$POLICY_ASSOC_WEB2" \
            --global-firewall-policy \
            --firewall-policy "$FIREWALL_POLICY" \
            --project "$PROJECT_ID" \
            --quiet

    # Remove association from Web VPC
    delete_or_skip "firewall policy association $POLICY_ASSOC" \
        gcloud compute network-firewall-policies associations delete \
            --name "$POLICY_ASSOC" \
            --global-firewall-policy \
            --firewall-policy "$FIREWALL_POLICY" \
            --project "$PROJECT_ID" \
            --quiet

    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        assoc=$(consumer_assoc_name "$CONSUMER_POLICY_ASSOC_PREFIX" "$net")
        delete_or_skip "firewall policy association $assoc ($net)" \
            gcloud compute network-firewall-policies associations delete \
                --name "$assoc" \
                --global-firewall-policy \
                --firewall-policy "$FIREWALL_POLICY" \
                --project "$PROJECT_ID" \
                --quiet
    done

    print_step "2. Deleting firewall policy rules..."
    delete_or_skip "firewall policy rule 11" \
        gcloud compute network-firewall-policies rules delete 11 \
            --firewall-policy "$FIREWALL_POLICY" \
            --global-firewall-policy \
            --project "$PROJECT_ID" \
            --quiet

    delete_or_skip "firewall policy rule 10" \
        gcloud compute network-firewall-policies rules delete 10 \
            --firewall-policy "$FIREWALL_POLICY" \
            --global-firewall-policy \
            --project "$PROJECT_ID" \
            --quiet

    print_step "3. Deleting firewall policy..."
    delete_or_skip "firewall policy $FIREWALL_POLICY" \
        gcloud compute network-firewall-policies delete "$FIREWALL_POLICY" \
            --project "$PROJECT_ID" \
            --global \
            --quiet

    print_step "4. Deleting security profile group..."
    delete_or_skip_shared "security profile group $SECURITY_PROFILE_GROUP" \
        gcloud beta network-security security-profile-groups delete "$SECURITY_PROFILE_GROUP" \
            --billing-project "$PROJECT_ID" \
            --organization "$ORGANIZATION_ID" \
            --location global \
            --quiet

    print_step "5. Deleting security profile..."
    if [ "$SHARED_LEFT_IN_PLACE" -eq 1 ]; then
        print_warning "Skipping security profile $SECURITY_PROFILE: the profile group above"
        print_warning "was left in place for other projects and still references it."
    else
        delete_or_skip_shared "security profile $SECURITY_PROFILE" \
            gcloud beta network-security security-profiles custom-intercept delete "$SECURITY_PROFILE" \
                --billing-project "$PROJECT_ID" \
                --organization "$ORGANIZATION_ID" \
                --location global \
                --quiet
    fi

    print_step "6. Deleting intercept endpoint group associations..."

    # Delete Web2 VPC association
    delete_or_skip "intercept endpoint group association $ENDPOINT_GROUP_ASSOC_WEB2" \
        gcloud beta network-security intercept-endpoint-group-associations delete "$ENDPOINT_GROUP_ASSOC_WEB2" \
            --project "$PROJECT_ID" \
            --location global \
            --quiet

    # Delete Web VPC association
    delete_or_skip "intercept endpoint group association $ENDPOINT_GROUP_ASSOC" \
        gcloud beta network-security intercept-endpoint-group-associations delete "$ENDPOINT_GROUP_ASSOC" \
            --project "$PROJECT_ID" \
            --location global \
            --quiet

    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        assoc=$(consumer_assoc_name "$CONSUMER_EPG_ASSOC_PREFIX" "$net")
        delete_or_skip "intercept endpoint group association $assoc ($net)" \
            gcloud beta network-security intercept-endpoint-group-associations delete "$assoc" \
                --project "$PROJECT_ID" \
                --location global \
                --quiet
    done

    print_step "7. Deleting intercept endpoint group..."
    # Association deletion is asynchronous: poll until the associations are really
    # gone rather than guessing at a fixed sleep. Only ours count -- associations on
    # other endpoint groups in the project do not block this one.
    wait_until_gone "endpoint group associations" 300 \
        endpoint_group_associations "$ENDPOINT_GROUP" "$PROJECT_ID"
    delete_or_skip "intercept endpoint group $ENDPOINT_GROUP" \
        gcloud beta network-security intercept-endpoint-groups delete "$ENDPOINT_GROUP" \
            --project "$PROJECT_ID" \
            --location global \
            --quiet

    print_step "8. Deleting intercept deployments..."
    for zone in "${ZONES[@]}"; do
        deployment_name="fgt-nsi-${zone//-/}"
        delete_or_skip "intercept deployment $deployment_name" \
            gcloud beta network-security intercept-deployments delete "$deployment_name" \
                --location="$zone" \
                --project="$PROJECT_ID" \
                --quiet
    done

    if [[ $CLEANUP_ERRORS -gt 0 ]]; then
        print_error "$CLEANUP_ERRORS resource(s) failed to delete. Resolve the errors above before continuing."
        exit 1
    fi

    print_step "9. Deleting intercept deployment group..."
    # Deployment deletion is asynchronous: poll every zone until none remain.
    for zone in "${ZONES[@]}"; do
        wait_until_gone "intercept deployments in $zone" 300 \
            gcloud beta network-security intercept-deployments list \
                --location="$zone" --project="$PROJECT_ID" --format="value(name)"
    done
    # The endpoint group deleted in step 7 also holds a reference to the deployment
    # group until its own async deletion completes.
    wait_until_gone "intercept endpoint groups" 300 \
        gcloud beta network-security intercept-endpoint-groups list \
            --location=global --project="$PROJECT_ID" --format="value(name)"
    delete_or_skip "intercept deployment group $DEPLOYMENT_GROUP" \
        gcloud beta network-security intercept-deployment-groups delete "$DEPLOYMENT_GROUP" \
            --location global \
            --project "$PROJECT_ID" \
            --quiet

    if [[ $CLEANUP_ERRORS -gt 0 ]]; then
        print_error "Intercept deployment group deletion failed. Resolve errors above before running terraform destroy."
        exit 1
    fi
}

# Main execution
main() {
    print_status "Starting NSI cleanup script..."

    check_variables
    cleanup_nsi_resources

    print_status "NSI cleanup completed successfully!"
    print_status "You can now proceed with 'terraform destroy --auto-approve'"
}

# Check if environment variables are set and run
if [ -n "$PROJECT_ID" ] && [ -n "$ORGANIZATION_ID" ]; then
    main
else
    echo "Usage: $0"
    echo ""
    echo "Environment variables required:"
    echo "  PROJECT_ID      - GCP Project ID"
    echo "  ORGANIZATION_ID - GCP Organization ID"
    echo ""
    echo "Optional:"
    echo "  CONSUMER_NETWORKS - The same VPC list setup-nsi.sh was run with"
    echo ""
    echo "Example:"
    echo "  export PROJECT_ID=your-project-id"
    echo "  export ORGANIZATION_ID=123456789012"
    echo "  $0"
    echo ""
    echo "Or run directly:"
    echo "  PROJECT_ID=your-project-id ORGANIZATION_ID=your-org-id $0"
    echo ""
    print_error "Please set PROJECT_ID and ORGANIZATION_ID environment variables"
    exit 1
fi