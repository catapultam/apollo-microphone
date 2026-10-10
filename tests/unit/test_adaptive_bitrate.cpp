/**
 * @file tests/unit/test_adaptive_bitrate.cpp
 * @brief Test src/adaptive_bitrate.h
 *
 * Builds without the rest of Sunshine. In the moonlight toolbox:
 *   g++ -std=c++20 -Wall -Werror -I . -I third-party/googletest/googletest/include tests/unit/test_adaptive_bitrate.cpp -L /tmp/gtest-build -lgtest -lgtest_main -pthread -o /tmp/test_adaptive_bitrate && /tmp/test_adaptive_bitrate
 */
#include <gtest/gtest.h>
#include <src/adaptive_bitrate.h>

#include <algorithm>
#include <string>

using namespace std::chrono_literals;
using adaptive_bitrate::change_t;
using adaptive_bitrate::result_t;
using adaptive_bitrate::state_t;
using adaptive_bitrate::status_e;

namespace {
  // The inline code of cmd_announce (src/rtsp.cpp) before Task 5, without the logs.
  // encoder_bitrate() must give the same values.
  std::pair<std::int64_t, std::int64_t> old_chain(std::int64_t configuredBitrateKbps, int max_bitrate, std::size_t warp_factor, int fec_percentage, bool high_quality, int channels) {
    if (max_bitrate > 0) {
      if (max_bitrate < configuredBitrateKbps) {
        configuredBitrateKbps = max_bitrate;
      }
    }
    const std::int64_t accepted = configuredBitrateKbps;
    if (warp_factor >= 2) {
      configuredBitrateKbps *= warp_factor;
    }
    if (configuredBitrateKbps) {
      if (fec_percentage <= 80) {
        configuredBitrateKbps /= 100.f / (100 - fec_percentage);
      }
      auto audioBitrateAdjustment = (high_quality ? 256 : 96) * channels;
      configuredBitrateKbps -= std::min((std::int64_t) audioBitrateAdjustment, configuredBitrateKbps / 5);
      configuredBitrateKbps -= std::min((std::int64_t) 500, configuredBitrateKbps / 10);
    }
    return {accepted, configuredBitrateKbps};
  }

  change_t make_change(std::uint32_t id, int encoder_kbps) {
    return change_t {id, encoder_kbps, (std::uint32_t) encoder_kbps * 5 / 4, (std::uint32_t) encoder_kbps * 5 / 4};
  }

  state_t started_state() {
    state_t state;
    state.encoder_kbps = 30000;
    state.accepted_kbps = 40000;
    return state;
  }
}  // namespace

TEST(AdaptiveBitrateWire, IdsAndSizesMatchTheSpec) {
  EXPECT_EQ(adaptive_bitrate::PACKET_TYPE_SET, 0x3102);
  EXPECT_EQ(adaptive_bitrate::PACKET_TYPE_STATUS, 0x3103);
  EXPECT_EQ(adaptive_bitrate::REQUEST_PAYLOAD_SIZE, 8u);
  EXPECT_EQ(adaptive_bitrate::STATUS_PAYLOAD_SIZE, 18u);
  EXPECT_EQ((int) status_e::applied, 0);
  EXPECT_EQ((int) status_e::applied_restart, 1);
  EXPECT_EQ((int) status_e::unchanged, 2);
  EXPECT_EQ((int) status_e::not_supported, 3);
  EXPECT_EQ((int) status_e::invalid, 4);
  EXPECT_EQ((int) status_e::encoder_failed, 5);
  EXPECT_EQ((int) status_e::input_only, 6);
  EXPECT_STREQ(adaptive_bitrate::status_name(status_e::applied_restart), "APPLIED_RESTART");
}

TEST(AdaptiveBitrateWire, DecodesALittleEndianRequest) {
  const std::string payload {"\x07\x00\x00\x00\x40\x9c\x00\x00", 8};  // id 7, 40000 kbps
  auto request = adaptive_bitrate::decode_request(payload);
  ASSERT_TRUE(request.has_value());
  EXPECT_EQ(request->request_id, 7u);
  EXPECT_EQ(request->configured_kbps, 40000u);

  // A longer payload is accepted; a shorter one is not
  EXPECT_TRUE(adaptive_bitrate::decode_request(payload + "xx").has_value());
  EXPECT_FALSE(adaptive_bitrate::decode_request(payload.substr(0, 7)).has_value());
  EXPECT_FALSE(adaptive_bitrate::decode_request({}).has_value());
}

