/**
 * @file src/adaptive_bitrate.h
 * @brief Wire format, bitrate chain and request state of the adaptive bitrate extension.
 * @details A Moonlight client asks for a new video bitrate with SET_BITRATE on the control
 * stream. The host changes the bitrate of the running encoder and answers each request with
 * BITRATE_STATUS. See docs/superpowers/specs/2026-10-10-adaptive-bitrate-design.md in the
 * moonlight-qt-mic repository. This header has no other Sunshine dependency, thus
 * tests/unit/test_adaptive_bitrate.cpp builds it alone.
 */
#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace adaptive_bitrate {

  // Control message ids (Apollo adaptive bitrate extension)
  constexpr std::uint16_t PACKET_TYPE_SET = 0x3102;
  constexpr std::uint16_t PACKET_TYPE_STATUS = 0x3103;

  // Payload sizes on the wire. Both payloads are little endian.
  constexpr std::size_t REQUEST_PAYLOAD_SIZE = 8;
  constexpr std::size_t STATUS_PAYLOAD_SIZE = 18;

  // Limits of the configured bitrate of a request. The client UI allows up to 500000.
  constexpr std::int64_t MIN_CONFIGURED_KBPS = 500;
  constexpr std::int64_t MAX_CONFIGURED_KBPS = 1000000;

  // Minimum time between two encoder restarts for a bitrate change
  constexpr auto RESTART_INTERVAL = std::chrono::seconds(2);

  // The control thread clears a released request without a result after this time
  constexpr auto IN_FLIGHT_TIMEOUT = std::chrono::seconds(5);

  enum class status_e : std::uint16_t {
    applied = 0,  ///< The encoder runs at the new bitrate. No IDR frame.
    applied_restart = 1,  ///< The host restarted the encoder at the new bitrate. One IDR frame.
    unchanged = 2,  ///< The encoder already runs at this value
    not_supported = 3,  ///< The encoder path cannot change the bitrate (sync capture path)
    invalid = 4,  ///< The configured bitrate is out of limits
    encoder_failed = 5,  ///< The restart failed. The encoder runs at the old bitrate.
    input_only = 6,  ///< The session has no video
  };

  /**
   * @brief Name of a status for the log.
   */
  constexpr const char *status_name(status_e status) {
    switch (status) {
      case status_e::applied:
        return "APPLIED";
      case status_e::applied_restart:
        return "APPLIED_RESTART";
      case status_e::unchanged:
        return "UNCHANGED";
      case status_e::not_supported:
        return "NOT_SUPPORTED";
      case status_e::invalid:
        return "INVALID";
      case status_e::encoder_failed:
        return "ENCODER_FAILED";
      case status_e::input_only:
        return "INPUT_ONLY";
    }
    return "UNKNOWN";
  }

  /**
   * @brief SET_BITRATE payload.
   */
  struct request_t {
    std::uint32_t request_id;
    std::uint32_t configured_kbps;  ///< Same unit as x-ml-video.configuredBitrateKbps
  };

  /**
   * @brief Read a SET_BITRATE payload.
   * @param payload The plain payload after the control header.
   * @return The request, or no value when the payload is shorter than REQUEST_PAYLOAD_SIZE.
   */
  inline std::optional<request_t> decode_request(std::string_view payload) {
    if (payload.size() < REQUEST_PAYLOAD_SIZE) {
      return std::nullopt;
    }
    const auto *bytes = reinterpret_cast<const unsigned char *>(payload.data());
    auto le32 = [bytes](std::size_t i) {
      return std::uint32_t(bytes[i]) | std::uint32_t(bytes[i + 1]) << 8 | std::uint32_t(bytes[i + 2]) << 16 | std::uint32_t(bytes[i + 3]) << 24;
    };
    return request_t {le32(0), le32(4)};
  }

  /**
   * @brief BITRATE_STATUS payload.
   */
  struct status_t {
    std::uint32_t request_id;
    std::uint32_t requested_kbps;  ///< The value of the request
    std::uint32_t accepted_kbps;  ///< The configured value after the host cap
    std::uint32_t encoder_kbps;  ///< The encoder bitrate after the full chain
    status_e status;
  };

  /**
   * @brief Write a BITRATE_STATUS payload in little endian byte order.
   */
  inline std::array<std::uint8_t, STATUS_PAYLOAD_SIZE> encode_status(const status_t &status) {
    std::array<std::uint8_t, STATUS_PAYLOAD_SIZE> out {};
    auto put32 = [&out](std::size_t i, std::uint32_t value) {
      out[i] = value & 0xFF;
      out[i + 1] = (value >> 8) & 0xFF;
      out[i + 2] = (value >> 16) & 0xFF;
      out[i + 3] = (value >> 24) & 0xFF;
    };
    put32(0, status.request_id);
    put32(4, status.requested_kbps);
    put32(8, status.accepted_kbps);
    put32(12, status.encoder_kbps);
    const auto code = static_cast<std::uint16_t>(status.status);
    out[16] = code & 0xFF;
    out[17] = (code >> 8) & 0xFF;
    return out;
  }

  /**
   * @brief Input of the bitrate chain. cmd_announce fills it at stream start and the
   * control handler uses it again with a new configured_kbps.
   */
  struct chain_input_t {
    std::int64_t configured_kbps = 0;  ///< Client configured bitrate
    int max_bitrate = 0;  ///< config::video.max_bitrate, 0 = no cap
    std::size_t warp_factor = 1;  ///< 1 when warp mode is not engaged
    int fec_percentage = 20;  ///< config::stream.fec_percentage
    bool audio_high_quality = true;  ///< audio::config_t::HIGH_QUALITY
    int audio_channels = 2;
  };

  struct chain_result_t {
    std::int64_t accepted_kbps;  ///< After the host cap
    std::int64_t encoder_kbps;  ///< After all steps
  };

  /**
   * @brief Convert a configured bitrate to the encoder bitrate.
   * @details The steps of cmd_announce in the same order: cap at max_bitrate, multiply by
   * the warp factor, remove the FEC share (when fec_percentage <= 80), subtract the audio
   * bitrate (at most 20 %), subtract 500 kbps for packet overhead (at most 10 %).
   * The stream start and the SET_BITRATE handler both use this function, thus they agree.
   */
  inline chain_result_t encoder_bitrate(const chain_input_t &input) {
    std::int64_t kbps = input.configured_kbps;
    if (input.max_bitrate > 0 && input.max_bitrate < kbps) {
      kbps = input.max_bitrate;
    }
    const std::int64_t accepted = kbps;

    if (input.warp_factor >= 2) {
      kbps *= input.warp_factor;
    }

    // The same float expression as the old code, so the values do not change
    if (input.fec_percentage <= 80) {
      kbps /= 100.f / (100 - input.fec_percentage);
    }

    const auto audio = (std::int64_t) ((input.audio_high_quality ? 256 : 96) * input.audio_channels);
    kbps -= std::min(audio, kbps / 5);
    kbps -= std::min((std::int64_t) 500, kbps / 10);

    return {accepted, kbps};
  }

  /**
   * @brief Check a SET_BITRATE request before the chain.
   * @param input_only True when the session streams no video.
   * @param encoder_parallel True when the encoder has PARALLEL_ENCODING (capture_async path).
   * @param configured_kbps The configured bitrate of the request.
   * @return The refusal status, or no value when the request is valid.
   */
  inline std::optional<status_e> check_request(bool input_only, bool encoder_parallel, std::uint32_t configured_kbps) {
    if (input_only) {
      return status_e::input_only;
    }
    if (!encoder_parallel) {
      return status_e::not_supported;
    }
    if (configured_kbps < MIN_CONFIGURED_KBPS || configured_kbps > MAX_CONFIGURED_KBPS) {
      return status_e::invalid;
    }
    return std::nullopt;
  }

  /**
   * @brief A bitrate change for the encode thread (mail::bitrate).
   */
  struct change_t {
    std::uint32_t request_id = 0;
    int encoder_kbps = 0;  ///< Value for video::config_t::bitrate
    std::uint32_t requested_kbps = 0;
    std::uint32_t accepted_kbps = 0;
  };

  /**
   * @brief The result of a change from the encode thread (mail::bitrate_result).
   */
  struct result_t {
    change_t change;
    status_e status;
  };

  /**
   * @brief Bitrate state of one session. Only the control thread uses it.
   */
  struct state_t {
    int encoder_kbps = 0;  ///< Encoder bitrate that runs now
    std::uint32_t accepted_kbps = 0;  ///< Configured bitrate after the host cap that runs now
    std::optional<change_t> pending;  ///< Newest request that is not released
    std::optional<change_t> in_flight;  ///< Newest released request without a result
    std::chrono::steady_clock::time_point in_flight_since;
    bool restart_mode = false;  ///< Set after the first encoder restart for a change
    std::chrono::steady_clock::time_point last_restart;

    /**
     * @brief Accept a checked request (spec 5.2 steps 7 and 8).
     * @param change The request after the chain.
     * @param replaced Gets the pending request that this request replaces.
     * @return True when the encoder already runs at this value and no change waits:
     * answer UNCHANGED now. False when the request is stored in pending.
     */
    bool on_request(const change_t &change, std::optional<change_t> &replaced) {
      replaced.reset();
      if (change.encoder_kbps == encoder_kbps && !pending && !in_flight) {
        return true;
      }
      replaced = pending;
      pending = change;
      return false;
    }

    /**
     * @brief Apply a result from the encode thread (spec 5.3 step 1).
     * @return True when the result is for the request in flight, which then ends.
     * A result for an older request leaves in_flight set.
     */
    bool on_result(const result_t &result, std::chrono::steady_clock::time_point now) {
      switch (result.status) {
        case status_e::applied_restart:
          restart_mode = true;
          last_restart = now;
          encoder_kbps = result.change.encoder_kbps;
          accepted_kbps = result.change.accepted_kbps;
          break;
        case status_e::applied:
        case status_e::unchanged:
          encoder_kbps = result.change.encoder_kbps;
          accepted_kbps = result.change.accepted_kbps;
          break;
        case status_e::encoder_failed:
          // The encoder runs at the old bitrate. The failed restart counts for the interval.
          restart_mode = true;
          last_restart = now;
          break;
        default:
          break;
      }
      if (in_flight && in_flight->request_id == result.change.request_id) {
        in_flight.reset();
        return true;
      }
      return false;
    }

    /**
     * @brief Release the pending request to the encode thread (spec 5.3 step 2).
     * @param now Current time.
     * @param resize_busy True when a live resize request is in progress or its display
     * thread runs. capture_async takes a pending resize size at the top of each loop, thus
     * a restart for a bitrate change must not start a loop before the display changes.
     * @return The change to raise on mail::bitrate, or no value.
     */
    std::optional<change_t> take_release(std::chrono::steady_clock::time_point now, bool resize_busy) {
      if (!pending || resize_busy) {
        return std::nullopt;
      }
      if (restart_mode && now - last_restart < RESTART_INTERVAL) {
        return std::nullopt;
      }
      const change_t change = *pending;
      pending.reset();
      in_flight = change;
      in_flight_since = now;
      return change;
    }

    /**
     * @brief Clear a released request that got no result (spec 5.3 step 3).
     * @return True when the function cleared it.
     */
    bool watchdog(std::chrono::steady_clock::time_point now) {
      if (in_flight && now - in_flight_since > IN_FLIGHT_TIMEOUT) {
        in_flight.reset();
        return true;
      }
      return false;
    }

    /**
     * @brief Drop the requests at session stop.
     */
    void clear() {
      pending.reset();
      in_flight.reset();
    }
  };

}  // namespace adaptive_bitrate
