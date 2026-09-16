Azure quota verification — setup and secrets

1) Create a service principal with limited scope and store as AZURE_CREDENTIALS.

Run locally (replace <subscriptionId>):

az ad sp create-for-rbac --name "github-actions-quota-check" --role Contributor --scopes /subscriptions/<subscriptionId> --sdk-auth

Copy the returned JSON and add it as a GitHub repository secret named AZURE_CREDENTIALS (Repository Settings -> Secrets -> Actions).

2) Configure quotas to check

Copy quota-config.sample.json to quota-config.json and add the provider quota
resources consumed by the deployment. Discover names with `az quota list`;
resource counts are not quota availability.

3) Behavior

- The workflow runs on pull_request and can be run manually.
- The script performs a strict regional vCPU check (uses az vm list-usage). Other checks count existing resources in-location and warn if counts are fewer than requested.
- For stricter or provider-derived quota checks (e.g., App Service Plan quotas or Azure Quota API), extend scripts to call the Microsoft Quota REST APIs via az rest.

4) Notes

- Ensure the service principal has permission to list resources and call usage APIs.
- The workflow installs Azure CLI on ubuntu-latest; the azure/login action performs authentication using AZURE_CREDENTIALS.
