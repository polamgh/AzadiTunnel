# App Store Connect — In-App Purchase Setup

App Store Connect API credentials were **not** found in this repository. Configure products manually in [App Store Connect](https://appstoreconnect.apple.com).

## Prerequisites

1. App record exists with bundle ID `com.polamgh.ali.AzadiTunnel`.
2. **In-App Purchase** capability enabled for the App ID in Apple Developer → Identifiers.
3. Paid Applications agreement and banking/tax forms completed (required for IAP).
4. Subscription group created (for monthly/yearly supporter products).

## Suggested price tiers (CAD)

Use Apple’s nearest price point when the exact amount is unavailable.

| Product ID | Type | Suggested price (CAD) | Display name (suggested) |
|---|---|---|---|
| `azaditunnel.tip.small` | Consumable | $2.99 | Small tip |
| `azaditunnel.tip.medium` | Consumable | $5.99 | Medium tip |
| `azaditunnel.tip.large` | Consumable | $9.99 | Large tip |
| `azaditunnel.support.monthly` | Auto-renewable subscription | $4.99/month | Monthly supporter |
| `azaditunnel.support.yearly` | Auto-renewable subscription | $49.99/year | Yearly supporter |

## Step-by-step (manual)

### Consumable tips (×3)

1. App Store Connect → **My Apps** → AzadiTunnel → **In-App Purchases** → **+**.
2. Type: **Consumable**.
3. Reference name: e.g. `Small tip`; Product ID: `azaditunnel.tip.small` (must match code exactly).
4. Set **Price Schedule** → base country Canada → select tier nearest **CAD $1.99**.
5. Add localization (English at minimum): display name and description stating VPN stays free.
6. Repeat for `azaditunnel.tip.medium` ($4.99) and `azaditunnel.tip.large` ($9.99).
7. Submit each product for review with the app version.

### Subscription group

1. **Subscriptions** → **+** → create group e.g. `Support`.
2. Add subscription `azaditunnel.support.monthly`:
   - Duration: 1 month
   - Price: nearest **CAD $2.99**
   - Localization + optional subscription privacy policy URL (can link to in-app privacy / support site)
3. Add subscription `azaditunnel.support.yearly`:
   - Duration: 1 year
   - Price: nearest **CAD $24.99**
4. Set subscription level/order if needed (yearly typically higher level).
5. Add **Review Information** screenshot of Support screen showing products and disclaimer.

### Sandbox testing

1. App Store Connect → **Users and Access** → **Sandbox** → create sandbox tester.
2. On device: Settings → App Store → Sandbox Account → sign in with sandbox Apple ID.
3. Install TestFlight or development build; open **Support AzadiTunnel** and purchase (no real charge).

### TestFlight / production

- Products must be **Ready to Submit** and attached to the app version being reviewed.
- First IAP submission requires app binary review together with products.

## Local development (no App Store Connect)

- Use `Configuration.storekit` at repository root (referenced by Xcode scheme).
- Run `Scripts/storekit-local-products-test.sh` to verify StoreKit loads 5 products in Simulator with local configuration.
- Sample prices in `.storekit` are for **local testing only**; the app UI always uses StoreKit `displayPrice`.

## What code already does

- Loads products via StoreKit 2 `Product.products(for:)`.
- Shows localized `displayName` and `displayPrice` from StoreKit.
- Empty state: “Support purchases are not available in this build.”
- Restore via `AppStore.sync()`.
- VPN connect is never blocked when products fail to load.
