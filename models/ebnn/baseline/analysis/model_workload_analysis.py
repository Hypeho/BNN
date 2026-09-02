#!/usr/bin/env python3

"""Calculate BNN operation counts and analytical speedup scenarios."""

from __future__ import annotations

import math


def words(bits: int, width: int) -> int:
    return math.ceil(bits / width)


def lfc_counts(width: int) -> int:
    layers = [(784, 1024), (1024, 1024), (1024, 1024), (1024, 10)]
    return sum(words(inputs, width) * outputs for inputs, outputs in layers)


def cnv_counts(width: int) -> int:
    # Conv1 is excluded: its activation input is 8-bit rather than bipolar.
    layers = [
        (576, 28 * 28 * 64),
        (576, 12 * 12 * 128),
        (1152, 10 * 10 * 128),
        (1152, 3 * 3 * 256),
        (2304, 1 * 1 * 256),
        (256, 512),
        (512, 512),
        (512, 10),
    ]
    return sum(words(inputs, width) * outputs for inputs, outputs in layers)


def ebnn_counts(width: int) -> int:
    conv_dots = 6 * 6 * 10 * 3 * 3
    fc_outputs = 10
    return conv_dots * words(9, width) + fc_outputs * words(360, width)


def amdahl(fraction: float, regional_speedup: float) -> float:
    return 1.0 / ((1.0 - fraction) + fraction / regional_speedup)


def main() -> None:
    print("[packed XNOR-popcount operations]")
    print("model,width,operations")
    for model, counter in (("eBNN", ebnn_counts), ("LFC", lfc_counts), ("CNV", cnv_counts)):
        for width in (32, 64, 128):
            print(f"{model},{width},{counter(width)}")

    total = 4_749_272
    packing = 832_680
    accelerated_region = 2_980_800 + 8_550
    fixed = total - packing - accelerated_region
    n32 = ebnn_counts(32)
    print("\n[eBNN measured Amdahl model]")
    print(f"baseline={total} packing={packing} accelerated_region={accelerated_region} fixed={fixed}")
    for name, cost_per_word in (("optimized_rv32i_swar", 23), ("mxpc32_loop", 7), ("mxpc32_block", 3)):
        new_region = n32 * cost_per_word
        new_total = fixed + packing + new_region
        regional_speedup = accelerated_region / new_region
        print(
            f"{name}: region={new_region} regional_speedup={regional_speedup:.3f} "
            f"total={new_total} overall_speedup={total / new_total:.3f} "
            f"amdahl={amdahl(accelerated_region / total, regional_speedup):.3f}"
        )
    no_pack_total = fixed + n32 * 3
    print(f"mxpc32_block_no_pack: total={no_pack_total} overall_speedup={total / no_pack_total:.3f}")

    print("\n[generic Amdahl sensitivity]")
    print("binary_fraction,loop_speedup_23_to_7,block_speedup_23_to_3")
    for fraction in (0.5, 0.7, 0.8, 0.9, 0.95):
        print(
            f"{fraction:.2f},{amdahl(fraction, 23 / 7):.3f},"
            f"{amdahl(fraction, 23 / 3):.3f}"
        )

    cnv_binary_bits = 57_906_176
    cnv_n32 = cnv_counts(32)
    print("\n[CNV packing sensitivity]")
    print("scenario,packing_cycles,software_cycles,accelerated_cycles,speedup")
    software_core = cnv_n32 * 23
    accelerated_core = cnv_n32 * 3
    for name, packing_cycles in (
        ("prepacked_or_hardware_window", 0),
        ("software_pack_7_cycles_per_bit", cnv_binary_bits * 7),
        ("ebnn_observed_pack_28.556_cycles_per_bit", round(cnv_binary_bits * (832_680 / 29_160))),
    ):
        before = packing_cycles + software_core
        after = packing_cycles + accelerated_core
        print(f"{name},{packing_cycles},{before},{after},{before / after:.3f}")

    print("\n[FINN full RV32I measured XPC replacement]")
    print("model,baseline,xpc_region,xpc_fraction,cost_per_word,new_total,speedup")
    measured = (
        # Region includes the software function and one call instruction per dot/vector call.
        ("LFC", 2_399_395, 2_329_548 + 3_082, lfc_counts(32)),
        ("CNV", 84_445_960, 43_429_632 + 1_809_568, cnv_counts(32)),
    )
    for model, baseline, region, operations in measured:
        for cost_per_word in (7, 3, 1):
            new_total = baseline - region + operations * cost_per_word
            print(
                f"{model},{baseline},{region},{region / baseline:.6f},"
                f"{cost_per_word},{new_total},{baseline / new_total:.3f}"
            )

    print("\n[CNV optimistic binary-suffix block bound]")
    print("cost_per_word,fixed,new_total,speedup")
    cnv_total = 84_445_960
    # Removes xnor_word plus binary Conv/FC/final-loop control. This is an upper bound;
    # a real block engine adds descriptor, threshold, and output costs.
    cnv_block_region = 43_429_632 + 24_263_853 + 109_360 + 70_701
    cnv_fixed = cnv_total - cnv_block_region
    for cost_per_word in (7, 3, 1):
        new_total = cnv_fixed + cnv_n32 * cost_per_word
        print(f"{cost_per_word},{cnv_fixed},{new_total},{cnv_total / new_total:.3f}")


if __name__ == "__main__":
    main()
