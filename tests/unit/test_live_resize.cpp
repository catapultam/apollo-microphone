/**
 * @file tests/unit/test_live_resize.cpp
 * @brief Test src/live_resize.h
 *
 * Builds without the rest of Sunshine. In the moonlight toolbox:
 *   g++ -std=c++20 -Wall -Werror -I . tests/unit/test_live_resize.cpp -lgtest -lgtest_main -pthread -o /tmp/test_live_resize && /tmp/test_live_resize
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
