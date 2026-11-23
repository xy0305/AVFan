//
//  AVFan-Bridging-Header.h
//  AVFan
//
//  Build 59 full restoration, stage D: exposes the MPlayNative-style
//  spatial audio ABI (MPlaySpatialBridge.h, which in turn includes
//  the vendored LibTrueHD / LibDTSX headers) to Swift.  This is the
//  app's only bridging surface; everything else in the target is
//  pure Swift / clang modules.  The import path is relative to
//  this file so it resolves without relying on the headermap.
//

#import "Services/MPlayKit/Spatial/MPlaySpatialBridge.h"
