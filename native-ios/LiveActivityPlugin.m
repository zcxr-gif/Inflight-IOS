#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(LiveActivityPlugin, "LiveActivity",
    CAP_PLUGIN_METHOD(areActivitiesEnabled, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(start, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(update, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(end, CAPPluginReturnPromise);
)
