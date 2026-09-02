# Wide-BDOT128 BNN Validation Summary

## 1. 연구 목적

- RV32I 기반 BNN inference에서 반복되는 Binary Dot Product의 software overhead를 줄이기 위한 architecture 탐색 과정을 정리함.
- 최종 Wide-BDOT128 architecture를 FINN LFC, FINN CNV, eBNN의 서로 다른 workload에 적용함.
- Vivado 2019.1 XSim에서 여러 실제 input을 사용해 Software Golden과 RTL의 Functional Correctness를 검증함.
- Multiple-Input correctness와 기존 Single-Input FPGA performance를 서로 다른 평가로 구분함.
- 새로운 architecture 확장보다 현재 결과의 재현성과 평가 범위를 명확히 하는 것을 우선함.

## 2. 해결하고자 한 문제

- BNN은 Multiply-Accumulate 대신 XNOR–Popcount로 Binary Dot Product를 계산할 수 있음.
- 기본 RV32I에서 이를 32-bit software loop로 수행하면 다음 작업이 반복됨.

  - Activation/Weight load를 수행함.
  - XNOR와 software popcount를 수행함.
  - partial result를 누산함.
  - pointer를 갱신함.
  - loop branch를 수행함.

- Binary arithmetic 자체가 단순하더라도 load, accumulation, pointer update 및 loop control이 전체 inference의 병목으로 남을 수 있음.
- 본 연구에서는 Custom Instruction이 담당하는 Binary Dot Product의 범위를 단계적으로 확장함.

## 3. Architecture 탐색 과정

### 3.1 RV32I Software

- 모든 Binary Dot Product를 기본 RV32I instruction으로 처리한 기준 구현임.
- FINN LFC 기준 2,399,397 cycles, 68.554 ms @ 35 MHz가 측정됨.
- Prediction과 class score를 이후 architecture의 기능 비교 기준으로 사용함.

### 3.2 XPC32

- 32-bit register-to-register XNOR–Popcount를 하나의 Custom Instruction으로 처리함.
- FINN LFC에서 776,741 cycles, 22.193 ms @ 35 MHz를 기록함.
- RV32I Software 대비 약 3.09× improvement를 확인함.
- CPU가 각 32-bit word마다 load, XPC32 호출, accumulation 및 loop control을 반복해야 하는 한계가 남음.

### 3.3 BPC32

- BRAM-to-BRAM 32-bit word-level operand 접근을 탐색한 Design-Space Exploration임.
- Directed test와 high-address test를 포함한 기능 검증은 PASS함.
- Synchronous BRAM read timing과 CPU/full-model integration 문제가 남아 FINN LFC 전체 inference 성능 개선을 입증하지 못함.
- Full-model 성공 architecture로 표현하지 않고 Wide-BDOT128 설계로 이어진 Back-data로 보존함.

### 3.4 Break-even Analysis

- BDOT 구현 전 analytical model을 사용해 accelerator가 기존 XPC32보다 유리해지는 최소 frequency를 검토함.
- 본 통합 문서에서는 현재 확정된 기준인 약 7.55 MHz의 break-even frequency만 사용함.
- Engineering target은 최소 약 10 MHz 이상을 확보하는 방향으로 설정함.
- 가정과 측정 조건이 다른 과거 break-even 수치는 본 비교에 혼용하지 않음.
- 본 값은 analytical 기준이며 FPGA frequency sweep 실측값으로 표현하지 않음.

### 3.5 Wide-BDOT128

- 128-bit Wide Activation BRAM과 128-bit Wide Weight BRAM을 사용함.
- Blocking BDOT Custom Instruction이 설정된 bit length에 따라 accelerator 내부에서 여러 128-bit block을 순회함.
- 각 block에서 masked XNOR–Popcount와 accumulation을 수행하고 최종 match count를 CPU에 반환함.
- Tail mask를 사용해 128-bit 배수가 아닌 vector의 마지막 valid bit만 계산함.
- 핵심 변화는 CPU가 반복하던 Binary Dot Product loop를 accelerator 내부로 더 많이 이동한 것임.

## 4. Wide-BDOT128 Architecture

### CPU 역할