TEST(AdaptiveBitrateWire, EncodesALittleEndianStatus) {
  const auto bytes = adaptive_bitrate::encode_status({0x01020304, 40000, 20000, 15500, status_e::applied_restart});
  const std::array<std::uint8_t, 18> expected {
    0x04, 0x03, 0x02, 0x01,  // request_id
    0x40, 0x9c, 0x00, 0x00,  // requested 40000
    0x20, 0x4e, 0x00, 0x00,  // accepted 20000
    0x8c, 0x3c, 0x00, 0x00,  // encoder 15500
    0x01, 0x00,  // APPLIED_RESTART
  };
  EXPECT_EQ(bytes, expected);
}

TEST(AdaptiveBitrateChain, EqualsTheOldInlineCode) {
  for (std::int64_t configured : {500, 1500, 20000, 44000, 150000, 500000}) {
    for (int max_bitrate : {0, 20000}) {
      for (std::size_t warp : {1, 2}) {
        for (int fec : {0, 20, 90}) {
          for (bool high : {false, true}) {
            for (int channels : {2, 8}) {
              adaptive_bitrate::chain_input_t input {configured, max_bitrate, warp, fec, high, channels};
              const auto result = adaptive_bitrate::encoder_bitrate(input);
              const auto old = old_chain(configured, max_bitrate, warp, fec, high, channels);
              EXPECT_EQ(result.accepted_kbps, old.first) << configured << ' ' << max_bitrate << ' ' << warp << ' ' << fec << ' ' << high << ' ' << channels;
              EXPECT_EQ(result.encoder_kbps, old.second) << configured << ' ' << max_bitrate << ' ' << warp << ' ' << fec << ' ' << high << ' ' << channels;
            }
          }
        }
      }
    }
  }
}

TEST(AdaptiveBitrateChain, KnownValues) {
  // 44000 kbps, FEC 20 %, stereo high quality: 44000 / 1.25 = 35200, - 512 = 34688, - 500 = 34188
  auto result = adaptive_bitrate::encoder_bitrate({44000, 0, 1, 20, true, 2});
  EXPECT_EQ(result.accepted_kbps, 44000);
  EXPECT_EQ(result.encoder_kbps, 34188);

  // The host cap gives the accepted value
  result = adaptive_bitrate::encoder_bitrate({44000, 20000, 1, 20, true, 2});
  EXPECT_EQ(result.accepted_kbps, 20000);
  EXPECT_LT(result.encoder_kbps, 20000);
}

TEST(AdaptiveBitrateRequest, Refusals) {
  EXPECT_EQ(adaptive_bitrate::check_request(true, true, 20000), status_e::input_only);
  EXPECT_EQ(adaptive_bitrate::check_request(false, false, 20000), status_e::not_supported);
  EXPECT_EQ(adaptive_bitrate::check_request(false, true, 499), status_e::invalid);
  EXPECT_EQ(adaptive_bitrate::check_request(false, true, 1000001), status_e::invalid);
  EXPECT_FALSE(adaptive_bitrate::check_request(false, true, 500).has_value());
  EXPECT_FALSE(adaptive_bitrate::check_request(false, true, 1000000).has_value());
}

TEST(AdaptiveBitrateState, EqualValueWithNothingWaitingIsUnchanged) {
  auto state = started_state();
  std::optional<change_t> replaced;
  EXPECT_TRUE(state.on_request(make_change(1, 30000), replaced));
  EXPECT_FALSE(state.pending.has_value());
  EXPECT_FALSE(replaced.has_value());
}

TEST(AdaptiveBitrateState, NewerRequestReplacesThePendingOne) {
  auto state = started_state();
  std::optional<change_t> replaced;
  EXPECT_FALSE(state.on_request(make_change(1, 20000), replaced));
  EXPECT_FALSE(replaced.has_value());
  EXPECT_FALSE(state.on_request(make_change(2, 25000), replaced));
  ASSERT_TRUE(replaced.has_value());
  EXPECT_EQ(replaced->request_id, 1u);
  EXPECT_EQ(state.pending->request_id, 2u);

  // An equal value is not UNCHANGED while a change waits: it must replace it
  EXPECT_FALSE(state.on_request(make_change(3, 30000), replaced));
  EXPECT_EQ(state.pending->request_id, 3u);
}

