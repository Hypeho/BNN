# FINN LFC BDOT128 Memory Image 설계

> 갱신 메모: 현재 구현에서 BDOT logic은 CPU와 같은 35 MHz이며, 아래의 105 MHz
> accelerator 표현은 초기 dual-clock 설계를 기록한 것이다. 105 MHz는 현재
> Activation/Weight wide Port B의 memory clock으로만 사용한다.

- 작성일: 2026-08-17 18:12 KST
- 상태: 구현 기준 확정

## 1. 설계 목적

기존 FINN LFC 프로그램은 input, weight, threshold 및 activation을 하나의 CPU
DMEM 주소 공간에 둔다. BDOT128에서는 Weight/Activation을 accelerator가 wide
port로 직접 읽으므로 다음 세 영역으로 물리·논리적으로 분리한다.

```text
CPU DMEM        threshold, polarity, stack, mailbox, score
Weight BRAM     neuron별 128-bit aligned weight
Activation BRAM input 및 layer output ping-pong
```

기존 `lfc_params.h`를 그대로 링크하면 weight 약 357 KiB가 CPU DMEM에 남으므로
64 KiB CPU DMEM 목표를 만족할 수 없다. 따라서 BDOT variant에는 threshold와
polarity만 포함하는 별도 header를 생성한다.

## 2. CPU byte-address map

| 영역 | CPU/ISA base | 크기 | 용도 |
|---|---:|---:|---|
| CPU DMEM | `0x2000_0000` | 64 KiB | mailbox, threshold, polarity, stack |
| Activation 0 | `0x3000_0000` | 32 KiB | input 또는 layer output |
| Activation 1 | `0x3001_0000` | 32 KiB | ping-pong layer output |
| Weight | `0x4000_0000` | 400 KiB | W0~W3 aligned weight |

모든 architectural operand는 byte address를 사용한다. Testbench와 FPGA wrapper가
각 base를 제거해 local BRAM byte address로 변환한다.

Activation 0과 1 사이 `0x3000_8000`~`0x3000_ffff`는 미사용 공백이다.
Accelerator의 범위 검사는 두 뱅크를 각각 판정하므로, 한 개의 연속 범위처럼
취급해 공백 접근을 허용하지 않는다. 요청한 전체 128-bit block 범위가 어느 한
뱅크 안에 완전히 들어와야 한다.

## 3. Activation ping-pong

| 단계 | 입력 | 출력 |
|---|---|---|
| Layer 0, 784→1024 | Activation 0 | Activation 1 |
| Layer 1, 1024→1024 | Activation 1 | Activation 0 |
| Layer 2, 1024→1024 | Activation 0 | Activation 1 |
| Output, 1024→10 | Activation 1 | CPU score |

BDOT은 input Activation BRAM을 wide port로 읽고 match count를 CPU `rd`로
반환한다. 초기 단계에서는 CPU가 threshold/polarity를 적용하고 output bit를
반대편 Activation BRAM의 32-bit port에 pack한다.

## 4. Weight layout

### 4.1 W0

- 입력 bit: 784
- 기존 neuron stride: 25 word, 100 B
- BDOT128 stride: 7 row = 28 word, 112 B
- neuron 수: 1,024
- 총 크기: 114,688 B = 112 KiB

각 neuron은 기존 25 word를 그대로 복사하고 3 word를 0으로 padding한다.
마지막 유효 word의 low 16 bit만 유효하며 BDOT tail mask가 나머지를 제외한다.

### 4.2 W1/W2/W3

1024-bit vector는 32 word로 이미 128-bit aligned이므로 word 순서를 변경하지
않는다.

| Layer | input bit | neuron | stride | offset | byte size |
|---|---:|---:|---:|---:|---:|
| W0 | 784 | 1,024 | 112 B | `0x00000` | 114,688 |
| W1 | 1,024 | 1,024 | 128 B | `0x1C000` | 131,072 |
| W2 | 1,024 | 1,024 | 128 B | `0x3C000` | 131,072 |
| W3 | 1,024 | 10 | 128 B | `0x5C000` | 1,280 |
| 합계 |  |  |  |  | 378,112 B = 369.25 KiB |

400 KiB Weight BRAM에서 30.75 KiB가 남는다. 이 용량은 현재 BDOT128 image뿐
아니라 385.25 KiB로 예상한 BDOT256 aligned image도 수용한다.

## 5. Lane ordering

원본 32-bit word 순서를 유지하며 낮은 byte address가 낮은 wide lane에 온다.

```text
wide[31:0]    = word[n+0]
wide[63:32]   = word[n+1]
wide[95:64]   = word[n+2]
wide[127:96]  = word[n+3]
```

CPU와 generator, RTL memory wrapper 및 BMG wrapper가 모두 이 규칙을 사용한다.

### 5.1 Port clock 계약

- Activation Port A: CPU 32-bit R/W, CPU clock 35 MHz
- Activation Port B: accelerator 128-bit read, accelerator clock 105 MHz
- Weight Port B: accelerator 128-bit read, accelerator clock 105 MHz

RTL 전체 추론 testbench도 이 independent-clock true dual-port 구성을 사용한다.
CPU address/data/control을 accelerator clock에서 직접 샘플링하는 구성은 허용하지
않는다.

## 6. 생성 산출물

`generate_lfc_bdot_images.py`는 하나의 원본 `lfc_params.h`에서 다음을 만든다.

- `lfc_bdot_params.h`: threshold, polarity, address/stride constant
- `weight_128.hex`: 400 KiB Weight BRAM용 word image
- `activation0.hex`: input을 포함한 32 KiB image
- `activation1.hex`: zero-initialized 32 KiB image
- layer별 golden packed activation
- `lfc_bdot_metadata.json`: 크기, offset, checksum 및 golden score

Generator 자체가 원본 layout과 aligned layout으로 추론을 각각 수행해 prediction,
score 및 layer activation이 동일한지 확인한 뒤에만 파일을 출력한다.

## 7. 설계상 제한

- 현재 BDOT은 threshold/output packing을 CPU에 유지한다.
- CPU가 Activation BRAM을 일반 `lw/sw`로 접근할 수 있어야 한다.
- Weight BRAM은 run mode에서 CPU가 접근하지 않는다.
- 향후 BNNRUN에서는 같은 image를 유지하면서 output packing을 accelerator로
  이동할 수 있다.