- BCFG로 Binary Dot Product의 valid bit length를 설정함.
- BDOT에 Activation/Weight base address를 전달함.
- model별 activation packing, threshold/polarity, pooling, Bias/BatchNorm, checksum 및 prediction 처리를 수행함.
- BDOT 결과를 사용해 다음 layer activation 또는 final class score를 생성함.

### Accelerator 역할

- BDOT request를 수신하면 blocking 방식으로 CPU 진행을 정지함.
- `ISSUE → WAIT → ACCUM` 순서로 각 128-bit block을 처리함.
- 128-bit XNOR–Popcount와 multi-block accumulation을 수행함.
- 마지막 block에 tail mask를 적용하고 최종 match count와 done을 반환함.

### Memory 구조

- CPU/BDOT control과 datapath는 35 MHz 기준으로 동작함.
- Wide BRAM read는 105 MHz 기준으로 구성함.
- Activation memory는 CPU용 32-bit port와 accelerator용 128-bit port를 제공함.
- Weight memory는 accelerator가 aligned 128-bit block 단위로 읽도록 배치함.
- FINN LFC의 784-bit 입력은 128-bit full block 6개와 마지막 16 valid bits를 포함한 tail block 1개로 처리함.

### BCFG / BDOT 동작

- BCFG가 vector length를 설정함.
- BDOT가 Activation/Weight address를 기준으로 내부 block loop를 실행함.
- CPU가 모든 block마다 별도 BDOT instruction을 호출하는 구조가 아님.
- LFC에서는 neuron/output당 BDOT 1회가 여러 128-bit block을 내부 처리함.
- model별 vector length가 달라도 동일한 Wide-BDOT128 datapath와 tail 처리 구조를 사용함.

## 5. Multiple-Input Correctness

### 검증 원칙

- 공식 RTL Simulator로 Vivado 2019.1 XSim을 사용함.
- Ground-truth label은 dataset metadata로만 사용함.
- RTL expected output은 model parameter를 사용해 계산한 Software/Host Golden으로 생성함.
- Prediction만 비교하지 않고 model에서 확보 가능한 class score와 intermediate result를 함께 비교함.
- Multiple-Input XSim cycle은 correctness regression의 관측값이며 FPGA latency로 해석하지 않음.
- 세 model validation에서 Wide-BDOT128 RTL architecture를 수정하지 않음.

### FINN LFC

- Binary-MNIST input data 20개를 FINN LFC parameter로 독립 inference함.
- eBNN의 prediction 또는 checksum을 FINN LFC Golden으로 사용하지 않음.
- Prediction과 class score 10개, Layer 0/1/2 전체 packed activation을 비교함.
- 전체 20개 sample이 XSim 2019.1에서 exact match함.

| 항목 | 결과 |
|---|---:|
| Samples | 20 |
| Prediction exact match | 20/20 |
| Class score exact match | 20/20 |
| Layer 0 packed activation | 20/20 |
| Layer 1 packed activation | 20/20 |
| Layer 2 packed activation | 20/20 |
| Cycle minimum / maximum | 121,399 / 121,531 |
| Cycle average / range | 121,475.1 / 132 |
| BDOT count | 3,082, 모든 input에서 동일함. |
| 128-bit block count | 23,632, 모든 input에서 동일함. |
| Overall | PASS |

- 기존 Single-Input case에서 prediction 5와 score `[-182,-94,-34,326,-162,556,54,6,216,-96]`을 재현함.
- 기존 Single-Input regression은 121,521 cycles, BDOT 3,082, Blocks 23,632로 PASS함.
- 관측된 cycle variation은 activation packing과 class maximum update의 input-dependent CPU-side branch로 확인됨.

### FINN CNV

- 실제 CIFAR-10 test input 10개를 사용하고 Ground-truth class 0~9를 각각 포함함.
- Exported Weight/Threshold/Polarity를 사용한 Software Golden을 기준으로 검증함.
- Prediction, class score 10개 및 intermediate checksum 10개를 비교함.
- 전체 10개 sample이 XSim 2019.1에서 exact match함.

