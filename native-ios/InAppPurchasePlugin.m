#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

// Objective-C bridge for the StoreKit 2 In-App Purchase plugin. Mirrors the
// LiveActivityPlugin bridge: CAP_PLUGIN wires up the identifier / jsName and
// the list of promise-returning methods the JS side can call. The Swift class
// name must also be present in packageClassList (see inject_live_activity.rb)
// or Capacitor 8 will never instantiate the plugin.
CAP_PLUGIN(InAppPurchasePlugin, "InAppPurchase",
    CAP_PLUGIN_METHOD(getProducts, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(purchase, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(restorePurchases, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getEntitlements, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(manageSubscriptions, CAPPluginReturnPromise);
)
