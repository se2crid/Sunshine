/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
 
// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

#include <CoreGraphics/CoreGraphics.h>

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, 
                      const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      BOOST_LOG(info) << "Configuring selected display ("sv << display_id << ") to stream"sv;
      av_capture = [[AVVideo alloc] initWithDisplay:display_id frameRate:config.framerate];
      if (!av_capture) {
        BOOST_LOG(error) << "Video setup failed."sv;
        return capture_e::failure;
      }
      width = av_capture.frameWidth;
      height = av_capture.frameHeight;
      // Set environment dimensions for proper mouse coordinate mapping.
      env_width = width;
      env_height = height;
      return capture_e::success;
    }
  };

  // Updated detection function that includes virtual (online) displays.
  std::shared_ptr<av_display_t> detectDisplay(const std::string &display_name) {
    auto display = std::make_shared<av_display_t>();

    // Default to main display
    display->display_id = CGMainDisplayID();

    // Retrieve display names using AVVideo.
    NSArray *display_array = [AVVideo displayNames];
    // Create a mutable array to merge with online displays.
    NSMutableArray *all_display_array = [NSMutableArray arrayWithArray:display_array];
    BOOST_LOG(info) << "Detecting displays using AVVideo"sv;
    for (NSDictionary *item in display_array) {
      NSNumber *display_id = item[@"id"];
      NSString *name = item[@"displayName"];
      BOOST_LOG(info) << "Detected display: "sv << name.UTF8String 
                      << " (id: "sv << [NSString stringWithFormat:@"%@", display_id].UTF8String 
                      << ") connected: true"sv;
      if (!display_name.empty() && std::atoi(display_name.c_str()) == [display_id unsignedIntValue]) {
        display->display_id = [display_id unsignedIntValue];
      }
    }

    // Additionally, detect online displays (which may include virtual displays)
    uint32_t onlineCount = 0;
    CGError onlineErr = CGGetOnlineDisplayList(0, NULL, &onlineCount);
    if (onlineErr == kCGErrorSuccess && onlineCount > 0) {
      std::vector<CGDirectDisplayID> onlineDisplays(onlineCount);
      onlineErr = CGGetOnlineDisplayList(onlineCount, onlineDisplays.data(), &onlineCount);
      if (onlineErr == kCGErrorSuccess) {
        for (uint32_t i = 0; i < onlineCount; i++) {
          CGDirectDisplayID dispID = onlineDisplays[i];
          BOOL found = NO;
          // Check if this display is already in the list from AVVideo.
          for (NSDictionary *item in display_array) {
            NSNumber *idObj = item[@"id"];
            if ([idObj unsignedIntValue] == dispID) {
              found = YES;
              break;
            }
          }
          if (!found) {
            // Retrieve display name via helper provided by AVVideo.
            NSString *dispName = [AVVideo getDisplayName:dispID];
            BOOST_LOG(info) << "Detected virtual/online display: "sv << dispName.UTF8String
                            << " (id: "sv << dispID << ") connected: unknown"sv;
            [all_display_array addObject:@{@"id": @(dispID), @"displayName": dispName}];
            // Update our selection if the virtual display matches the user-specified display.
            if (!display_name.empty() && std::atoi(display_name.c_str()) == dispID) {
              display->display_id = dispID;
            }
          }
        }
      }
    }

    // Optionally, you can integrate this merged display list elsewhere if needed.
    return display;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> names;
    NSArray *display_array = [AVVideo displayNames];
    [display_array enumerateObjectsUsingBlock:^(NSDictionary * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
      NSString *name = obj[@"name"];
      names.emplace_back(name.UTF8String);
    }];
    return names;
  }

  /**
   * @brief Returns whether GPUs/drivers have changed since the last call.
   * @return `true` if a change occurred or if it is unknown.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state on macOS, so we always reenumerate.
    return true;
  }
}  // namespace platf