| 항목 | 결과 |
|---|---:|
| Samples | 10 |
| Ground-truth class coverage | 0~9 |
| Prediction exact match | 10/10 |
| Class score exact match | 10/10 |
| Intermediate checksum 10개 | 10/10 |
| Cycle minimum / maximum | 29,468,057 / 29,528,328 |
| Cycle average / range | 29,491,892.5 / 60,271 |
| BDOT count | 756,746, 모든 input에서 동일함. |
| 128-bit block count | 761,128, 모든 input에서 동일함. |
| Overall | PASS |

- Case 2의 Ground-truth label은 0이지만 Golden prediction과 RTL prediction은 모두 8임.
- Case 2의 score와 checksum도 exact match함.
- Dataset label이 아니라 FINN CNV Software Golden 계산 결과를 expected output으로 사용했음을 보여줌.
- 기존 Single-Input regression도 XSim 2019.1에서 PASS함.

### eBNN

- `binary_mnist_data.h`의 기존 Binary-MNIST sample 20개를 사용함.
- Host Golden이 prediction, float class score bit pattern, Activation checksum 및 360-bit packed activation을 생성함.
- 전체 20개 sample이 XSim 2019.1에서 bit-exact하게 일치함.

| 항목 | 결과 |
|---|---:|
| Samples | 20 |
| Prediction exact match | 20/20 |
| Float class score bit-exact match | 20/20 |
| Activation checksum exact match | 20/20 |
| 360-bit packed activation exact match | 20/20 |
| Cycle minimum / maximum | 1,043,161 / 1,048,616 |
| Cycle average / range | 1,045,692.85 / 5,455 |
| BDOT count | 3,250, 모든 input에서 동일함. |
| 128-bit block count | 3,270, 모든 input에서 동일함. |
| Overall | PASS |

- Sample 19의 Ground-truth label은 9이지만 Golden prediction과 RTL prediction은 모두 7임.
- Sample 19의 score, checksum 및 packed activation도 exact match함.
- Dataset label이 아니라 eBNN Host Golden 계산 결과를 expected output으로 사용했음을 보여줌.

### 통합 비교

| 항목 | FINN LFC | FINN CNV | eBNN Binary-MNIST |
|---|---:|---:|---:|
| Input | Binary-MNIST data | 실제 CIFAR-10 test input | Binary-MNIST data |
| Samples | 20 | 10 | 20 |
| Prediction | 20/20 PASS | 10/10 PASS | 20/20 PASS |
| Score | 20/20 exact | 10/10 exact | 20/20 bit-exact |
| Intermediate | L0/L1/L2 packed activation | Intermediate checksum 10개 | Checksum + 360-bit packed activation |
| BDOT / sample | 3,082 | 756,746 | 3,250 |
| Blocks / sample | 23,632 | 761,128 | 3,270 |
| Overall | PASS | PASS | PASS |

- 동일 Wide-BDOT128 architecture가 세 종류의 BNN workload에서 Software Golden과 일치함을 확인함.
- 검증 sample은 각 model에 포함된 제한된 subset이며 전체 dataset 검증 또는 모든 BNN으로의 일반화를 의미하지 않음.

## 6. Single-Input FPGA Performance

- 다음 수치는 Multiple-Input XSim correctness와 별도로 기존 Single-Input FPGA 평가에서 확보한 결과임.
- Multiple-Input validation firmware의 cycle을 기존 FPGA latency와 직접 혼용하지 않음.

### FINN LFC

| 구현 | 기준 결과 |
|---|---:|
| RV32I-only | 2,399,397 cycles, 68.554 ms @ 35 MHz |
| XPC32 | 776,741 cycles, 22.193 ms @ 35 MHz |
| Wide-BDOT128 FPGA | 약 3.478 ms @ 35 MHz |
| Wide-BDOT128 improvement | 약 19.71× vs. RV32I-only |
| Wide-BDOT128 workload | BDOT 3,082, Blocks 23,632 |

- 긴 FC Binary Dot Product가 많아 한 번의 BDOT instruction이 반복 block 작업을 많이 흡수함.

### FINN CNV

