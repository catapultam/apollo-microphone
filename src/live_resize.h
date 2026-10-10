/**
 * @file src/live_resize.h
 * @brief Wire format, size rules and display change of the live resize extension.
 * @details A Moonlight client asks for a new stream size with RESIZE_REQUEST on the
 * control stream. The host changes the virtual display and the encoder size. The host
 * answers only with RESIZE_REFUSED. See docs/superpowers/specs/2026-10-09-live-resize-design.md
 * in the moonlight-qt-mic repository.
 */
#pragma once

#include <chrono>
#include <cstdint>
#include <string>

namespace live_resize {

  // Control message ids (Apollo live resize extension)
  constexpr std::uint16_t PACKET_TYPE_REQUEST = 0x3100;
  constexpr std::uint16_t PACKET_TYPE_REFUSED = 0x3101;

  // The host clears a request that did not finish after this time
  constexpr auto HOST_TIMEOUT = std::chrono::seconds(15);

  enum class reason_e : std::uint16_t {
    ok = 0,  ///< Not sent on the wire
    busy = 1,  ///< A resize is in progress
    not_virtual_display = 2,  ///< The capture display is not a SudoVDA monitor
    multiple_clients = 3,  ///< Another session shares the display
    size_limit = 4,  ///< The size is odd, too small, too large, or the session is input only
    display_failed = 5,  ///< The display change failed and was reverted
    encoder_failed = 6,  ///< The encoder rejected the size and the old size was restored
    // 7 (not supported) is used by the client only
  };

  // Payloads are little endian on the wire. Use util::endian::little() to read and write them.
#pragma pack(push, 1)
  struct request_payload_t {
    std::uint16_t width;
    std::uint16_t height;
    std::uint32_t request_id;
  };

  struct refused_payload_t {
    std::uint16_t width;
    std::uint16_t height;
    std::uint32_t request_id;
    std::uint16_t reason;
  };
#pragma pack(pop)

  static_assert(sizeof(request_payload_t) == 8, "RESIZE_REQUEST payload is 8 bytes");
  static_assert(sizeof(refused_payload_t) == 10, "RESIZE_REFUSED payload is 10 bytes");

  constexpr int MIN_WIDTH = 320;
  constexpr int MIN_HEIGHT = 200;
  constexpr int MAX_DIMENSION = 8192;
  constexpr int MAX_DIMENSION_H264 = 4096;

  /**
   * @brief Check a requested size against the stream limits.
   * @param width Requested width.
   * @param height Requested height.
   * @param video_format 0 - H.264, 1 - HEVC, 2 - AV1 (video::config_t::videoFormat).
   * @param input_only True when the session streams no video.
   * @return reason_e::ok when the size is valid, otherwise reason_e::size_limit.
   */
  constexpr reason_e validate_size(int width, int height, int video_format, bool input_only) {
    if (input_only) {
      return reason_e::size_limit;
    }
    if ((width & 1) != 0 || (height & 1) != 0) {
      return reason_e::size_limit;
    }
    if (width < MIN_WIDTH || height < MIN_HEIGHT) {
      return reason_e::size_limit;
    }
    const int max_dimension = video_format == 0 ? MAX_DIMENSION_H264 : MAX_DIMENSION;
    if (width > max_dimension || height > max_dimension) {
      return reason_e::size_limit;
    }
    return reason_e::ok;
  }

#ifdef _WIN32
  /**
   * @brief Result of a display change.
   */
  struct display_result_t {
    bool ok;
    bool changed;  ///< False when the function changed nothing. Do not revert then.
    std::string message;  ///< Reason of the failure, empty on success
  };

  /**
   * @brief Set the virtual display of the running app to a new size.
   * @details Removes the SudoVDA monitor, adds it again with the new preferred mode and
   * applies the mode. When Windows keeps the saved mode, adds the monitor again with a
   * new GUID. Holds proc::vdd_lock for the whole change. Updates proc::proc.display_name,
   * config::video.output_name and the launch session size on success.
   * @param width New width.
   * @param height New height.
   * @param generation The value of proc::vdd_generation at the request. The function
   * changes the display only while proc::vdd_generation has this value, thus not the
   * display of another app. It stops after the current step when terminate() starts.
   * @return ok == false when no app with this virtual display runs, when terminate()
   * started, or when the display did not reach the size.
   * @details Fields after each result:
   * - ok == true: proc::proc.display_name and config::video.output_name name the new
   *   monitor. The launch session size is the new size. proc::proc.vdd.guid is the GUID
   *   of the monitor. changed == true.
   * - ok == false, changed == false: no app with this virtual display runs. No field
   *   changed. Do not revert.
   * - ok == false, changed == true: the old monitor is removed. proc::proc.display_name and
   *   config::video.output_name still name the old monitor, which can be missing now.
   *   The capture thread cannot find a display until a change succeeds. The launch
   *   session size is the old size. proc::proc.vdd.guid is the GUID of the monitor that
   *   the last add used (it can be a new GUID), so terminate() removes that monitor.
   *   The caller must call change_display_size() again with the old size. When that call
   *   also fails with changed == true, the session has no display and the caller must
   *   stop the stream.
   * @note Holds proc::vdd_lock during up to two removes, two adds and four mode changes.
   * Each add can poll for the display name for about 1.26 s (sleeps of 20 to 640 ms), thus
   * up to about 2.5 s for two adds. After each add there are one or two mode changes (two
   * when config::video.isolated_virtual_display_option is set), thus up to four. The mode
   * changes have no time limit. proc_t::terminate() sets proc::vdd_generation to 0 before
   * it waits for the lock. This function checks the value after each add and each mode
   * change, and then stops. No check follows a remove: each remove comes before an add with
   * no check between them. Thus terminate() waits for at most one remove and one add (about
   * 1.26 s of name polling), or for one mode change.
   * A mode change that does not return still blocks terminate(). stream::session::join()
   * can call terminate() inside its 10 s hang check, which then ends Apollo.
   */
  display_result_t change_display_size(int width, int height, std::uint32_t generation);
#endif

}  // namespace live_resize
