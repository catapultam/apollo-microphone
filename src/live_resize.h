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
   * @return ok == false when no app with a virtual display runs or the display did not
   * reach the size. The caller reverts with the old size.
   */
  display_result_t change_display_size(int width, int height);
#endif

}  // namespace live_resize
