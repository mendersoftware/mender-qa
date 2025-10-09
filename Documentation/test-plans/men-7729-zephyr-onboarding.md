# MEN-7729 Zephyr onboarding

## Summary

This test plan covers the implementation of the Zephyr onboarding functionality.

This project introduces a new "Micro" and "Standard" device tiers. Micro for microcontrollers and a "Standard" tier for anything else.
The Micro tier aims to optimize for devices with lower software complexity and smaller artifact sizes.
The Standard tier will be the default tier and used for all devices without any other tier specified.

This project also enables new users to get started with the Zephyr platform through a guided setup process.

## Related

- [MEN-7729 Zephyr onboarding (Epic)](https://northerntech.atlassian.net/browse/MEN-7729)
- [User experience for Zephyr (Docs)](https://docs.google.com/document/d/1-3BtSTl5kr4lT9Rcah-G4cRQhgusr0VmRIYmWVE3Ygg)
- [Pricing model for MCUs (Docs)](https://docs.google.com/document/d/1R8gUejuQecvYKuJlq0LEVzHFdMC3MSbOTHXZXaWD3Bo)
- [UX/UI (Figma)](https://www.figma.com/design/ZTGKMcKtHrZ0V7pfdws7KM/Zephyr-onboarding-UX-concept)
- [Zephyr signup epic (Slides)](https://docs.google.com/presentation/d/1pIGPEDrZYKk4PSdsvhtcL8XAeuTybBHKcGhi19V8zXE)
- API documentation TBA
- Onboarding (Docs) TBA

## Features breakdown

### Device tiers

- Two device tiers: "Micro" and "Standard"
    - Orthogonal to the current plan types (Trial, Basic, Professional, Enterprise)
    - All tenants will be able to have device limits for both tiers
- Commercial plans (Basic, Professional, Enterprise) with Micro tier devices will, by default, have a maximum 5 MB Artifact size for deployment
- Device tier will be configured on the device side and included as part of the authentication set
- If an existing, accepted, device changes tier, it needs to be authenticated again
- During plan purchase, users can select the number of devices to purchase for each tier
    - Buying a paid plan with 0 "Standard" tier devices should be prevented, because the user might have "Standard" devices existing from their Free trial
- Device tier limit will be synchronized with HubSpot

### Onboarding process

- Users can choose an MCU with Zephyr among the devices options
- Users can choose between US and EU hosting regions
- Guided process for initial device setup
- Connecting a new device dialog now features MCU devices
    - For MCUs, the reference device will be Espressif ESP32-S3
    - MCUs will not be able to run the demo artifact, onboarding for this type
    clearly informs the user about this
- New "Microcontroller Get started" tutorial link

### UX

- A new device type (Zephyr/MCU) is available for onboarding
- The UI will provide a configuration snippet for building MCU images
    - the token includes the device tier and tenant token
- A warning will be displayed in the UI if an artifact is too large for the "Micro" tier during deployment
    - Only applies to cases where we know the device type in advance, ie. not for dynamic deployments where device type might not be known before the deployment is actually attempted

### Server API

__Management:__
- Will get available tiers, their names, IDs, and current device limits
- New endpoint to set device limits for a given tier (forwards requests to Stripe)
- New endpoint to predict the payment amount for given device limits in tiers

__Device Auth:__
- Enforcing tier limits for new devices
- A new `tier` attribute will be added to the device identity
    - The tier is incorporated into the JWT issued for a device

__Deployments:__
- On call to `/deployments` the device's tier is verified
- The tier also determines the allowed artifact size for the device
    - Based on this, the device is allowed to update or not

__Internal:__
- New endpoint to set artifact size limits per tier for a given tenant
- New endpoint to set and get update and inventory rate limits for the "Micro" tier

### Service Provider Tenant

- Set global device limits for child tenants per tier

## Out of scope

- Bulk device onboarding for enterprise users
- C++ client,  MCU client

## Entry criteria

- Device management functionality for Micro tier is available
- API endpoints for onboarding the new tier are implemented
- Micro tier device images are prepared

## Exit criteria

- All test cases pass
- Manual user acceptance testing completed successfully
    - newly found issues sufficiently addressed (blocker and high priority resolved)
- Potential security issues addressed (TODO: coordinate with security officer)
- New documentation updated/reviewed
- Micro tier device can successfully be updated once per day without causing errors
in inventory (rate limiting)

## Risk

- Changes to the device identity and authentication must not break existing devices
- E2E testing involves a 3rd party in Stripe and HubSpot
- Flaky integration with Stripe could lead to billing errors for customers
- The introduction of "Micro" and "Standard" tiers might confuse users, especially during the purchasing process
- Tier imposed limits might prevent a legitimate update

## Test environment

### Infrastructure

- Staging environment with the latest components deployed
- Test instances for Stripe and HubSpot (TODO: unsure about HubSpot, or if strictly needed at all)

### Test Data

- Virtual Device for OS updates with "Micro" tier set
- Sample runtime configuration to set "Micro" tier
- Test tenants with different plans and device tier configurations
- Artifacts of varying sizes, including some that exceed the default "Micro" tier limit of 5MB

## Verification criteria

### Server

- Server correctly identifies the device tier
- Device authentication enforces the device limits for each tier accordingly
    - For SP Tenant, the device limit is reflected in it's child tenants
- The management API correctly reflects tier information, limits, and pricing from Stripe
- Internal APIs for setting artifact size and rate limits work
- The deployments service correctly enforces default artifact size limits of 5MB for "Micro" tier devices
    - The deployments service enforces custom artifact size limits set on the tenant level
    - Updates that failed due to the limits, should be clearly reported
- Rate limiting for updates  (1 / day) and inventory (1 / 14 days) is correctly enforced for "Micro" tier devices
    - Device updates that automatically trigger inventory updates should not consume the allocated inventory update quota
- Logging does not capture onboarding of new devices
- Server shall never sent the Client an artifact exceeding the size limits
    - Device for which the update exceeds the limit, will be flagged in the UI
    - Note: For Trial tier ther is no strict limit on the Artifact size

### Client

- The client correctly sends its `tier` as part of its authentication request
    - If authenticated, the resulting JWT claim contains also the specified device tier
- The `mender-artifact` gets the new command-line arguments: `--fail-on-payload-size-greater:5MB` and `--warn-on-payload-size-greater:5MB`
- Tier is correctly configured during the build process for both Yocto and Zephyr
    - We provide guidance/layers to build Micro tier images
    - Yocto and Zephyr build process propagate the Artifact limit to mender-artifact tool,
    by default issuing a warning if an Artifact exceeds 5MB

### Installation / Migrations

- N/A

### UI

- Visual design matches approved mockups
- The UI shows the correct configuration snippet for the selected device type
- Onboarding flow correctly presents Zephyr/MCU among available device options
- Warnings for oversized artifacts are displayed
- Indicators for rate limiting are displayed (TODO: unsure, but this is probably an error from the backend?)
- Some addons (Monitor) are not availble under certain pricing plans (Basic)

### SRE

- Logging provides sufficient detail to debug issues related to device tiers and limits

### Documentation

- The "Get started" guides now consider the different device tiers
- New concepts like tiers, limits, and build configurations are explained

## Testing notes

- User with accepted "Standard" devices in their trial cannot purchase a Micro-only plan
    - Have active "Standard" devices -> Attempt to buy a Micro plan -> Verify the action is blocked
    - Have active "Standard" devices -> Decommission them -> Attempt to buy a Micro plan -> Purchase now succeeds
    - Must first decommission such devices or add "Standard" devices to a plan to prevent loss of access to existing devices if they purchase only a Micro device limit
- Differences in limits between the free trial and paid plans
    - Free trial has no artifact size limit or strict polling interval limits
    - Commercial Micro plans, however, have default limits (e.g., 5 MB artifact size, daily update polls)
- Ensure that all existing devices (and any new clients that don't specify a tier) are automatically and correctly categorized as Standard tier
- Device tier is defined during the client build process
- Built images/devices should be sending their `tier` as part of their authentication request
- Verify `mender-artifact` new command line arguments for payload size
- Ensure the API correctly interacts with Stripe for billing
- Verify deploying a Micro device fails when the payload size exceeds the limit

## Glossary

- Tier: A category of device with specific limits and pricing
    - Micro Tier: A new, lower-cost tier designed for microcontrollers with limitations on artifact size and update frequency
    - Standard Tier: The existing tier for Linux-based devices, which is the default for all legacy devices
- Device Limit: The maximum number of devices of a specific tier that a tenant can have
- Artifact Size Limit: The maximum size of an artifact that can be deployed to a device of a specific tier. For the "Micro" tier, this is 5MB by default
- Polling Interval: The frequency at which a device checks for updates or sends inventory data. The "Micro" tier will have stricter limits on this
