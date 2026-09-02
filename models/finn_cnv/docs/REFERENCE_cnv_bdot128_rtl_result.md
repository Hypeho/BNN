# FINN CNV-W1A1 Wide-BDOT128 RTL 및 FPGA 결과

- 측정일: 2026-08-24
- 모델/input: FINN CNV-W1A1, CIFAR-10 class 3 sample
- 구조: Single-cycle RV32I 35 MHz + BDOT128, Wide-BRAM 105 MHz
- 상태: Verilator full inference PASS

## 적용 구조

- 첫 Q1.7/W1 convolution은 CPU에서 실행한다.
- 이후 5개 binary 3×3 convolution은 kernel 위치별 channel vector에 BDOT을 실행하고 9개 결과를 합산한다.
- 3개 binary FC layer는 neuron별 연속 weight에 BDOT을 적용한다.
- Threshold, polarity, max-pooling 및 checksum은 CPU에서 처리한다.
- 64-channel pixel은 BDOT의 16-byte alignment를 위해 2 word padding을 사용한다.
- Synchronous activation BRAM Port A read는 동일 주소를 두 번 읽어 latency를 명시적으로 처리한다.

## Memory layout

| Layer | Offset | BDOT vector | Aligned stride |
|---|---:|---:|---:|
| W1 | 0 B | 64 bits | 16 B/kernel |
| W2 | 9,216 B | 64 bits | 16 B/kernel |
| W3 | 27,648 B | 128 bits | 16 B/kernel |
| W4 | 46,080 B | 128 bits | 16 B/kernel |
| W5 | 82,944 B | 256 bits | 32 B/kernel |
| FC0 | 156,672 B | 256 bits | 32 B/neuron |
| FC1 | 173,056 B | 512 bits | 64 B/neuron |
| FC2 | 205,824 B | 512 bits | 64 B/neuron |

전체 aligned weight는 206,464 B로 400 KiB Weight BRAM의 50.41%를 사용한다. 두 32 KiB activation bank는 최대 30×30×16 B의 padded activation을 수용한다.

## RTL 결과

| 항목 | 값 |
|---|---:|
| CPU cycles | 29,360,256 |
| Latency @ 35 MHz | 838.864 ms |
| BDOT instructions | 756,746 |
| 128-bit blocks | 761,128 |
| BCFG instructions | 8 |
| Accelerator errors | 0 |
| Prediction / expected | 3 / 3 |
| Layer checksum status | PASS |

```text
scores=[-40,-46,-32,404,-30,24,-14,-28,-16,-42]
checksums=[
  c112c55a,d132e492,9ad5c9fa,c038297d,5d36067d,
  338d91b0,8d98f679,2e9f3c9d,aa108d24,9a737f7e
]
TB PASS: FINN CNV BDOT128
```

기존 RV32I software profile은 84,445,960 retired instructions다. 이를 cycle 기준으로 비교하면 CNV BDOT128은 약 2.876배 감소했으며, 35 MHz 기준 baseline 2,412.742 ms에서 838.864 ms로 단축된다.

CNV는 짧은 64/128-bit dot product가 많아 BDOT 명령당 고정 blocking overhead의 비중이 LFC보다 크다. 따라서 이 결과는 다양한 layer shape에서도 정확성이 유지됨을 보이는 두 번째 모델 결과이며, 다음 성능 개선 지점은 여러 kernel vector를 한 요청으로 묶는 convolution 전용 command 또는 BDOT command overhead 축소다.

## Ultra96-V1 FPGA 결과

- 실행일: 2026-08-25
- XSA: `vivado_workspace/260817_Wide_BDOT128/export/Wide_BDOT128_Ultra96V1.xsa`
- Vitis platform: `vitis/platform_2`
- 상태: PASS

| 항목 | RTL | Ultra96-V1 |
|---|---:|---:|
| Latency | 838.864 ms | 838.871 ms |
| Cycles | 29,360,256 | 약 29,360,485 |
| Prediction / expected | 3 / 3 | 3 / 3 |
| Correct | 1 | 1 |
| Layer checksum status | PASS | PASS |

FPGA의 cycle 값은 PS timer로 측정한 838,871 us를 35 MHz로 환산한 값이다. RTL과의
차이는 7 us, 약 229 cycles(0.001% 미만)이며 GPIO handoff와 PS timer 측정 경계를
포함한다. IMEM 687 words, DMEM 2,230 words, 두 activation bank 각 8,192 words,
Weight 51,616 words의 AXI full read-back도 모두 PASS했다. Prediction, class score
10개와 layer checksum 10개는 RTL 회귀값과 exact match했다.

```text
run=838871 us, approximately 29360485 RV32I cycles @ 35 MHz
status=1 prediction=3 expected=3 correct=1 layer_checks=1
scores=[-40,-46,-32,404,-30,24,-14,-28,-16,-42]
checksums=[C112C55A,D132E492,9AD5C9FA,C038297D,5D36067D,338D91B0,8D98F679,2E9F3C9D,AA108D24,9A737F7E]
Wide-BDOT128 FINN CNV PASS
```

## 재현

```bash
cd RV32I-Project/FPGA/BNN/260817_Wide_BDOT128
./testbench/run_rv32i_cnv_bdot.sh
```

CNV image의 Vitis header와 PS loader를 사용해 기존 Wide-BDOT128 XSA에서
Ultra96-V1 board 실행까지 검증했다. CNV 전용 bitstream은 필요하지 않다.