| 구현 | 기준 결과 |
|---|---:|
| RV32I-only profile | 약 84,445,960 retired instructions |
| Wide-BDOT128 기존 RTL 평가 | 약 29,360,256 cycles |
| Wide-BDOT128 FPGA | 약 838.871 ms @ 35 MHz |
| Wide-BDOT128 improvement | 약 2.876× |
| Wide-BDOT128 workload | BDOT 756,746, Blocks 761,128 |

- RV32I-only instruction profile은 single-cycle CPU 비교 기준으로 사용된 기존 reference임.
- 현재 Multiple-Input cycle 29.47~29.53M은 validation firmware 결과이므로 기존 Single-Input 성능 측정과 동일 실험으로 표현하지 않음.

### eBNN

| 구현 | 기준 결과 |
|---|---:|
| RV32I-only | 약 4,749,274 cycles |
| Wide-BDOT128 기존 RTL 평가 | 약 1,044,728 cycles |
| Wide-BDOT128 FPGA | 약 29.853 ms @ 35 MHz |
| Wide-BDOT128 improvement | 약 4.546× |
| Wide-BDOT128 workload | BDOT 3,250, Blocks 3,270 |

- 현재 Multiple-Input cycle 1.043~1.049M은 validation firmware 결과이므로 기존 Single-Input 성능 측정과 동일 실험으로 표현하지 않음.

## 7. 모델별 결과 차이 분석

### FINN LFC

- 긴 FC Binary Dot Product가 주 workload임.
- 한 번의 BDOT instruction이 여러 128-bit block을 내부 처리해 CPU loop overhead를 크게 줄임.
- 기존 Single-Input FPGA 평가에서 약 19.71× improvement를 확인함.

### FINN CNV

- BDOT 호출 수가 756,746회로 매우 많음.
- 64/128-bit 수준의 상대적으로 짧은 Binary Dot Product가 다수 존재함.
- 짧은 vector에서는 BDOT command와 CPU-side control overhead의 상대적 비중이 증가함.
- 기존 Single-Input FPGA 평가의 improvement는 약 2.876×로 LFC보다 작음.

### eBNN

- BDOT 호출 수는 LFC와 비슷하지만 9-bit Binary Convolution window가 다수 존재함.
- CPU-side float Bias/BatchNorm, pooling/control 및 activation packing 작업이 남음.
- Binary Dot Product를 가속해도 전체 inference의 모든 작업이 제거되지 않음.
- 기존 Single-Input FPGA 평가의 improvement는 약 4.546×임.

### Amdahl 관점

- 전체 inference는 BDOT으로 가속 가능한 부분과 CPU에 남는 부분으로 나뉨.
- Wide-BDOT128이 Binary Dot Product 시간을 줄여도 CPU-side 처리 비중이 speedup의 상한을 결정함.
- model별 speedup은 다음 요소의 영향을 함께 받음.

  - Binary Dot Product가 전체 inference에서 차지하는 비중임.
  - Binary vector의 길이와 한 명령당 실제 계산량임.
  - BDOT instruction 호출 횟수임.
  - packing, pooling, threshold, Bias/BatchNorm 등 CPU-side processing 비중임.

- 본 단계에서는 새로운 Amdahl analytical calculation을 수행하지 않음.

## 8. Contribution

### Contribution 1 — Workload-driven bottleneck 분석

- BNN을 RV32I에서 실행할 때 Binary arithmetic 자체보다 반복적인 32-bit load, software popcount, accumulation 및 loop control이 성능 병목이 될 수 있음을 분석함.

### Contribution 2 — Custom Instruction 처리 범위 확장

- XPC32의 32-bit register-to-register XNOR–Popcount에서 출발함.
- 128-bit Wide BRAM을 직접 사용하고 한 output의 multi-block Binary Dot Product를 accelerator 내부에서 처리하는 Blocking Wide-BDOT128 구조로 확장함.

### Contribution 3 — Multi-workload evaluation

- FINN LFC, FINN CNV, eBNN에서 동일 Wide-BDOT128 architecture의 correctness를 검증함.
- 가속 효과가 단순히 BNN 여부가 아니라 vector length, BDOT 호출 overhead 및 CPU-side processing 비중에 따라 달라짐을 기존 FPGA 결과와 함께 확인함.
- 모든 BNN에 일반적으로 적용 가능한 범용 최적 구조라고 단정하지 않음.

