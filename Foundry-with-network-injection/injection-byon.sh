#!/usr/bin/env bash

set -euo pipefail

# Show CLI usage.
usage() {
	cat <<'EOF'
Usage:
	./build-environment.sh --resource-group <name> --location <azure-region> --foundry-account <name> [options]

Required:
	--resource-group <name>     Resource group to create or reuse.
	--location <azure-region>   Azure region, for example eastus2.
	--foundry-account <name>    Azure AI Foundry account name.

Optional:
	--project-name <name>       Foundry project name. Default: <foundry-account>-project
	--project-display <name>    Project display name. Default: same as project name
	--project-description <txt> Project description.
	--subscription <id>         Subscription ID to target.
	--vnet-name <name>          Virtual network name. Default: foundry-vnet
	--vnet-prefix <cidr>        VNet CIDR. Default: 10.30.0.0/16
	--agent-subnet-name <name>  Delegated subnet name. Default: agent-snet
	--agent-subnet-prefix <cidr> Delegated subnet CIDR. Default: 10.30.0.0/27
	--pe-subnet-name <name>     Private endpoint subnet name. Default: pe-subnet
	--pe-subnet-prefix <cidr>   Private endpoint subnet CIDR. Default: 10.30.1.0/24
	--public-network-access <Enabled|Disabled>
	                             Default: Disabled
	--help                      Show this help text.

Notes:
	- The agent subnet is delegated to Microsoft.App/environments.
	- The pe-subnet is created for future private endpoints but this script does not
		create private endpoints for dependent services.
	- The Foundry account is deployed with networkInjections pointing to the agent subnet.
EOF
}

# Fail early if a required command is missing.
require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

# Timestamped log output for long-running Azure operations.
log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Default values. These can all be overridden by CLI arguments.
RESOURCE_GROUP='your-rg-name'
LOCATION='your-location'
SUBSCRIPTION_ID='your-SUBSCRIPTION-id'
FOUNDRY_ACCOUNT_NAME='foundry-name'
PROJECT_NAME='foundry-project-name'
PROJECT_DISPLAY_NAME='project-display-name'
PROJECT_DESCRIPTION='project subscription'
VNET_NAME='your-vnet-name'
VNET_PREFIX='10.XX.0.0/16'
AGENT_SUBNET_NAME='agent-snet'
AGENT_SUBNET_PREFIX='10.XX.0.0/24'
PE_SUBNET_NAME='pe-subnet'
PE_SUBNET_PREFIX='10.XX.1.0/24'
PUBLIC_NETWORK_ACCESS='Disabled'

# Parse CLI arguments.
while [[ $# -gt 0 ]]; do
	case "$1" in
		--resource-group)
			RESOURCE_GROUP="$2"
			shift 2
			;;
		--location)
			LOCATION="$2"
			shift 2
			;;
		--subscription)
			SUBSCRIPTION_ID="$2"
			shift 2
			;;
		--foundry-account)
			FOUNDRY_ACCOUNT_NAME="$2"
			shift 2
			;;
		--project-name)
			PROJECT_NAME="$2"
			shift 2
			;;
		--project-display)
			PROJECT_DISPLAY_NAME="$2"
			shift 2
			;;
		--project-description)
			PROJECT_DESCRIPTION="$2"
			shift 2
			;;
		--vnet-name)
			VNET_NAME="$2"
			shift 2
			;;
		--vnet-prefix)
			VNET_PREFIX="$2"
			shift 2
			;;
		--agent-subnet-name)
			AGENT_SUBNET_NAME="$2"
			shift 2
			;;
		--agent-subnet-prefix)
			AGENT_SUBNET_PREFIX="$2"
			shift 2
			;;
		--pe-subnet-name)
			PE_SUBNET_NAME="$2"
			shift 2
			;;
		--pe-subnet-prefix)
			PE_SUBNET_PREFIX="$2"
			shift 2
			;;
		--public-network-access)
			PUBLIC_NETWORK_ACCESS="$2"
			shift 2
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

# Normalize and validate inputs before touching Azure.
if [[ -z "$RESOURCE_GROUP" || -z "$LOCATION" || -z "$FOUNDRY_ACCOUNT_NAME" ]]; then
	usage >&2
	exit 1
fi

if [[ -z "$PROJECT_NAME" ]]; then
	PROJECT_NAME="${FOUNDRY_ACCOUNT_NAME}-project"
