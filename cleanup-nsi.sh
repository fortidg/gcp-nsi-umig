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

    print_status "Security profile: $SECURITY_PROFILE"
    print_status "Security profile group: $SECURITY_PROFILE_GROUP"
}

# Helper: delete a resource and treat NOT_FOUND as success; exit on other errors
delete_or_skip() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        print_status "Deleted: $desc"
    elif echo "$output" | grep -qE "NOT_FOUND|was not found|Could not fetch resource|already deleted"; then
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

    if echo "$output" | grep -qE "NOT_FOUND|was not found|Could not fetch resource|already deleted"; then
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
    local waited=0 interval=10 remaining

    while [ "$waited" -lt "$timeout" ]; do
        remaining=$("$@" 2>/dev/null | grep -c . || true)
        if [ "${remaining:-0}" -eq 0 ]; then
            [ "$waited" -gt 0 ] && print_status "$desc cleared after ${waited}s"
            return 0
        fi
        print_status "Waiting for $desc to clear (${remaining} remaining, ${waited}s elapsed)..."
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

    print_step "1. Removing firewall policy associations..."

    # Remove association from Web2 VPC
    delete_or_skip "firewall policy association newfgt-nsi-policy-assoc-web2" \
        gcloud compute network-firewall-policies associations delete \
            --name newfgt-nsi-policy-assoc-web2 \
            --global-firewall-policy \
            --firewall-policy newfgt-nsi \
            --project "$PROJECT_ID" \
            --quiet

    # Remove association from Web VPC
    delete_or_skip "firewall policy association newfgt-nsi-policy-assoc" \
        gcloud compute network-firewall-policies associations delete \
            --name newfgt-nsi-policy-assoc \
            --global-firewall-policy \
            --firewall-policy newfgt-nsi \
            --project "$PROJECT_ID" \
            --quiet

    print_step "2. Deleting firewall policy rules..."
    delete_or_skip "firewall policy rule 11" \
        gcloud compute network-firewall-policies rules delete 11 \
            --firewall-policy newfgt-nsi \
            --global-firewall-policy \
            --project "$PROJECT_ID" \
            --quiet

    delete_or_skip "firewall policy rule 10" \
        gcloud compute network-firewall-policies rules delete 10 \
            --firewall-policy newfgt-nsi \
            --global-firewall-policy \
            --project "$PROJECT_ID" \
            --quiet

    print_step "3. Deleting firewall policy..."
    delete_or_skip "firewall policy newfgt-nsi" \
        gcloud compute network-firewall-policies delete newfgt-nsi \
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
    delete_or_skip "intercept endpoint group association new-fgt-nsi-ftnt-epg-assoc-web2" \
        gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc-web2 \
            --project "$PROJECT_ID" \
            --location global \
            --quiet

    # Delete Web VPC association
    delete_or_skip "intercept endpoint group association new-fgt-nsi-ftnt-epg-assoc" \
        gcloud beta network-security intercept-endpoint-group-associations delete new-fgt-nsi-ftnt-epg-assoc \
            --project "$PROJECT_ID" \
            --location global \
            --quiet

    print_step "7. Deleting intercept endpoint group..."
    # Association deletion is asynchronous: poll until the associations are really
    # gone rather than guessing at a fixed sleep.
    wait_until_gone "endpoint group associations" 300 \
        gcloud beta network-security intercept-endpoint-group-associations list \
            --location=global --project="$PROJECT_ID" --format="value(name)"
    delete_or_skip "intercept endpoint group newfgt-nsi-ftnt-epg" \
        gcloud beta network-security intercept-endpoint-groups delete newfgt-nsi-ftnt-epg \
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
    delete_or_skip "intercept deployment group newfgt-nsi-ftnt-dg" \
        gcloud beta network-security intercept-deployment-groups delete newfgt-nsi-ftnt-dg \
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