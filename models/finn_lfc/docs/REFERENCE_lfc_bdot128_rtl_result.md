# FINN LFC Wide-BRAM BDOT128 RTL 통합 결과

> 상태: 이 문서는 이전 35/105 MHz accelerator CDC 구조의 역사적 측정이다.
> 현재 구현은 CPU/BDOT 35 MHz 통합형이며 최신 결과는
> `cpu_integrated_bdot35_implementation_result.md`를 따른다.

- 검증일: 2026-08-17
- 상태: RTL 전체 추론 PASS
- CPU clock: 약 35 MHz
- Accelerator/BRAM wide-port clock: 약 105 MHz
- FPGA 합성·실측: 미수행

## 1. 검증 범위

기존 FINN LFC-W1A1 parameter와 입력을 128-bit row에 맞게 재배치하고 다음 전체
경로를 실행했다.

```text
RV32I software
  -> BCFG_LENGTH / blocking BDOT
  -> CPU-to-accelerator toggle CDC
  -> 128-bit Activation/Weight read
  -> XNOR-Popcount 및 neuron 누산
  -> accelerator-to-CPU result CDC
  -> CPU threshold/polarity 및 activation packing
  -> 4-layer prediction
```

Activation memory는 true dual-port clock 조건으로 검증했다.

- Port A: CPU 32-bit read/write, CPU 35 MHz clock
- Port B: accelerator 128-bit read, accelerator 105 MHz clock

CPU 신호를 accelerator clock에서 직접 샘플링하지 않는다. Vivado BMG도 이
비대칭 폭·독립 clock 계약을 만족해야 한다.

## 2. Software 및 image

### 2.1 명령 ABI

| 명령 | opcode | funct3 | 동작 |
|---|---:|---:|---|
| `BCFG_LENGTH rs1` | `0x2B` | `000` | BDOT bit length 설정 |
| `BDOT rd,rs1,rs2` | `0x2B` | `001` | Activation/Weight BDOT 후 `rd`에 match count 반환 |

`bdot.h`는 GNU assembler의 `.insn r`을 사용하며 BDOT에는 `memory` clobber를
지정했다. 한 번의 추론에서 BCFG 4회, BDOT 3,082회가 동적으로 실행된다.

### 2.2 Memory image

| 항목 | 결과 |
|---|---:|
| Weight 할당 | 400 KiB, 102,400 word |
| Weight 사용 | 378,112 B, 94,528 word |
| Activation 0/1 | 각각 32 KiB |
| W0/W1/W2/W3 offset | `0x00000`, `0x1C000`, `0x3C000`, `0x5C000` |
| W0 stride | 112 B, 784 bit + zero padding |
| W1/W2/W3 stride | 128 B |

Generator는 원본 layout과 aligned layout 추론 결과가 layer activation, score 및
prediction까지 같을 때만 image를 출력한다. 현재 주요 SHA-256은 다음과 같다.

```text
weight_128.hex   0468f379aa98cf070b90174cedfd8f179753b0891a294349300839a28c9678ce
activation0.hex c0b429d305eaaa078b25ccb359fcbc0d52cdb2001b429ef0fd60fc333b68c0a0
activation1.hex e2a781641ce9637c52daea07f06ac16fe70ee751f4f4261477f77d6372a0f329
```

### 2.3 RV32I image 크기

```text
text=7,072 B, data=0 B, bss/mailbox=4,096 B
```

`text` 합계는 실행 코드 544 B와 threshold/polarity `.rodata` 6,528 B이다. Weight를
CPU ELF에서 제거했으므로 CPU DMEM 64 KiB 안에 여유 있게 들어간다.

## 3. 정합성 결과

다음 항목을 testbench에서 모두 assert했다.

- Layer 0, 1, 2의 packed activation: word 단위 golden과 일치
- BDOT 수: 3,082
- 128-bit block read 수: 23,632
- BCFG 수: 4
- accelerator error: 0
- prediction: 5
- class score 10개: golden과 일치

```text
scores = [-182, -94, -34, 326, -162, 556, 54, 6, 216, -96]
prediction = 5
```

최종 로그:

```text
LFC BDOT result cycles=105699 bdot=3082 blocks=23632 bcfg=4 status=1 prediction=5
LFC BDOT activity pc_hold_cpu=48288 bridge_busy_cpu=39042 accel_busy=70896
LFC BDOT scores=-182,-94,-34,326,-162,556,54,6,216,-96
TB PASS: rv32i_lfc_bdot cycles=105699 bdot=3082 blocks=23632
```

재현 명령:

```bash
./testbench/run_rv32i_lfc_bdot.sh
```

## 4. 성능 결과

| 구현 | RTL cycle | 35 MHz 환산 | BDOT128 대비 |
|---|---:|---:|---:|
| RV32I software | 2,399,397 | 68.554 ms | 22.700x |
| XPC32 | 776,741 | 22.193 ms | 7.349x |
| Wide-BRAM BDOT128 | 105,699 | 3.020 ms | 1.000x |

BDOT128은 XPC32보다 671,042 cycle, 86.392% 감소했다. 이 수치는 RTL clock
가정에 따른 기능·cycle 결과이며 FPGA timing closure 결과가 아니다.

Activity breakdown은 다음과 같다.

| 항목 | 측정 cycle | clock domain |
|---|---:|---|
| 전체 추론 | 105,699 | CPU |
| PC hold | 48,288 | CPU |
| bridge busy | 39,042 | CPU |
| accelerator busy | 70,896 | accelerator |
| non-hold CPU 실행 | 57,411 | CPU |

`70,896 = 23,632 × 3`이므로 현재 accelerator는 128-bit block당 정확히 3 cycle을
사용한다. 105 MHz에서 순수 accelerator busy 시간 합계는 675.2 us이다.

## 5. Break-even

두 가지 해석을 구분한다.

1. 전체 BDOT128 설계를 하나의 clock으로 비례 축소하는 보수적 모델에서는 XPC32
   break-even이 4.763 MHz, 20% margin 목표가 5.715 MHz이다.
2. CPU는 35 MHz로 고정하고 accelerator clock만 바꾸는 dual-clock 분석에서는
   측정된 고정 CPU 상당 cycle을 82,067, accelerator work를 70,896 cycle로 두어
   break-even 3.572 MHz, 20% margin 목표 4.286 MHz를 얻는다.

두 번째 값은 CDC/host overhead가 accelerator 주파수 변화에도 현재와 같은 CPU
cycle로 유지된다는 분석 가정이 포함된다. FPGA 측정에서는 주파수별 CDC latency를
다시 계측해야 한다. 목표 105 MHz는 두 모델 모두에 충분한 여유가 있다.

## 6. 남은 위험 및 다음 단계

- 현재 memory는 RTL 기능 모델이다. 실제 BMG의 read latency, read-first mode,
  lane ordering 및 independent-clock 설정을 등가시험해야 한다.
- toggle CDC bundled-data 경로에 `ASYNC_REG`와 timing exception을 추가하고 Vivado
  CDC report를 확인해야 한다.
- custom-1 opcode `0x2B`는 팀 공용 opcode allocation과 최종 대조해야 한다.
- Vivado 합성 후 105 MHz timing, LUT/FF/BRAM, 동적 전력 및 energy/inference를
  측정해야 한다.
- 현재 threshold와 output packing은 CPU에 남아 있다. 다음 성능 최적화 후보는
  layer 단위 threshold/packing 가속이다.
