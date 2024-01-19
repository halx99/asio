//
// high_res_clock.hpp
// ~~~~~~~~~~~~~~~~~~
//
// Copyright (c) 2003-2023 Christopher M. Kohlhoff (chris at kohlhoff dot com)
//
// Distributed under the Boost Software License, Version 1.0. (See accompanying
// file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
//

#ifndef HIGH_RES_CLOCK_HPP
#define HIGH_RES_CLOCK_HPP

#include <cstdint>
#include <chrono>
using namespace std::chrono_literals;

inline std::uint64_t high_res_clock()
{
    return std::chrono::steady_clock::now().time_since_epoch().count();
}

struct microsec_clock {
    using rep = long long;
    using period = std::micro;
    using duration = std::chrono::microseconds;
    using time_point = std::chrono::time_point<std::chrono::steady_clock>;
    static constexpr bool is_steady = true;

    static inline time_point universal_time() {
        return std::chrono::time_point_cast<duration>(std::chrono::steady_clock::now());
    }
};

using ptime = microsec_clock::time_point;

#define total_microseconds count

#endif // HIGH_RES_CLOCK_HPP
