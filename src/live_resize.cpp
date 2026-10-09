/**
 * @file src/live_resize.cpp
 * @brief Virtual display change of the live resize extension (Windows).
 */
#include "live_resize.h"

#ifdef _WIN32

  #include <cstring>
  #include <mutex>

  #include "config.h"
  #include "display_device.h"
  #include "logging.h"
  #include "platform/windows/misc.h"
  #include "platform/windows/virtual_display.h"
  #include "process.h"
  #include "uuid.h"

using namespace std::literals;

namespace live_resize {

  // Reads the current mode of a display. Returns false when the display is not found.
  static bool read_mode(const std::wstring &name, int &width, int &height) {
    DEVMODEW mode = {};
    mode.dmSize = sizeof(mode);
    // getDeviceSettings() returns the BOOL of EnumDisplaySettingsW(): not zero on success
    if (!VDISPLAY::getDeviceSettings(name.c_str(), mode)) {
      return false;
    }
    width = (int) mode.dmPelsWidth;
    height = (int) mode.dmPelsHeight;
    return true;
  }

  // Adds the monitor with this GUID at the size and applies the mode, as proc_t::execute() does.
  // Returns the device name, or an empty string when the driver gave no name in time.
  static std::wstring add_and_apply(const proc::proc_t::vdd_t &vdd, const GUID &guid, int width, int height) {
    auto name = VDISPLAY::createVirtualDisplay(vdd.device_uuid.c_str(), vdd.device_name.c_str(), width, height, vdd.target_fps, guid);
    if (name.empty()) {
      return name;
    }

    // Spike S1b: after a re-add Windows first shows the saved mode; this call applies the new one
    VDISPLAY::changeDisplaySettings(name.c_str(), width, height, vdd.target_fps);
    if (config::video.isolated_virtual_display_option) {
      VDISPLAY::changeDisplaySettings2(name.c_str(), width, height, vdd.target_fps, true);
    }
    return name;
  }

  static bool is_at_size(const std::wstring &name, int width, int height, int &current_width, int &current_height) {
    current_width = 0;
    current_height = 0;
    return !name.empty() && read_mode(name, current_width, current_height) && current_width == width && current_height == height;
  }

  display_result_t change_display_size(int width, int height) {
    auto &app = proc::proc;
    std::lock_guard lg(proc::vdd_lock);

    // Do not call app.running() here: it can call terminate(), which locks proc::vdd_lock.
    // terminate() clears vdd under the lock, thus vdd.valid is false after the app stops.
    if (!app.vdd.valid || !app.virtual_display) {
      return {false, "no app with a virtual display runs"};
    }

    // A failed remove is not fatal: the add below returns the existing monitor for a known GUID
    if (!VDISPLAY::removeVirtualDisplay(app.vdd.guid)) {
      BOOST_LOG(warning) << "Live resize: could not remove the virtual display before the re-add"sv;
    }

    int current_width, current_height;
    auto name = add_and_apply(app.vdd, app.vdd.guid, width, height);
    bool at_size = is_at_size(name, width, height, current_width, current_height);

    if (!at_size) {
      // Spike S1: Windows kept the mode it saved for this monitor identity. Use a new identity.
      BOOST_LOG(warning) << "Live resize: display ["sv << platf::to_utf8(name) << "] is at "sv
                         << current_width << 'x' << current_height << ", adding it again with a new GUID"sv;
      // Always remove the old GUID. The add can succeed when the name poll times out.
      // When no monitor has this GUID, the remove only returns false.
      VDISPLAY::removeVirtualDisplay(app.vdd.guid);

      auto new_uuid = uuid_util::uuid_t::generate();
      GUID new_guid;
      static_assert(sizeof(new_guid) == sizeof(new_uuid), "GUID and uuid_t have the same size");
      std::memcpy(&new_guid, &new_uuid, sizeof(new_guid));
      // Record the new GUID before the add, so that terminate() removes the monitor
      // also when the add gives no name in time
      app.set_vdd_guid(new_guid);

      name = add_and_apply(app.vdd, new_guid, width, height);
      at_size = is_at_size(name, width, height, current_width, current_height);
    }

    if (!at_size) {
      return {false, "display is at " + std::to_string(current_width) + "x" + std::to_string(current_height) + " instead of " + std::to_string(width) + "x" + std::to_string(height)};
    }

    // The capture thread finds the display by this name at its next reinit
    app.display_name = platf::to_utf8(name);
    config::video.output_name = display_device::map_display_name(app.display_name);
    app.set_vdd_size(width, height);

    BOOST_LOG(info) << "Live resize: display ["sv << app.display_name << "] is now "sv << width << 'x' << height;
    return {true, {}};
  }

}  // namespace live_resize

#endif