TEST(AdaptiveBitrateState, ReleaseMovesPendingToInFlight) {
  auto state = started_state();
  const auto now = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  auto released = state.take_release(now, false);
  ASSERT_TRUE(released.has_value());
  EXPECT_EQ(released->request_id, 1u);
  EXPECT_FALSE(state.pending.has_value());
  ASSERT_TRUE(state.in_flight.has_value());
  EXPECT_EQ(state.in_flight_since, now);
  EXPECT_FALSE(state.take_release(now, false).has_value());
}

TEST(AdaptiveBitrateState, ReleaseWaitsForLiveResize) {
  // Review Focus 1: capture_async takes a pending resize size at the top of each loop,
  // so a bitrate restart during a resize would apply the size before the display changes
  auto state = started_state();
  const auto now = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  EXPECT_FALSE(state.take_release(now, true).has_value());
  EXPECT_TRUE(state.pending.has_value());
  EXPECT_TRUE(state.take_release(now + 150ms, false).has_value());
}

TEST(AdaptiveBitrateState, RestartModeKeepsTwoSecondsBetweenRestarts) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  state.take_release(t0, false);
  EXPECT_TRUE(state.on_result({make_change(1, 20000), status_e::applied_restart}, t0 + 500ms));
  EXPECT_TRUE(state.restart_mode);
  EXPECT_EQ(state.encoder_kbps, 20000);
  EXPECT_EQ(state.accepted_kbps, 25000u);

  state.on_request(make_change(2, 15000), replaced);
  EXPECT_FALSE(state.take_release(t0 + 2400ms, false).has_value());
  EXPECT_TRUE(state.take_release(t0 + 2500ms, false).has_value());
}

TEST(AdaptiveBitrateState, InPlaceChangesHaveNoInterval) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  state.take_release(t0, false);
  state.on_result({make_change(1, 20000), status_e::applied}, t0 + 20ms);
  EXPECT_FALSE(state.restart_mode);
  state.on_request(make_change(2, 15000), replaced);
  EXPECT_TRUE(state.take_release(t0 + 40ms, false).has_value());
}

TEST(AdaptiveBitrateState, ResultOfAnOlderRequestKeepsInFlight) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  state.take_release(t0, false);
  state.on_request(make_change(2, 15000), replaced);
  state.take_release(t0 + 10ms, false);  // the mail keeps only request 2
  EXPECT_FALSE(state.on_result({make_change(1, 20000), status_e::applied}, t0 + 20ms));
  ASSERT_TRUE(state.in_flight.has_value());
  EXPECT_EQ(state.in_flight->request_id, 2u);
  EXPECT_TRUE(state.on_result({make_change(2, 15000), status_e::applied}, t0 + 30ms));
  EXPECT_FALSE(state.in_flight.has_value());
  EXPECT_EQ(state.encoder_kbps, 15000);
}

TEST(AdaptiveBitrateState, EncoderFailureKeepsTheRunningValues) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 60000), replaced);
  state.take_release(t0, false);
  EXPECT_TRUE(state.on_result({make_change(1, 60000), status_e::encoder_failed}, t0 + 100ms));
  EXPECT_EQ(state.encoder_kbps, 30000);
  EXPECT_EQ(state.accepted_kbps, 40000u);
  // A failed restart is a restart: the interval applies
  EXPECT_TRUE(state.restart_mode);
  EXPECT_EQ(state.last_restart, t0 + 100ms);
}

TEST(AdaptiveBitrateState, WatchdogClearsALateRequest) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  state.take_release(t0, false);
  EXPECT_FALSE(state.watchdog(t0 + 5s));
  EXPECT_TRUE(state.watchdog(t0 + 5001ms));
  EXPECT_FALSE(state.in_flight.has_value());
}

TEST(AdaptiveBitrateState, ClearDropsPendingAndInFlight) {
  auto state = started_state();
  const auto t0 = std::chrono::steady_clock::now();
  std::optional<change_t> replaced;
  state.on_request(make_change(1, 20000), replaced);
  state.take_release(t0, false);
  state.on_request(make_change(2, 15000), replaced);
  state.clear();
  EXPECT_FALSE(state.pending.has_value());
  EXPECT_FALSE(state.in_flight.has_value());
}
