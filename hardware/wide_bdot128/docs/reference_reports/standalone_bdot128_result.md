# Standalone Wide-BRAM BDOT128 기능검증 결과

> 이 문서는 standalone 단계 당시의 이력이다. 현재 CPU/BDOT 35 MHz 통합형 구조와
> 최신 결과는 `cpu_integrated_bdot35_implementation_result.md`를 기준으로 한다.

- 검증일: 2026-08-17
- 상태: PASS
- 범위: CPU, CDC, AXI 및 Vivado BMG를 제외한 standalone RTL

## 구현 항목

- 32-bit Port A / 128-bit Port B asymmetric memory 기능 모델
- 기존 `xnor_popcount32` 4개를 재사용한 balanced reduction tree
- bit별 valid mask를 적용한 128-bit XNOR-Popcount
- blocking BDOT FSM
- byte-address 기반 Activation/Weight address generator
- single/multi-block accumulator
- 784-bit 마지막 16-bit tail mask
- invalid request 검출
- busy 중 중복 request 억제
- request가 유지될 때 done/result hold
- transaction 중 reset과 이후 recovery

## 시험 결과

```text
TB PASS: wide_bram_wrapper tests=7 errors=0
TB PASS: wide_xnor_popcount vectors=2134 errors=0
TB PASS: wide_bdot_accel tests=14 errors=0
ALL FUNCTIONAL TESTS PASS
```

Verilator lint도 computational RTL에 대해 warning 없이 완료됐다.

```text
verilator --lint-only -Wall -Wno-fatal --top-module wide_bdot_accel ...
```

## Cycle 측정

기능 우선 FSM은 block마다 다음 세 상태를 사용한다.

```text
ISSUE -> WAIT -> ACCUM
```

| bit length | block | accelerator cycle |
|---:|---:|---:|
| 128 | 1 | 3 |
| 256 | 2 | 6 |
| 512 | 4 | 12 |
| 784 | 7 | 21 |
| 1024 | 8 | 24 |

따라서 현재 standalone RTL의 `II_block`은 3이다. 784-bit LFC W0 dot은
7 block, 21 accelerator cycle이 필요하다.

FINN LFC 전체 기준 accelerator block cycle의 1차 값은 다음과 같다.

```text
23,632 block * 3 cycle/block = 70,896 accelerator cycles
```

이 값에는 CPU의 threshold/packing/neuron loop와 CPU-accelerator CDC가 포함되지
않으므로 최종 latency나 break-even 값으로 사용하지 않는다.

## 검증된 memory contract

- Port A address는 32-bit word에 대한 byte address이다.
- Port B address는 wide row에 대한 byte address이며 16-byte aligned여야 한다.
- 낮은 byte address의 word가 `doutb[31:0]`에 위치한다.
- 이후 word는 `doutb[63:32]`, `[95:64]`, `[127:96]` 순서로 배치된다.
- Port A의 byte enable이 예상 byte lane만 변경한다.

## 현재 한계

- `wide_bram_32xwide_model.v`은 functional simulation model이며 실제 BMG inference
  또는 FPGA primitive가 아니다.
- CPU blocking state와 register write-back은 아직 통합하지 않았다.
- CPU 35 MHz와 accelerator 105 MHz 사이 CDC는 아직 구현하지 않았다.
- FINN LFC의 CPU host cycle을 측정하지 않아 최종 break-even 주파수는 미확정이다.
- post-synthesis resource와 timing은 아직 측정하지 않았다.

## 다음 단계

1. RV32I에 `BCFG_LENGTH`와 `BDOT` decode를 추가한다.
2. IDLE/WAIT/COMMIT state로 PC hold와 single write-back을 구현한다.
3. request/done CDC를 level 또는 toggle handshake로 구현한다.
4. 기존 RV32I/XPC32/eBNN regression을 유지한다.
5. FINN LFC BDOT variant로 CPU host cycle을 측정해 break-even을 확정한다.
