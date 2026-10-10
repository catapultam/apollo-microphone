/**
 * @file tests/unit/test_live_resize.cpp
 * @brief Test src/live_resize.h
 *
 * Builds without the rest of Sunshine. In the moonlight toolbox:
 *   g++ -std=c++20 -Wall -Werror -I . -I third-party/googletest/googletest/include tests/unit/test_live_resize.cpp -L <gtest build dir> -lgtest -lgtest_main -pthread -o /tmp/test_live_resize && /tmp/test_live_resize
 */
#include <gtest/gtest.h>
#include <src/live_resize.h>

using live_resize::reason_e;
using live_resize::validate_size;

TEST(LiveResizeTests, PayloadSizesMatchTheSpec) {
  EXPECT_EQ(sizeof(live_resize::request_payload_t), 8u);
  EXPECT_EQ(sizeof(live_resize::refused_payload_t), 10u);
  EXPECT_EQ(live_resize::PACKET_TYPE_REQUEST, 0x3100);
  EXPECT_EQ(live_resize::PACKET_TYPE_REFUSED, 0x3101);
}

TEST(LiveResizeTests, AcceptsEvenSizesInsideTheLimits) {
  EXPECT_EQ(validate_size(2536, 1390, 1, false), reason_e::ok);
  EXPECT_EQ(validate_size(320, 200, 0, false), reason_e::ok);
  EXPECT_EQ(validate_size(4096, 4096, 0, false), reason_e::ok);
  EXPECT_EQ(validate_size(8192, 8192, 2, false), reason_e::ok);
}

TEST(LiveResizeTests, RejectsOddSizes) {
  EXPECT_EQ(validate_size(2537, 1390, 1, false), reason_e::size_limit);
  EXPECT_EQ(validate_size(2536, 1391, 1, false), reason_e::size_limit);
}

TEST(LiveResizeTests, RejectsSmallSizes) {
  // Review Focus 2: a minimized or tiny window
  EXPECT_EQ(validate_size(0, 0, 1, false), reason_e::size_limit);
  EXPECT_EQ(validate_size(318, 200, 1, false), reason_e::size_limit);
  EXPECT_EQ(validate_size(320, 198, 1, false), reason_e::size_limit);
}

TEST(LiveResizeTests, RejectsSizesAboveTheCodecLimit) {
  EXPECT_EQ(validate_size(4098, 100, 0, false), reason_e::size_limit);  // H.264
  EXPECT_EQ(validate_size(4098, 200, 1, false), reason_e::ok);  // HEVC
  EXPECT_EQ(validate_size(8194, 200, 1, false), reason_e::size_limit);
  EXPECT_EQ(validate_size(200, 8194, 2, false), reason_e::size_limit);
}

TEST(LiveResizeTests, RejectsInputOnlySessions) {
  EXPECT_EQ(validate_size(2536, 1390, 1, true), reason_e::size_limit);
}

using live_resize::decide_request;
using live_resize::request_action_e;

TEST(LiveResizeTests, IgnoresTheTargetSize) {
  // Equal to the size in progress, or to the current size when nothing is in progress
  EXPECT_EQ(decide_request(true, 1920, 1080, 1920, 1080), request_action_e::ignore);
  EXPECT_EQ(decide_request(false, 1920, 1080, 1920, 1080), request_action_e::ignore);
}

TEST(LiveResizeTests, StoresADifferentSizeWhileBusy) {
  EXPECT_EQ(decide_request(true, 1920, 1080, 2536, 1390), request_action_e::store_pending);
  // Only the width or only the height is different
  EXPECT_EQ(decide_request(true, 1920, 1080, 1920, 1200), request_action_e::store_pending);
  EXPECT_EQ(decide_request(true, 1920, 1080, 2560, 1080), request_action_e::store_pending);
}

TEST(LiveResizeTests, StartsADifferentSizeWhenIdle) {
  EXPECT_EQ(decide_request(false, 1920, 1080, 2536, 1390), request_action_e::start);
  // The start path checks the size, not this function
  EXPECT_EQ(decide_request(false, 1920, 1080, 1, 1), request_action_e::start);
}

TEST(LiveResizeTests, PendingSlotKeepsTheLatestRequest) {
  const auto t0 = std::chrono::steady_clock::time_point {} + std::chrono::hours(1);
  live_resize::pending_slot_t slot;
  EXPECT_FALSE(slot.set);

  slot.store(2536, 1390, 7, t0);
  slot.store(1280, 720, 9, t0 + std::chrono::seconds(5));
  EXPECT_TRUE(slot.set);
  EXPECT_EQ(slot.width, 1280);
  EXPECT_EQ(slot.height, 720);
  EXPECT_EQ(slot.request_id, 9u);
  // An overwrite does not reset the time of the first store
  EXPECT_EQ(slot.first_stored, t0);

  slot.clear();
  EXPECT_FALSE(slot.set);
  slot.store(800, 600, 10, t0 + std::chrono::seconds(30));
  EXPECT_EQ(slot.first_stored, t0 + std::chrono::seconds(30));
}

TEST(LiveResizeTests, PendingSlotExpiresAfterTheTimeout) {
  const auto t0 = std::chrono::steady_clock::time_point {} + std::chrono::hours(1);
  live_resize::pending_slot_t slot;
  EXPECT_FALSE(slot.expired(t0 + std::chrono::hours(1)));  // Empty slot

  slot.store(2536, 1390, 7, t0);
  // Overwrites cannot keep the slot alive
  slot.store(1280, 720, 8, t0 + live_resize::PENDING_TIMEOUT);
  EXPECT_FALSE(slot.expired(t0 + live_resize::PENDING_TIMEOUT));
  EXPECT_TRUE(slot.expired(t0 + live_resize::PENDING_TIMEOUT + std::chrono::seconds(1)));
  EXPECT_EQ(live_resize::PENDING_TIMEOUT, std::chrono::seconds(60));
}

TEST(LiveResizeTests, StartsPendingOnlyWhenTheChangeEnded) {
  EXPECT_TRUE(live_resize::can_start_pending(false, false, true));
  EXPECT_FALSE(live_resize::can_start_pending(true, false, true));  // Request in progress
  EXPECT_FALSE(live_resize::can_start_pending(false, true, true));  // Revert thread runs
  EXPECT_FALSE(live_resize::can_start_pending(true, true, true));
  EXPECT_FALSE(live_resize::can_start_pending(false, false, false));  // Empty slot
}
