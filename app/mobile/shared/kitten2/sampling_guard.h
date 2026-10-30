// OpenRead adapter: GPL-3.0-or-later.
#pragma once
#include <cmath>
#include <limits>
#include <stdexcept>
#include <vector>

namespace openread {
struct InvalidLogits : std::runtime_error {
    InvalidLogits() : std::runtime_error("The voice returned no valid sound candidates.") {}
};
// The upstream top-p filter assumes a finite candidate exists. Model failures
// can return NaNs or an all-masked row; never let that become order.back() on
// an empty vector. Leave headroom for repetition/temperature scaling as well.
inline void guard_logits(std::vector<float> &scores) {
    constexpr float limit = std::numeric_limits<float>::max() / 4;
    bool candidate = false;
    for (auto &score : scores) {
        if (!std::isfinite(score) || std::fabs(score) > limit)
            score = -std::numeric_limits<float>::infinity();
        else candidate = true;
    }
    if (!candidate) throw InvalidLogits();
}
}
