#import <React/RCTViewManager.h>

// Registers the Swift view manager, its props, and the configure method with the RN bridge.
@interface RCT_EXTERN_MODULE(MeldWidgetManager, RCTViewManager)

RCT_EXPORT_VIEW_PROPERTY(order, NSDictionary)
RCT_EXPORT_VIEW_PROPERTY(onReady, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPaymentSubmitted, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onStatusChange, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onCancel, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onError, RCTDirectEventBlock)

RCT_EXTERN_METHOD(configure:(NSString *)environment)
RCT_EXTERN_METHOD(capabilities:(NSDictionary *)order
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
