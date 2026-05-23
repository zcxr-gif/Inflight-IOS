#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(InflightMapkitPlugin, "InflightMapkit",
    CAP_PLUGIN_METHOD(create, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(destroy, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setFrame, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setCamera, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(fitBounds, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setMapType, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setMarkers, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setPolylines, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setPolygons, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setVisible, CAPPluginReturnPromise);
)
