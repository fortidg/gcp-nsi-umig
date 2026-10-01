#!/bin/bash

# Complete NSI Setup Script
# Run this script after terraform apply to complete the NSI configuration

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

# Shared CONSUMER_NETWORKS helpers. cleanup-nsi.sh sources the same file, which is
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
        exit 1
    fi
    
    if [ -z "$ORGANIZATION_ID" ]; then
        print_error "ORGANIZATION_ID environment variable is required"
        exit 1
    fi
    
    print_status "Using PROJECT_ID: $PROJECT_ID"
    print_status "Using ORGANIZATION_ID: $ORGANIZATION_ID"

    # Security profiles and profile groups live under the ORGANIZATION, so their
    # names share one namespace with every other project in the org. Derive them
    # from PROJECT_ID so parallel deployments cannot collide or silently reuse
    # each other's profile group. Override with NSI_NAME_PREFIX if needed.
    NSI_NAME_PREFIX="${NSI_NAME_PREFIX:-$PROJECT_ID}"
    SECURITY_PROFILE="${NSI_NAME_PREFIX}-ftnt-sp1"
    SECURITY_PROFILE_GROUP="${NSI_NAME_PREFIX}-ftnt-spg1"
    SECURITY_PROFILE_URI="organizations/$ORGANIZATION_ID/locations/global/securityProfiles/$SECURITY_PROFILE"
    SECURITY_PROFILE_GROUP_URI="organizations/$ORGANIZATION_ID/locations/global/securityProfileGroups/$SECURITY_PROFILE_GROUP"

    # The intercept resources live in PROJECT_ID, but the org-scoped commands in
    # steps 5-6 have no --project flag, so gcloud would expand a bare resource
    # name against the gcloud default core/project instead. Always pass the fully
    # qualified URI so the wrong project can never be picked up.
    DEPLOYMENT_GROUP="newfgt-nsi-ftnt-dg"
    ENDPOINT_GROUP="newfgt-nsi-ftnt-epg"
    DEPLOYMENT_GROUP_URI="projects/$PROJECT_ID/locations/global/interceptDeploymentGroups/$DEPLOYMENT_GROUP"
    ENDPOINT_GROUP_URI="projects/$PROJECT_ID/locations/global/interceptEndpointGroups/$ENDPOINT_GROUP"

    print_status "Security profile: $SECURITY_PROFILE"
    print_status "Security profile group: $SECURITY_PROFILE_GROUP"

    parse_consumer_networks || exit 1
    if [ ${#CONSUMER_NETWORK_LIST[@]} -gt 0 ]; then
        print_status "Consumer networks: ${CONSUMER_NETWORK_LIST[*]}"
    fi
}

# Get Terraform outputs
get_terraform_outputs() {
    print_status "Getting Terraform outputs..."

    INSPECTION_NETWORK=$(terraform output -json vpc_networks | jq -r '.inspection_vpc.name')
    MANAGEMENT_NETWORK=$(terraform output -json vpc_networks | jq -r '.management_vpc.name')
    # web_vpc / web2_vpc are null when deploy_web_servers = false; "// empty" turns
    # that into "" instead of the literal string "null".
    WEB_NETWORK=$(terraform output -json vpc_networks | jq -r '.web_vpc.name // empty')
    WEB2_NETWORK=$(terraform output -json vpc_networks | jq -r '.web2_vpc.name // empty')

    # Derive zones and forwarding rule names from the forwarding_rules output rather than
    # hardcoding them, so the script follows var.region / var.zones for any deployment.
    FORWARDING_RULES_JSON=$(terraform output -json forwarding_rules)

    ZONES=()
    while IFS= read -r zone; do
        ZONES+=("$zone")
    done < <(jq -r 'keys[]' <<<"$FORWARDING_RULES_JSON")

    if [ ${#ZONES[@]} -eq 0 ]; then
        print_error "No forwarding rules found in Terraform outputs. Run 'terraform apply' first."
        exit 1
    fi

    # The forwarding rule id looks like projects/<p>/regions/<region>/forwardingRules/<name>
    REGION=$(jq -r 'to_entries[0].value.id | split("/")[3]' <<<"$FORWARDING_RULES_JSON")

    print_status "Inspection Network: $INSPECTION_NETWORK"
    if [ -n "$WEB_NETWORK" ]; then
        print_status "Web Network: $WEB_NETWORK"
        print_status "Web2 Network: $WEB2_NETWORK"
    else
        print_status "Web VPCs: not deployed (deploy_web_servers = false)"
    fi
    print_status "Region: $REGION"
    print_status "Zones: ${ZONES[*]}"
}

# Check CONSUMER_NETWORKS before creating anything, so a typo fails the run up
# front instead of after half the NSI resources exist.
validate_consumer_networks() {
    local net problems=0 valid=()

    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        if [ "$net" = "$INSPECTION_NETWORK" ] || [ "$net" = "$MANAGEMENT_NETWORK" ]; then
            # Steering the FortiGates' own traffic back into themselves would loop it.
            print_error "CONSUMER_NETWORKS must not include the FortiGate network $net"
            problems=1
        elif [ "$net" = "$WEB_NETWORK" ] || [ "$net" = "$WEB2_NETWORK" ]; then
            print_warning "$net is a demo web VPC and is already associated; ignoring it in CONSUMER_NETWORKS"
        elif ! gcloud compute networks describe "$net" --project "$PROJECT_ID" --format="value(name)" >/dev/null 2>&1; then
            print_error "Consumer network $net not found in project $PROJECT_ID"
            problems=1
        else
            valid+=("$net")
        fi
    done

    if [ "$problems" -ne 0 ]; then
        print_error "Fix CONSUMER_NETWORKS and re-run. Nothing has been created."
        exit 1
    fi
    CONSUMER_NETWORK_LIST=("${valid[@]}")
}

# Associate the endpoint group with one consumer network. A failure only counts
# as "already exists" if the association can actually be found.
create_consumer_epg_association() {
    local net="$1" assoc
    assoc=$(consumer_assoc_name "$CONSUMER_EPG_ASSOC_PREFIX" "$net")

    print_status "Associating endpoint group with $net ($assoc)"
    gcloud beta network-security intercept-endpoint-group-associations create "$assoc" \
        --intercept-endpoint-group "$ENDPOINT_GROUP_URI" \
        --network "$net" \
        --project "$PROJECT_ID" \
        --location global \
        --no-async && return

    if gcloud beta network-security intercept-endpoint-group-associations describe "$assoc" \
        --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
        print_warning "Endpoint group association $assoc already exists, continuing..."
    else
        print_error "Could not associate endpoint group with $net (see error above)"
        SETUP_ERRORS=$((SETUP_ERRORS + 1))
    fi
}

# Associate the firewall policy with one consumer network.
create_consumer_policy_association() {
    local net="$1" assoc
    assoc=$(consumer_assoc_name "$CONSUMER_POLICY_ASSOC_PREFIX" "$net")

    print_status "Associating firewall policy with $net ($assoc)"
    gcloud compute network-firewall-policies associations create \
        --name "$assoc" \
        --global-firewall-policy \
        --firewall-policy newfgt-nsi \
        --network "$net" \
        --project "$PROJECT_ID" && return

    if firewall_policy_associations newfgt-nsi "$PROJECT_ID" | grep -q "^$assoc "; then
        print_warning "Firewall policy association $assoc already exists, continuing..."
    else
        print_error "Could not associate firewall policy with $net (see error above)."
        print_error "A VPC can have only one global network firewall policy; if $net already has one, its traffic cannot be steered to NSI by this policy."
        SETUP_ERRORS=$((SETUP_ERRORS + 1))
    fi
}

# Look up the forwarding rule name for a zone
forwarding_rule_for_zone() {
    jq -r --arg zone "$1" '.[$zone].name' <<<"$FORWARDING_RULES_JSON"
}

# Create NSI resources
create_nsi_resources() {
    SETUP_ERRORS=0

    print_step "1. Creating intercept deployment group..."
    gcloud beta network-security intercept-deployment-groups create "$DEPLOYMENT_GROUP" \
        --location global \
        --project "$PROJECT_ID" \
        --network "$INSPECTION_NETWORK" \
        --no-async || {
        print_warning "Intercept deployment group may already exist, continuing..."
    }
    
    print_step "2. Creating intercept deployments for each zone..."

    for zone in "${ZONES[@]}"; do
        deployment_name="fgt-nsi-${zone//-/}"
        forwarding_rule=$(forwarding_rule_for_zone "$zone")

        if [ -z "$forwarding_rule" ] || [ "$forwarding_rule" = "null" ]; then
            print_error "No forwarding rule found for zone $zone"
            exit 1
        fi

        print_status "Creating $deployment_name in $zone (forwarding rule: $forwarding_rule)"
        gcloud beta network-security intercept-deployments create "$deployment_name" \
            --location="$zone" \
            --project="$PROJECT_ID" \
            --forwarding-rule="$forwarding_rule" \
            --intercept-deployment-group="$DEPLOYMENT_GROUP_URI" \
            --forwarding-rule-location="$REGION" \
            --no-async || {
            print_warning "Intercept deployment $deployment_name may already exist, continuing..."
        }
    done

    print_step "3. Creating intercept endpoint group..."
    gcloud beta network-security intercept-endpoint-groups create "$ENDPOINT_GROUP" \
        --intercept-deployment-group "$DEPLOYMENT_GROUP_URI" \
        --project "$PROJECT_ID" \
        --location global \
        --no-async || {
        print_warning "Intercept endpoint group may already exist, continuing..."
    }
    
    print_step "4. Associating endpoint group with workload VPCs..."

    if [ -z "$WEB_NETWORK" ] && [ ${#CONSUMER_NETWORK_LIST[@]} -eq 0 ]; then
        print_warning "No demo web VPCs and no CONSUMER_NETWORKS; skipping endpoint group associations."
    fi

    if [ -n "$WEB_NETWORK" ]; then
        # Associate with first Web VPC
        gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc \
            --intercept-endpoint-group "$ENDPOINT_GROUP_URI" \
            --network "$WEB_NETWORK" \
            --project "$PROJECT_ID" \
            --location global \
            --no-async || {
            print_warning "Intercept endpoint group association for Web VPC may already exist, continuing..."
        }

        # Associate with second Web VPC
        gcloud beta network-security intercept-endpoint-group-associations create new-fgt-nsi-ftnt-epg-assoc-web2 \
            --intercept-endpoint-group "$ENDPOINT_GROUP_URI" \
            --network "$WEB2_NETWORK" \
            --project "$PROJECT_ID" \
            --location global \
            --no-async || {
            print_warning "Intercept endpoint group association for Web2 VPC may already exist, continuing..."
        }
    fi

    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        create_consumer_epg_association "$net"
    done
    
    print_step "5. Creating security profile..."
    gcloud beta network-security security-profiles custom-intercept create "$SECURITY_PROFILE" \
        --intercept-endpoint-group "$ENDPOINT_GROUP_URI" \
        --billing-project "$PROJECT_ID" \
        --organization "$ORGANIZATION_ID" \
        --location global || {
        # Steps 6 and 8 both reference this profile, so a create failure that is
        # not "already exists" has to stop the run rather than cascade.
        gcloud beta network-security security-profiles custom-intercept describe "$SECURITY_PROFILE" \
            --billing-project "$PROJECT_ID" \
            --organization "$ORGANIZATION_ID" \
            --location global >/dev/null 2>&1 || {
            print_error "Could not create security profile $SECURITY_PROFILE (see error above)"
            exit 1
        }
        print_warning "Security profile $SECURITY_PROFILE already exists, continuing..."
    }

    print_step "6. Creating security profile group..."
    gcloud beta network-security security-profile-groups create "$SECURITY_PROFILE_GROUP" \
        --custom-intercept-profile "$SECURITY_PROFILE_URI" \
        --billing-project "$PROJECT_ID" \
        --organization "$ORGANIZATION_ID" \
        --location global || {
        # The firewall rules in step 8 reference this group by URI, so bail out
        # instead of creating rules that cannot resolve it.
        gcloud beta network-security security-profile-groups describe "$SECURITY_PROFILE_GROUP" \
            --billing-project "$PROJECT_ID" \
            --organization "$ORGANIZATION_ID" \
            --location global >/dev/null 2>&1 || {
            print_error "Could not create security profile group $SECURITY_PROFILE_GROUP (see error above)"
            exit 1
        }
        print_warning "Security profile group $SECURITY_PROFILE_GROUP already exists, continuing..."
    }
    
    print_step "7. Creating firewall policy..."
    gcloud compute network-firewall-policies create newfgt-nsi \
        --project "$PROJECT_ID" \
        --global || {
        print_warning "Firewall policy may already exist, continuing..."
    }
    
    print_step "8. Creating firewall policy rules..."
    gcloud beta compute network-firewall-policies rules create 10 \
        --action=APPLY_SECURITY_PROFILE_GROUP \
        --firewall-policy newfgt-nsi \
        --global-firewall-policy \
        --project "$PROJECT_ID" \
        --security-profile-group "$SECURITY_PROFILE_GROUP_URI" \
        --layer4-configs all \
        --src-ip-ranges 0.0.0.0/0 \
        --dest-ip-ranges 0.0.0.0/0 \
        --direction INGRESS || {
        print_warning "Firewall policy rule 10 may already exist, continuing..."
    }
    
    gcloud beta compute network-firewall-policies rules create 11 \
        --action=APPLY_SECURITY_PROFILE_GROUP \
        --firewall-policy newfgt-nsi \
        --global-firewall-policy \
        --project "$PROJECT_ID" \
        --security-profile-group "$SECURITY_PROFILE_GROUP_URI" \
        --layer4-configs all \
        --src-ip-ranges 0.0.0.0/0 \
        --dest-ip-ranges 0.0.0.0/0 \
        --direction EGRESS || {
        print_warning "Firewall policy rule 11 may already exist, continuing..."
    }
    
    print_step "9. Associating policy with workload VPCs..."

    if [ -z "$WEB_NETWORK" ] && [ ${#CONSUMER_NETWORK_LIST[@]} -eq 0 ]; then
        print_warning "No demo web VPCs and no CONSUMER_NETWORKS; skipping firewall policy associations."
    fi

    if [ -n "$WEB_NETWORK" ]; then
        # Associate with first Web VPC
        gcloud compute network-firewall-policies associations create \
            --name newfgt-nsi-policy-assoc \
            --global-firewall-policy \
            --firewall-policy newfgt-nsi \
            --network "$WEB_NETWORK" \
            --project "$PROJECT_ID" || {
            print_warning "Firewall policy association for Web VPC may already exist, continuing..."
        }

        # Associate with second Web VPC
        gcloud compute network-firewall-policies associations create \
            --name newfgt-nsi-policy-assoc-web2 \
            --global-firewall-policy \
            --firewall-policy newfgt-nsi \
            --network "$WEB2_NETWORK" \
            --project "$PROJECT_ID" || {
            print_warning "Firewall policy association for Web2 VPC may already exist, continuing..."
        }
    fi

    for net in "${CONSUMER_NETWORK_LIST[@]}"; do
        create_consumer_policy_association "$net"
    done
}

# Main execution
main() {
    print_status "Starting NSI setup script..."
    
    check_variables
    get_terraform_outputs
    validate_consumer_networks
    create_nsi_resources

    if [ "$SETUP_ERRORS" -gt 0 ]; then
        print_error "$SETUP_ERRORS consumer network association(s) failed. Fix the errors above and re-run;"
        print_error "resources that already exist are skipped."
        exit 1
    fi

    print_status "NSI setup completed successfully!"
    if [ -n "$WEB_NETWORK" ] || [ ${#CONSUMER_NETWORK_LIST[@]} -gt 0 ]; then
        print_status "Your FortiGate NSI deployment is now ready for traffic inspection."
    else
        # Without associations nothing is steered to the FortiGates yet.
        print_warning "No workload VPCs are associated, so no traffic is being inspected yet."
        print_warning "List the VPCs to inspect in CONSUMER_NETWORKS and re-run, e.g.:"
        echo "  CONSUMER_NETWORKS=\"prod-vpc,staging-vpc\" $0"
    fi
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
    echo "  CONSUMER_NETWORKS - Comma/space-separated VPC names in PROJECT_ID to inspect,"
    echo "                      in addition to the demo web VPCs (if deployed)"
    echo ""
    echo "Example:"
    echo "  export PROJECT_ID=your-project-id"
    echo "  export ORGANIZATION_ID=123456789012"
    echo "  export CONSUMER_NETWORKS=prod-vpc,staging-vpc   # optional"
    echo "  $0"
    echo ""
    print_error "Please set PROJECT_ID and ORGANIZATION_ID environment variables"
    exit 1
fi