## 9. Limitations

- Multiple-Input 결과는 Vivado 2019.1 XSim RTL Validation이며 FPGA Multiple-Input execution이 아님.
- FINN LFC와 eBNN은 각각 Binary-MNIST 20개, FINN CNV는 CIFAR-10 10개만 검증함.
- 전체 dataset에 대한 exhaustive validation 또는 model accuracy 평가를 수행하지 않음.
- Ground-truth label과 model Golden prediction을 분리했으며 correctness PASS를 classification accuracy로 해석하지 않음.
- model 간 XSim cycle은 network 구조와 firmware가 달라 직접적인 model 성능 순위로 사용하지 않음.
- Multiple-Input validation cycle과 기존 Single-Input FPGA performance는 측정 firmware/경계가 다를 수 있어 직접 혼용하지 않음.
- Input별 CNV/eBNN cycle variation의 정확한 CPU control-flow 원인은 본 단계에서 별도 분석하지 않음.
- BPC32는 directed/high-address 기능시험 결과이며 Full FINN LFC 성능 개선을 입증하지 못함.

### Pipeline 결과 해석 제한

- 기존 Pipeline FINN LFC는 약 2,725,120 cycles를 기록함.
- nominal 80 MHz 설정에서 FPGA functional execution 약 34.064 ms를 확인함.
- Implementation WNS가 -0.857 ns이므로 80 MHz timing constraint를 만족한 결과가 아님.
- 최종 performance comparison 전 Timing-clean frequency 재평가가 필요함.

### Power 결과 해석 제한

- FINN LFC SAIF flow의 annotation coverage는 약 8%이며 confidence는 medium임.
- Preliminary 결과는 Active total power 약 0.256 W, Idle 약 0.249 W임.
- Dynamic difference는 약 7 mW임.
- Activity-window dynamic energy는 약 118.05 µJ, total energy는 약 888.847 µJ, Active–Idle incremental energy는 약 24.304 µJ임.
- 낮은 annotation coverage 때문에 최종 Energy Efficiency 증거로 사용하지 않음.

## 10. 향후 수행할 평가

- Pipeline + BDOT 결과를 Timing-clean frequency에서 재평가하고 Single-cycle + BDOT과 비교함.
- SAIF annotation coverage를 개선하고 동일 조건에서 RV32I, XPC32, Wide-BDOT128 Power/Energy를 비교함.
- 필요한 기존 Single-Input FPGA 결과와 향후 Multiple-Input FPGA 결과의 측정 경계를 명확히 정리함.
- 교수님 미팅 자료에서 Correctness, Performance, Timing, Power evidence를 분리한 Storyline을 구성함.
- 새로운 Custom Instruction, 새로운 BRAM architecture 또는 BDOT256을 Future Work에 추가하지 않음.

## 11. Repository 포함/제외 기준

### GitHub 포함 후보

- `hardware/wide_bdot128`의 공통 RTL, constraint 및 필요한 Tcl을 포함함.
- model별 Validation Firmware, Testbench, Golden Generator, runner 및 helper를 포함함.
- model별 결과 CSV와 Markdown을 포함함.
- model별 README와 본 통합 summary를 포함함.
- 재현에 필요한 parameter source와 memory image generator를 포함함.
- 기존 source의 copyright, license 및 author header를 유지함.

### GitHub 제외 후보

- `.Xil`, `xsim.dir`, Vivado cache 및 local workspace를 제외함.
- `models/*/work`, temporary firmware build output, ELF/object/map 파일을 제외함.
- Python virtual environment와 `__pycache__`를 제외함.
- raw/intermediate log와 waveform 중 재현에 불필요한 대용량 파일을 제외함.
- local absolute path에 종속된 temporary artifact를 제외함.
- generated vector는 generator로 재생성 가능하므로 기본 제외 대상으로 유지함.

- 현재 `.gitignore`가 위 generated artifact와 model result CSV/Markdown 예외 규칙을 반영함.
- 본 workspace에는 아직 Git repository가 생성되지 않았으며 commit/push를 수행하지 않음.
