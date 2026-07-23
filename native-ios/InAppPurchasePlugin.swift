import Foundation
import Capacitor
import StoreKit
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// InAppPurchasePlugin — StoreKit 2 auto-renewable subscription bridge.
//
// Exposes the minimum surface the JS layer (www/iapService.js) needs to sell
// and restore "InFlight Pro" through Apple In-App Purchase (App Store Guideline
// 3.1.1). Entitlement is verified on-device via StoreKit 2's cryptographically
// signed `Transaction` values, so the app can gate Pro correctly even before
// the server-side Supabase sync runs.
//
// Methods (all return Promises to JS):
//   getProducts({ productIds:[String] }) -> { products:[{ id, displayName,
//       description, price, displayPrice, currencyCode }] }
//   purchase({ productId }) -> { status:"purchased"|"pending"|"cancelled",
//       transactionId?, originalTransactionId?, jws?, productId?, expiresAt? }
//   restorePurchases() -> { active:Bool, entitlements:[…], … }
//   getEntitlements() -> { active:Bool, entitlements:[…] }  (no AppStore.sync)
//   manageSubscriptions() -> { opened:Bool }
//
// StoreKit 2 requires iOS 15+. On older systems every method rejects with
// "unavailable" and the JS layer treats Pro as simply not purchasable in-app.
// ─────────────────────────────────────────────────────────────────────────────
@objc(InAppPurchasePlugin)
public class InAppPurchasePlugin: CAPPlugin {

    private var updatesTask: Task<Void, Never>?

    public override func load() {
        super.load()
        // Listen for transactions that arrive outside an explicit purchase call
        // (Ask-to-Buy approvals, renewals, purchases made on another device) and
        // finish them so StoreKit stops re-delivering them. We also nudge the JS
        // layer to re-check entitlements via a plugin event.
        if #available(iOS 15.0, *) {
            updatesTask = Task.detached { [weak self] in
                for await update in Transaction.updates {
                    guard let self = self else { continue }
                    if case .verified(let transaction) = update {
                        await transaction.finish()
                        self.notifyListeners("entitlementsChanged", data: [
                            "productId": transaction.productID
                        ])
                    }
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Products

    @objc func getProducts(_ call: CAPPluginCall) {
        guard #available(iOS 15.0, *) else {
            call.reject("StoreKit 2 requires iOS 15 or later.", "unavailable")
            return
        }
        let ids = call.getArray("productIds", String.self) ?? []
        guard !ids.isEmpty else {
            call.reject("productIds is required.")
            return
        }
        Task {
            do {
                let products = try await Product.products(for: ids)
                let payload = products.map { self.serializeProduct($0) }
                call.resolve(["products": payload])
            } catch {
                call.reject("Failed to load products: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Purchase

    @objc func purchase(_ call: CAPPluginCall) {
        guard #available(iOS 15.0, *) else {
            call.reject("StoreKit 2 requires iOS 15 or later.", "unavailable")
            return
        }
        guard let productId = call.getString("productId") else {
            call.reject("productId is required.")
            return
        }
        Task {
            do {
                let products = try await Product.products(for: [productId])
                guard let product = products.first else {
                    call.reject("Product not found: \(productId). Check the product ID and that it is Ready to Submit in App Store Connect.")
                    return
                }

                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        await transaction.finish()
                        call.resolve(self.serializeTransaction(transaction, jws: verification.jwsRepresentation, status: "purchased"))
                    case .unverified(_, let error):
                        call.reject("Purchase could not be verified: \(error.localizedDescription)", "unverified")
                    }
                case .pending:
                    // Ask-to-Buy / SCA — resolves later via Transaction.updates.
                    call.resolve(["status": "pending"])
                case .userCancelled:
                    call.resolve(["status": "cancelled"])
                @unknown default:
                    call.reject("Unknown purchase result.")
                }
            } catch {
                call.reject("Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Restore

    @objc func restorePurchases(_ call: CAPPluginCall) {
        guard #available(iOS 15.0, *) else {
            call.reject("StoreKit 2 requires iOS 15 or later.", "unavailable")
            return
        }
        Task {
            do {
                // Prompts for the App Store account and refreshes entitlements.
                try? await AppStore.sync()
                let payload = await self.currentEntitlementsPayload()
                call.resolve(payload)
            } catch {
                call.reject("Restore failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Entitlements (no sync prompt)

    @objc func getEntitlements(_ call: CAPPluginCall) {
        guard #available(iOS 15.0, *) else {
            call.reject("StoreKit 2 requires iOS 15 or later.", "unavailable")
            return
        }
        Task {
            let payload = await self.currentEntitlementsPayload()
            call.resolve(payload)
        }
    }

    // MARK: - Manage subscriptions

    @objc func manageSubscriptions(_ call: CAPPluginCall) {
        guard #available(iOS 15.0, *) else {
            call.reject("StoreKit 2 requires iOS 15 or later.", "unavailable")
            return
        }
        Task { @MainActor in
            #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
                call.reject("No active window scene to present the manage-subscriptions sheet.")
                return
            }
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                call.resolve(["opened": true])
            } catch {
                call.reject("Could not open manage subscriptions: \(error.localizedDescription)")
            }
            #else
            call.reject("Unavailable on this platform.", "unavailable")
            #endif
        }
    }

    // MARK: - Helpers

    @available(iOS 15.0, *)
    private func currentEntitlementsPayload() async -> [String: Any] {
        var entitlements: [[String: Any]] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                // Only surface active (non-revoked, non-expired) entitlements.
                if transaction.revocationDate != nil { continue }
                if let exp = transaction.expirationDate, exp < Date() { continue }
                entitlements.append(self.serializeTransaction(transaction, jws: result.jwsRepresentation, status: "active"))
            }
        }
        return ["active": !entitlements.isEmpty, "entitlements": entitlements]
    }

    @available(iOS 15.0, *)
    private func serializeProduct(_ product: Product) -> [String: Any] {
        var dict: [String: Any] = [
            "id": product.id,
            "displayName": product.displayName,
            "description": product.description,
            "price": NSDecimalNumber(decimal: product.price).doubleValue,
            "displayPrice": product.displayPrice,
        ]
        if #available(iOS 16.0, *) {
            dict["currencyCode"] = product.priceFormatStyle.currencyCode
        }
        if let sub = product.subscription {
            dict["subscriptionPeriod"] = "\(sub.subscriptionPeriod.value) \(String(describing: sub.subscriptionPeriod.unit))"
        }
        return dict
    }

    @available(iOS 15.0, *)
    private func serializeTransaction(_ transaction: Transaction, jws: String, status: String) -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "productId": transaction.productID,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID),
            "jws": jws,
        ]
        if let exp = transaction.expirationDate {
            dict["expiresAt"] = ISO8601DateFormatter().string(from: exp)
        }
        return dict
    }
}
