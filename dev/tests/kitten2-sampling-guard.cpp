#include "../../app/mobile/shared/kitten2/sampling_guard.h"
#include <cassert>
#include <iostream>
int main() {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    const float maximum = std::numeric_limits<float>::max();
    for (auto scores : {std::vector<float>{}, {nan, nan}, {-inf, -inf}, {inf, nan}, {-maximum, maximum}}) {
        bool rejected = false;
        try { openread::guard_logits(scores); } catch (const openread::InvalidLogits &) { rejected = true; }
        assert(rejected && "An empty candidate set must never reach upstream top-p sampling");
    }
    std::vector<float> mixed{nan, -inf, -maximum, -2, 4, inf};
    openread::guard_logits(mixed);
    assert(mixed[3] == -2 && mixed[4] == 4);
    for (int i : {0, 1, 2, 5}) assert(mixed[i] == -inf);
    std::vector<float> valid{-30, -1, 0, 2};
    const auto original = valid;
    openread::guard_logits(valid);
    assert(valid == original && "Normal model scores must keep their sampling distribution");
    std::cout << "Sampling guard PASS: empty, NaN, infinity, extreme masks and valid rows\n";
}