fi

if [[ -z "$PROJECT_DISPLAY_NAME" ]]; then
	PROJECT_DISPLAY_NAME="$PROJECT_NAME"
fi

if [[ ! "$PUBLIC_NETWORK_ACCESS" =~ ^(Enabled|Disabled)$ ]]; then
	echo "--public-network-access must be Enabled or Disabled" >&2
	exit 1
fi

if [[ ! "$FOUNDRY_ACCOUNT_NAME" =~ ^[a-z0-9-]{2,64}$ ]]; then
	echo "Foundry account name must be 2-64 characters of lowercase letters, numbers, or hyphens." >&2
	exit 1
fi

require_command az

if ! az account show >/dev/null 2>&1; then
	echo 'Azure CLI is not logged in. Run: az login' >&2
	exit 1
fi

if [[ -n "$SUBSCRIPTION_ID" ]]; then
	log "Setting Azure subscription to ${SUBSCRIPTION_ID}"
	az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
fi

# Temporary files are generated at runtime for the ARM deployment payload.
DEPLOYMENT_NAME="foundry-network-$(date '+%Y%m%d%H%M%S')"
WORK_DIR="$(mktemp -d)"
TEMPLATE_FILE="${WORK_DIR}/foundry-template.json"
PARAMS_FILE="${WORK_DIR}/foundry-parameters.json"

