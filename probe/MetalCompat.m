#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>

static BOOL depth24Unsupported(id self, SEL selector) {
    // Metal's Depth24Unorm_Stencil8 format is macOS-only. Let the original
    // renderer select its existing Depth32Float_Stencil8 fallback on iPadOS.
    return NO;
}

void PrepareMetalCompatibility(id<MTLDevice> device) {
    SEL query=sel_registerName("isDepth24Stencil8PixelFormatSupported");
    if (device && ![device respondsToSelector:query]) {
        class_addMethod(object_getClass(device),query,(IMP)depth24Unsupported,"B@:");
    }
    fprintf(stderr,"FACTORIO_PROBE: BC texture compression supported=%d\n",
            [device supportsBCTextureCompression]);
}
