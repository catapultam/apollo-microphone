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

using live_resize::apply_request;
using live_resize::pending_action_e;
using live_resize::pending_slot_t;
using live_resize::take_pending;

namespace {
  const auto T0 = std::chrono::steady_clock::time_point {} + std::chrono::hours(1);
}

TEST(LiveResizeTests, ApplyRequestStoresWhileBusy) {
  pending_slot_t slot, old;
  EXPECT_EQ(apply_request(slot, true, 1920, 1080, 2536, 1390, 5, T0, old), request_action_e::store_pending);
  EXPECT_FALSE(old.set);
  EXPECT_TRUE(slot.set);
  EXPECT_EQ(slot.request_id, 5u);

  EXPECT_EQ(apply_request(slot, true, 1920, 1080, 1280, 720, 6, T0, old), request_action_e::store_pending);
  EXPECT_TRUE(old.set);
  EXPECT_EQ(old.request_id, 5u);
  EXPECT_EQ(slot.request_id, 6u);
  EXPECT_EQ(slot.width, 1280);
}

TEST(LiveResizeTests, ApplyRequestEqualToTargetClearsTheSlot) {
  pending_slot_t slot, old;
  slot.store(1280, 720, 5, T0);
  EXPECT_EQ(apply_request(slot, true, 1920, 1080, 1920, 1080, 6, T0, old), request_action_e::ignore);
  EXPECT_TRUE(old.set);
  EXPECT_FALSE(slot.set);
}

TEST(LiveResizeTests, ApplyRequestStartWithSlotSetClearsTheSlot) {
  // A display thread ended after the drain pass, before this packet. The newer request
  // starts (or the start path refuses it), and the older pending request must not start later.
  pending_slot_t slot, old;
  slot.store(2536, 1390, 5, T0);
  EXPECT_EQ(apply_request(slot, false, 1920, 1080, 1280, 720, 6, T0, old), request_action_e::start);
  EXPECT_TRUE(old.set);
  EXPECT_EQ(old.request_id, 5u);
  EXPECT_FALSE(slot.set);

  pending_slot_t taken;
  EXPECT_EQ(take_pending(slot, false, false, 1280, 720, T0, taken), pending_action_e::none);
}

TEST(LiveResizeTests, TakePendingWaitsForTheChangeAndTheThread) {
  pending_slot_t slot, taken;
  EXPECT_EQ(take_pending(slot, false, false, 1920, 1080, T0, taken), pending_action_e::none);  // Empty

  slot.store(1280, 720, 5, T0);
  EXPECT_EQ(take_pending(slot, true, true, 1920, 1080, T0, taken), pending_action_e::none);
  EXPECT_EQ(take_pending(slot, true, false, 1920, 1080, T0, taken), pending_action_e::none);  // Request in progress
  EXPECT_EQ(take_pending(slot, false, true, 1920, 1080, T0, taken), pending_action_e::none);  // Revert thread runs
  EXPECT_TRUE(slot.set);

  EXPECT_EQ(take_pending(slot, false, false, 1920, 1080, T0, taken), pending_action_e::start);
  EXPECT_FALSE(slot.set);
  EXPECT_EQ(taken.request_id, 5u);
  EXPECT_EQ(taken.width, 1280);
  EXPECT_EQ(taken.height, 720);
}

TEST(LiveResizeTests, TakePendingDropsTheCurrentSize) {
  // In progress A from S, pending S, A refused: the current size is S again
  pending_slot_t slot, taken;
  slot.store(1920, 1080, 5, T0);
  EXPECT_EQ(take_pending(slot, false, false, 1920, 1080, T0, taken), pending_action_e::drop);
  EXPECT_FALSE(slot.set);
  EXPECT_EQ(taken.request_id, 5u);
}

TEST(LiveResizeTests, TakePendingRefusesWithBusyAfterTheTimeout) {
  pending_slot_t slot, taken;
  slot.store(1280, 720, 5, T0);
  slot.store(1600, 900, 6, T0 + std::chrono::seconds(50));
  EXPECT_EQ(take_pending(slot, true, true, 1920, 1080, T0 + live_resize::PENDING_TIMEOUT, taken), pending_action_e::none);
  EXPECT_EQ(take_pending(slot, true, true, 1920, 1080, T0 + live_resize::PENDING_TIMEOUT + std::chrono::seconds(1), taken), pending_action_e::refuse_busy);
  EXPECT_FALSE(slot.set);
  EXPECT_EQ(taken.request_id, 6u);  // BUSY uses the id and size of the latest request
  EXPECT_EQ(taken.width, 1600);
}

TEST(LiveResizeTests, DrainOrderStartsTheLatestRequestOnce) {
  // Drain order in stream.cpp: refusals, done check, watchdog, then the pending slot.
  // A in progress; B, then C, arrive while busy; A is refused with ENCODER_FAILED.
  pending_slot_t slot, old, taken;
  int current_w = 2536, current_h = 1390;  // Target of A
  EXPECT_EQ(apply_request(slot, true, current_w, current_h, 1280, 720, 2, T0, old), request_action_e::store_pending);
  EXPECT_EQ(apply_request(slot, true, current_w, current_h, 1600, 900, 3, T0, old), request_action_e::store_pending);

  // The refusal loop sets the size back and starts the revert thread in the same pass
  current_w = 1920;
  current_h = 1080;
  EXPECT_EQ(take_pending(slot, false, true, current_w, current_h, T0, taken), pending_action_e::none);

  // A later pass, after the revert thread ended: C starts, B never starts
  EXPECT_EQ(take_pending(slot, false, false, current_w, current_h, T0, taken), pending_action_e::start);
  EXPECT_EQ(taken.request_id, 3u);
  EXPECT_EQ(take_pending(slot, false, false, current_w, current_h, T0, taken), pending_action_e::none);
}
