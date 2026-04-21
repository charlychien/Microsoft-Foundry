# injection-byon.sh

This folder contains a Bash script that provisions a basic Azure AI Foundry environment with VNet integration.

## What it does

The script creates or updates these resources in a target resource group:

1. A virtual network.
2. An `agent-snet` subnet delegated to `Microsoft.App/environments`.
3. A `pe-subnet` subnet reserved for private endpoints.
4. An Azure AI Foundry account backed by `Microsoft.CognitiveServices/accounts` with `kind: AIServices`.
5. A Foundry project under that account.

The Foundry account is configured to use `networkInjections` against the delegated agent subnet.

## Current deployment model

The script uses two deployment styles:

1. Azure CLI commands for the resource group, VNet, and subnets.
2. An ARM deployment for the Foundry account and project.

Because of this split model, the script does not support a full `what-if` preview for every resource.

## Prerequisites

Before running the script, make sure you have:

1. Bash available on your machine.
   On this workstation the script was tested with Git Bash.
2. Azure CLI installed.
3. An active Azure login.
   Run `az login` first.
4. Enough permission to create:
   - Resource groups
   - Virtual networks and subnets
   - Cognitive Services accounts and child resources
5. Register Resource Providers on the Subscription.
   - az provider register --namespace 'Microsoft.KeyVault'
   - az provider register --namespace 'Microsoft.CognitiveServices'
   - az provider register --namespace 'Microsoft.Storage'
   - az provider register --namespace 'Microsoft.Search'
   - az provider register --namespace 'Microsoft.Network'
   - az provider register --namespace 'Microsoft.App'
   - az provider register --namespace 'Microsoft.ContainerService'

## Default behavior

The script includes default values in the file for:

1. Resource group name
2. Azure region
3. Subscription ID
4. Foundry account name
5. Foundry project name
6. VNet name and CIDR ranges

These defaults can be overridden with command-line arguments.

## Parameters

### Required parameters

The script supports these required inputs when you want to override defaults:

1. `--resource-group <name>`
2. `--location <azure-region>`
3. `--foundry-account <name>`

### Optional parameters

1. `--project-name <name>`
2. `--project-display <name>`
3. `--project-description <text>`
4. `--subscription <id>`
5. `--vnet-name <name>`
6. `--vnet-prefix <cidr>`
7. `--agent-subnet-name <name>`
8. `--agent-subnet-prefix <cidr>`
9. `--pe-subnet-name <name>`
10. `--pe-subnet-prefix <cidr>`
11. `--public-network-access <Enabled|Disabled>`
12. `--help`

## Example usage

Run with the defaults currently defined in the script:

```bash
./injection-byon.sh
```

Run with explicit values:

```bash
./injection-byon.sh \
  --resource-group rg-foundry-demo \
  --location japaneast \
  --subscription 00000000-0000-0000-0000-000000000000 \
  --foundry-account foundrydemoaccount \
  --project-name foundry-demo-project \
  --project-display "demo project for foundry network integration" \
  --vnet-name foundry-vnet \
  --vnet-prefix 10.89.0.0/16 \
  --agent-subnet-name agent-snet \
  --agent-subnet-prefix 10.89.0.0/24 \
  --pe-subnet-name pe-subnet \
  --pe-subnet-prefix 10.89.1.0/24 \
  --public-network-access Disabled
```

Show help:

```bash
./injection-byon.sh --help
```

## Resources created

After a successful run, you should expect these resource types:

1. `Microsoft.Network/virtualNetworks`
2. `Microsoft.CognitiveServices/accounts`
3. `Microsoft.CognitiveServices/accounts/projects`

The two subnets are created under the virtual network:

1. `agent-snet`
   Delegated to `Microsoft.App/environments`
2. `pe-subnet`
   Intended for future private endpoint resources

## Important notes

1. `pe-subnet` is only prepared for private endpoints.
   The script does not create private endpoints for Storage, Search, Cosmos DB, or other dependencies.
2. The Foundry account is created with public network access set from the script parameter or default.
3. The script generates temporary ARM template and parameter files at runtime and removes them on exit.
4. The script was tested successfully in Bash and created:
   - Virtual network
   - Foundry account
   - Foundry project

## Validation commands

List resources in the resource group:

```bash
az resource list --resource-group <resource-group> -o table
```

Check Foundry account status:

```bash
az cognitiveservices account show \
  --resource-group <resource-group> \
  --name <foundry-account-name> \
  --query "{name:name,location:location,provisioningState:properties.provisioningState,publicNetworkAccess:properties.publicNetworkAccess,endpoint:properties.endpoint}" \
  -o table
```

Check VNet and subnet settings:

```bash
az network vnet show \
  --resource-group <resource-group> \
  --name <vnet-name> \
  --query "{name:name,addressPrefixes:addressSpace.addressPrefixes,subnets:subnets[].{name:name,prefix:addressPrefix,delegations:delegations[].serviceName}}"
```

## Future enhancements

If this script needs to be extended, likely next steps are:

1. Add private endpoints into `pe-subnet`.
2. Add private DNS zone integration.
3. Add model deployment resources.
4. Refactor all resources into ARM or Bicep if full `what-if` support becomes necessary.
