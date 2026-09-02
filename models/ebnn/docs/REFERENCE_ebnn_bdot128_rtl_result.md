# eBNN Binary-MNIST Wide-BDOT128 RTL 및 FPGA 결과

- 측정일: 2026-08-24
- 모델/input: eBNN Binary-MNIST, 첫 번째 MNIST sample
- 구조: Single-cycle RV32I 35 MHz + BDOT128, Wide-BRAM 105 MHz
- 상태: Verilator full inference PASS

## 적용 구조

- Binary convolution은 3×3 input window를 9-bit vector로 packing한 뒤 BDOT128을
  실행한다.
- 3×3/stride-2 convolution과 3×3/stride-2 max-pooling을 결합해 output당 9개
  BDOT 결과의 최댓값을 사용한다.
- 10×6×6 convolution output은 360-bit vector로 packing한다.
- 마지막 360→10 binary FC는 class별 3개의 128-bit block으로 실행한다.
- 기존 float bias/batch-normalization을 유지해 원본 eBNN과 동일한 판정을 한다.

Weight image는 convolution 160 bytes와 FC 480 bytes를 합쳐 640 bytes를 사용한다.

## 결과

| 항목 | 값 |
|---|---:|
| 기존 RV32I cycles | 4,749,274 |
| Wide-BDOT128 cycles | 1,044,728 |
| Cycle reduction | 4.546× |
| Latency @ 35 MHz | 29.849 ms |
| BDOT instructions | 3,250 |
| 128-bit blocks | 3,270 |
| BCFG instructions | 2 |
| Accelerator errors | 0 |
| Prediction / expected | 5 / 5 |
| Activation checksum | `82552330` |

```text
score_bits=[
  be9a0152,bf3c8938,bee0d7fe,4015220b,bfb6ae47,
  40815608,bd9bda49,3fb3df63,be806104,bfaebdc9
]
TB PASS: eBNN Binary-MNIST BDOT128
```

## Ultra96-V1 FPGA 결과

- 실행일: 2026-08-25
- XSA: `vivado_workspace/260817_Wide_BDOT128/export/Wide_BDOT128_Ultra96V1.xsa`
- Vitis platform: `vitis/platform_2`
- 상태: PASS

| 항목 | RTL | Ultra96-V1 |
|---|---:|---:|
| Latency | 29.849 ms | 29.853 ms |
| Cycles | 1,044,728 | 약 1,044,855 |
| Prediction / expected | 5 / 5 | 5 / 5 |
| Activation checksum | `82552330` | `82552330` |
| BDOT instructions | 3,250 | 3,250 |

FPGA cycle 값은 PS timer로 측정한 29,853 us를 35 MHz로 환산한 값이다. RTL과의
차이는 약 4 us, 127 cycles이며 GPIO handoff와 PS timer 측정 경계를 포함한다.
IMEM 1,481 words, DMEM 690 words, 두 activation bank 각 8,192 words, Weight
160 words의 AXI full read-back이 모두 PASS했다. Prediction, activation checksum,
BDOT count와 10개 score bit pattern도 RTL 회귀값과 exact match했다.

```text
run=29853 us, approximately 1044855 RV32I cycles @ 35 MHz
status=1 prediction=5 expected=5 correct=1 checksum=82552330 bdot=3250
score_bits=[BE9A0152,BF3C8938,BEE0D7FE,4015220B,BFB6AE47,40815608,BD9BDA49,3FB3DF63,BE806104,BFAEBDC9]
Wide-BDOT128 eBNN Binary-MNIST PASS
```

## 재현

```bash
cd RV32I-Project/FPGA/BNN/260817_Wide_BDOT128
./testbench/run_rv32i_ebnn_bdot.sh
```

기존 Wide-BDOT128 XSA와 eBNN Vitis loader를 사용해 Ultra96-V1 board 실행까지
검증했다. eBNN 전용 bitstream은 필요하지 않다.