# Always clean up generated files.
cleanup() {
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT

log 'Registering required resource providers'
az provider register --namespace Microsoft.Network --wait >/dev/null
az provider register --namespace Microsoft.App --wait >/dev/null
az provider register --namespace Microsoft.CognitiveServices --wait >/dev/null

# Network prerequisites for Foundry agent VNet injection.
log "Ensuring resource group ${RESOURCE_GROUP} exists"
az group create \
	--name "$RESOURCE_GROUP" \
	--location "$LOCATION" \
	--output none

log "Creating virtual network ${VNET_NAME} and delegated subnet ${AGENT_SUBNET_NAME}"
az network vnet create \
	--resource-group "$RESOURCE_GROUP" \
	--location "$LOCATION" \
	--name "$VNET_NAME" \
	--address-prefixes "$VNET_PREFIX" \
	--subnet-name "$AGENT_SUBNET_NAME" \
	--subnet-prefixes "$AGENT_SUBNET_PREFIX" \
	--output none

az network vnet subnet update \
	--resource-group "$RESOURCE_GROUP" \
	--vnet-name "$VNET_NAME" \
	--name "$AGENT_SUBNET_NAME" \
	--delegations Microsoft.App/environments \
	--output none

log "Creating private endpoint subnet ${PE_SUBNET_NAME}"
az network vnet subnet create \
	--resource-group "$RESOURCE_GROUP" \
	--vnet-name "$VNET_NAME" \
	--name "$PE_SUBNET_NAME" \
	--address-prefixes "$PE_SUBNET_PREFIX" \
	--private-endpoint-network-policies Disabled \
	--output none

# Capture subnet IDs for the generated ARM parameters file.
AGENT_SUBNET_ID="$(az network vnet subnet show \
	--resource-group "$RESOURCE_GROUP" \
	--vnet-name "$VNET_NAME" \
	--name "$AGENT_SUBNET_NAME" \
	--query id \
	--output tsv)"

PE_SUBNET_ID="$(az network vnet subnet show \
	--resource-group "$RESOURCE_GROUP" \
	--vnet-name "$VNET_NAME" \
	--name "$PE_SUBNET_NAME" \
	--query id \
	--output tsv)"

# ARM template for the Foundry account and project resources.
cat > "$TEMPLATE_FILE" <<'EOF'
{
	"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
	"contentVersion": "1.0.0.0",
	"parameters": {
		"location": {
			"type": "string"
		},
		"foundryAccountName": {
			"type": "string"
		},
		"projectName": {
			"type": "string"
		},
		"projectDisplayName": {
			"type": "string"
		},
		"projectDescription": {
			"type": "string"
		},
		"agentSubnetId": {
			"type": "string"
		},
		"publicNetworkAccess": {
			"type": "string",
			"allowedValues": [
				"Enabled",
				"Disabled"
			]
		}
	},
	"resources": [
		{
			"type": "Microsoft.CognitiveServices/accounts",
			"apiVersion": "2026-03-01",
			"name": "[parameters('foundryAccountName')]",
			"location": "[parameters('location')]",
			"kind": "AIServices",
			"identity": {
				"type": "SystemAssigned"
			},
			"sku": {
				"name": "S0"
			},
			"properties": {
				"allowProjectManagement": true,
				"customSubDomainName": "[parameters('foundryAccountName')]",
				"disableLocalAuth": false,
				"publicNetworkAccess": "[parameters('publicNetworkAccess')]",
				"networkAcls": {
					"bypass": "AzureServices",
					"defaultAction": "Deny",
					"ipRules": [],
					"virtualNetworkRules": []
				},
				"networkInjections": [
					{
						"scenario": "agent",
						"subnetArmId": "[parameters('agentSubnetId')]",
						"useMicrosoftManagedNetwork": false
					}
				],
				"restrictOutboundNetworkAccess": true
			}
		},
		{
			"type": "Microsoft.CognitiveServices/accounts/projects",
			"apiVersion": "2026-03-01",
			"name": "[format('{0}/{1}', parameters('foundryAccountName'), parameters('projectName'))]",
			"location": "[parameters('location')]",
			"identity": {
				"type": "SystemAssigned"
			},
			"dependsOn": [
				"[resourceId('Microsoft.CognitiveServices/accounts', parameters('foundryAccountName'))]"
			],
			"properties": {
				"displayName": "[parameters('projectDisplayName')]",
				"description": "[parameters('projectDescription')]"
			}
		}
	],
	"outputs": {
		"foundryAccountId": {
			"type": "string",
			"value": "[resourceId('Microsoft.CognitiveServices/accounts', parameters('foundryAccountName'))]"
		},
		"foundryProjectId": {
			"type": "string",
			"value": "[resourceId('Microsoft.CognitiveServices/accounts/projects', parameters('foundryAccountName'), parameters('projectName'))]"
		}
	}
}
EOF

# Parameter file uses runtime values captured earlier in the script.
cat > "$PARAMS_FILE" <<EOF
{
	"\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
	"contentVersion": "1.0.0.0",
	"parameters": {
		"location": {
			"value": "$LOCATION"
		},
		"foundryAccountName": {
			"value": "$FOUNDRY_ACCOUNT_NAME"
		},
		"projectName": {
			"value": "$PROJECT_NAME"
		},
		"projectDisplayName": {
			"value": "$PROJECT_DISPLAY_NAME"
		},
		"projectDescription": {
			"value": "$PROJECT_DESCRIPTION"
		},
		"agentSubnetId": {
			"value": "$AGENT_SUBNET_ID"
		},
		"publicNetworkAccess": {
			"value": "$PUBLIC_NETWORK_ACCESS"
		}
	}
}
EOF

log "Deploying Foundry account ${FOUNDRY_ACCOUNT_NAME} with VNet injection to ${AGENT_SUBNET_NAME}"
DEPLOYMENT_OUTPUT="$(az deployment group create \
	--resource-group "$RESOURCE_GROUP" \
	--name "$DEPLOYMENT_NAME" \
	--template-file "$TEMPLATE_FILE" \
	--parameters "$PARAMS_FILE" \
	--query properties.outputs \
	--output json)"

log 'Deployment complete'
echo
echo 'Created resources:'
echo "  Resource group     : $RESOURCE_GROUP"
echo "  Virtual network    : $VNET_NAME ($VNET_PREFIX)"
echo "  Agent subnet       : $AGENT_SUBNET_NAME ($AGENT_SUBNET_PREFIX)"
echo "  Agent subnet ID    : $AGENT_SUBNET_ID"
echo "  PE subnet          : $PE_SUBNET_NAME ($PE_SUBNET_PREFIX)"
echo "  PE subnet ID       : $PE_SUBNET_ID"
echo "  Foundry account    : $FOUNDRY_ACCOUNT_NAME"
echo "  Foundry project    : $PROJECT_NAME"
echo
echo 'ARM outputs:'
echo "$DEPLOYMENT_OUTPUT"
echo
echo 'Next steps:'
echo "  1. Create private endpoints for dependent resources into ${PE_SUBNET_NAME}."
echo '  2. If you need a fully private standard agent setup, add private endpoints and DNS for Storage, Search, and Cosmos DB.'
